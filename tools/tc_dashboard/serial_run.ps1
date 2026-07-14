<#
tc_dashboard 백엔드(server.py)가 SSH 대신 시리얼(COM)로 TC 스크립트를 transfer+실행할 때 호출하는 헬퍼.
~/.claude/projects/-home-hsung-edge/tools/serial_helper.ps1 의 transfer/run_main 패턴을 재사용하되,
임의의 --flag 하나를 실행하고 그 결과(base64 dump)를 디코딩해 stdout으로 그대로 출력한다
(SSH를 전혀 쓰지 않으므로 SSH lockout 상태에서도 동작 가능).
#>
param(
    [string]$ComPort    = "COM6",
    [Parameter(Mandatory=$true)] [string]$ScriptPath,
    [string]$Flag       = "",
    [int]$TimeoutMs     = 120000,
    [string]$LogFile    = "C:\Users\hyunje.sung\AppData\Local\Temp\tc_dashboard_serial.log"
)
$ErrorActionPreference = 'Continue'
$REMOTE_SCRIPT = "/tmp/tc_system_log.sh"
$REMOTE_OUT    = "/tmp/tc_dash_serial.out"

# Write-Output 은 리다이렉트된 stdout에 콘솔 로케일(한글 Windows면 CP949)로 재인코딩해서
# 한글이 깨진다 (Python 쪽은 UTF-8로 읽음). 표준출력 핸들에 직접 UTF-8 바이트를 쓴다.
$stdOut = [Console]::OpenStandardOutput()
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Out-Utf8([string]$s) {
    $bytes = $utf8NoBom.GetBytes($s + "`n")
    $stdOut.Write($bytes, 0, $bytes.Length)
    $stdOut.Flush()
}

# 대시보드(server.py의 _tail_serial_log)가 이 파일을 WSL(/mnt/c)로 동시에 읽다가 겹치면
# "다른 프로세스에서 사용 중" 공유 위반이 간헐적으로 난다. 짧게 재시도하고, 그래도 안 되면
# 이 한 조각만 조용히 포기한다 — 실시간 로그 한 줄보다 시리얼 pump 타이밍(80ms 주기)이 우선이라
# 재시도도 최소한으로만 한다.
function Write-LogSafe([string]$path, [string]$value, [switch]$NoNewline) {
    for ($i = 0; $i -lt 3; $i++) {
        try {
            if ($NoNewline) {
                Add-Content -Path $path -Value $value -NoNewline -Encoding UTF8
            } else {
                Add-Content -Path $path -Value $value -Encoding UTF8
            }
            return
        } catch {
            if ($i -lt 2) { Start-Sleep -Milliseconds 15 }
        }
    }
}

$port = New-Object System.IO.Ports.SerialPort($ComPort, 115200, 'None', 8, 'One')
# 기본 Encoding은 ASCII라 ReadExisting()이 한글(멀티바이트 UTF-8) 바이트를 '?'로 뭉갠다 —
# 대시보드가 $LogFile을 실시간 tail해 보여줄 때 이 깨짐이 그대로 노출되므로 UTF8로 명시.
$port.Encoding = [System.Text.Encoding]::UTF8
$port.NewLine = "`r"
$port.ReadTimeout = 1000
$port.Handshake = 'None'
$port.RtsEnable = $true
$port.DtrEnable = $true

$global:matchBuf = ''
$global:fullCapture = ''
function Pump([int]$ms) {
    if ($ms -gt 0) { Start-Sleep -Milliseconds $ms }
    if ($port.BytesToRead -gt 0) {
        $b = $port.ReadExisting()
        Write-LogSafe $LogFile $b -NoNewline
        $global:matchBuf += $b
        $global:fullCapture += $b
        if ($global:matchBuf.Length -gt 65536) {
            $global:matchBuf = $global:matchBuf.Substring($global:matchBuf.Length - 32768)
        }
    }
}
function WaitFor([string]$marker, [int]$timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rx = '(?m)^' + [Regex]::Escape($marker)
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        Pump 80
        if ([Regex]::IsMatch($global:matchBuf, $rx)) { $global:matchBuf = ''; return $true }
    }
    return $false
}
function SendLine([string]$l) { $port.Write($l + "`r") }
function CtrlC { $port.Write([string][char]3); Start-Sleep -Milliseconds 200 }
function EnsureLogin {
    SendLine ''
    Pump 800
    SendLine ''
    Pump 800
    if ($global:matchBuf -match 'login:') { SendLine 'root'; WaitFor '# ' 8000 | Out-Null }
}
function MakeQuiet {
    SendLine 'dmesg -n 1'
    Pump 400
    SendLine 'export PS1="P> "'
    Pump 400
    SendLine 'stty -echo'
    Pump 400
    $global:matchBuf = ''
}

$ok = $false
try {
    if (-not (Test-Path $LogFile)) { New-Item -ItemType File -Path $LogFile -Force | Out-Null }
    $port.Open()
    Start-Sleep -Milliseconds 300
    [void]$port.ReadExisting()
    Write-LogSafe $LogFile ("`n=== SERIAL_RUN START (" + $ComPort + ", flag=" + $Flag + ") " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " ===`n")

    CtrlC; CtrlC; CtrlC
    Pump 1000
    EnsureLogin
    MakeQuiet

    # 이전 잔여 정리
    SendLine ("rm -f /tmp/tc.b64 " + $REMOTE_SCRIPT + " " + $REMOTE_OUT + "; echo M_RM_DONE")
    WaitFor 'M_RM_DONE' 5000 | Out-Null

    # 스크립트 base64 chunked transfer (serial_helper.ps1 의 transfer phase와 동일 패턴)
    $bytes = [System.IO.File]::ReadAllBytes($ScriptPath)
    $b64 = [Convert]::ToBase64String($bytes)
    $chunkSize = 512
    for ($i = 0; $i -lt $b64.Length; $i += $chunkSize) {
        $len = [Math]::Min($chunkSize, $b64.Length - $i)
        $chunk = $b64.Substring($i, $len)
        SendLine ("printf '%s' '" + $chunk + "' >> /tmp/tc.b64")
        Pump 110
    }
    SendLine ("base64 -d /tmp/tc.b64 > " + $REMOTE_SCRIPT + " && chmod +x " + $REMOTE_SCRIPT + " && wc -c " + $REMOTE_SCRIPT + "; echo M_DECODE_DONE")
    $decodeOk = WaitFor 'M_DECODE_DONE' 20000

    if (-not $decodeOk) {
        Out-Utf8 "[SERIAL_RUN] 스크립트 transfer 실패 (M_DECODE_DONE 미수신)"
    } else {
        # 실행 — /tmp 가 noexec 마운트이므로 sh 로 감싸서 실행 (edge feedback_ssh_retry_limit 참고, tc_dashboard와 동일한 우회)
        # tee로 결과 파일 저장과 동시에 시리얼 콘솔에도 흘려서 대시보드 실시간 tail(_tail_serial_log)이
        # 실행 중 절차/PASS/FAIL을 바로 보여줄 수 있게 한다 — 최종 판정은 여전히 base64 dump(신뢰 가능한
        # 전체 캡처)로 하고, 콘솔 스트림은 진행상황 표시 용도(노이즈 섞일 수 있어 참고용).
        $remoteCmd = "sh $REMOTE_SCRIPT $Flag 2>&1 | tee $REMOTE_OUT; echo M_DASH_RUN_END"
        SendLine $remoteCmd
        $ok = WaitFor 'M_DASH_RUN_END' $TimeoutMs

        # 결과 dump (작은 파일 기준 base64 1회 dump)
        SendLine ("echo M_DUMPBEG; base64 -w 76 " + $REMOTE_OUT + "; echo M_DUMPEND")
        WaitFor 'M_DUMPEND' 60000 | Out-Null

        $m = [Regex]::Match($global:fullCapture, '(?s)M_DUMPBEG\r?\n(.*?)\r?\nM_DUMPEND')
        if ($m.Success) {
            $b64out = ($m.Groups[1].Value -replace '[^A-Za-z0-9+/=]', '')
            try {
                $outBytes = [Convert]::FromBase64String($b64out)
                $text = [System.Text.Encoding]::UTF8.GetString($outBytes)
                Out-Utf8 $text
            } catch {
                Out-Utf8 ("[SERIAL_RUN] base64 decode 실패: " + $_)
            }
        } else {
            Out-Utf8 "[SERIAL_RUN] 결과 dump 캡처 실패 (marker 매칭 안됨)"
        }
    }
    Out-Utf8 ("SERIAL_RUN_OK=" + $ok)
}
catch {
    Out-Utf8 ("[SERIAL_RUN ERROR] " + $_)
}
finally {
    if ($port.IsOpen) { $port.Close() }
    Write-LogSafe $LogFile ("`n=== SERIAL_RUN END " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " ===`n")
}
