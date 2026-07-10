param(
    [Parameter(Mandatory=$true)] [string]$Phase,
    [string]$ComPort   = "COM7",
    [string]$LogFile   = "C:\Users\hyunje.sung\AppData\Local\Temp\tc_console.log",
    [string]$ScriptPath = "\\wsl.localhost\Ubuntu-18.04\home\hsung\edge\tcs\system_log\tc_system_log.sh"
)
$ErrorActionPreference = 'Continue'

$port = New-Object System.IO.Ports.SerialPort($ComPort, 115200, 'None', 8, 'One')
$port.NewLine = "`r"
$port.ReadTimeout = 1000
$port.Handshake = 'None'
$port.RtsEnable = $true
$port.DtrEnable = $true

$global:matchBuf = ''
function Pump([int]$ms) {
    if ($ms -gt 0) { Start-Sleep -Milliseconds $ms }
    if ($port.BytesToRead -gt 0) {
        $b = $port.ReadExisting()
        Add-Content -Path $LogFile -Value $b -NoNewline -Encoding UTF8
        $global:matchBuf += $b
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
        if ([Regex]::IsMatch($global:matchBuf, $rx)) {
            $global:matchBuf = ''
            return $true
        }
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
# 작은 file은 한 번에 dump
function DumpSmall([string]$tag, [string]$cmd) {
    $beg = 'M_DUMPBEG_' + $tag
    $end = 'M_DUMPEND_' + $tag
    $port.DiscardInBuffer()
    $global:matchBuf = ''
    SendLine ('echo ' + $beg + '; ' + $cmd + ' | base64 -w 76; echo ' + $end)
    return (WaitFor $end 60000)
}
# 큰 file은 split해서 chunked dump (corruption 방지)
function DumpChunked([string]$tag, [string]$srcFile) {
    # 디바이스에서 split → 각 chunk를 base64 dump
    SendLine ("split -b 16384 -d -a 3 '" + $srcFile + "' /tmp/_chunk_; echo M_SPLIT_DONE")
    WaitFor 'M_SPLIT_DONE' 10000 | Out-Null
    SendLine 'ls /tmp/_chunk_* | wc -l; echo M_CHUNK_COUNT'
    WaitFor 'M_CHUNK_COUNT' 5000 | Out-Null
    Pump 500
    # 모든 chunk dump
    $beg = 'M_DUMPBEG_' + $tag
    $end = 'M_DUMPEND_' + $tag
    $port.DiscardInBuffer()
    $global:matchBuf = ''
    SendLine ('echo ' + $beg + '; for f in /tmp/_chunk_*; do echo "===CHUNK $f==="; base64 -w 76 "$f"; done; echo ' + $end)
    $ok = WaitFor $end 600000
    SendLine 'rm -f /tmp/_chunk_*'
    Pump 400
    return $ok
}

try {
    if (-not (Test-Path $LogFile)) { New-Item -ItemType File -Path $LogFile -Force | Out-Null }
    $port.Open()
    Start-Sleep -Milliseconds 300
    [void]$port.ReadExisting()
    Add-Content -Path $LogFile -Value ("`n=== PHASE " + $Phase + " START " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " ===`n") -Encoding UTF8

    if ($Phase -eq 'login_test') {
        EnsureLogin
        SendLine 'whoami; hostname; date'
        Pump 2000
        Write-Host 'LOGIN_OK'
    }
    elseif ($Phase -eq 'transfer') {
        EnsureLogin
        MakeQuiet
        $bytes = [System.IO.File]::ReadAllBytes($ScriptPath)
        $b64 = [Convert]::ToBase64String($bytes)
        Write-Host ('Script size: ' + $bytes.Length + ' bytes, base64: ' + $b64.Length + ' chars')
        SendLine 'rm -f /tmp/tc.b64 /tmp/tc_system_log.sh; echo M_RM_DONE'
        WaitFor 'M_RM_DONE' 4000 | Out-Null
        $chunkSize = 512
        for ($i = 0; $i -lt $b64.Length; $i += $chunkSize) {
            $end = [Math]::Min($chunkSize, $b64.Length - $i)
            $chunk = $b64.Substring($i, $end)
            SendLine ("printf '%s' '" + $chunk + "' >> /tmp/tc.b64")
            Pump 110
        }
        SendLine 'base64 -d /tmp/tc.b64 > /tmp/tc_system_log.sh && chmod +x /tmp/tc_system_log.sh && wc -c /tmp/tc_system_log.sh; md5sum /tmp/tc_system_log.sh; echo M_DECODE_DONE'
        WaitFor 'M_DECODE_DONE' 20000 | Out-Null
        Write-Host 'TRANSFER_DONE'
    }
    elseif ($Phase -eq 'run_main') {
        CtrlC; CtrlC; CtrlC
        Pump 1500
        EnsureLogin
        MakeQuiet
        SendLine 'timedatectl set-ntp false 2>/dev/null; systemctl stop chronyd 2>/dev/null; systemctl stop systemd-timesyncd 2>/dev/null; echo M_NTPOFF'
        WaitFor 'M_NTPOFF' 5000 | Out-Null
        # 이전 잔여 cleanup
        SendLine 'rm -f /tmp/tc_journal.log /tmp/tc_mqtt.log /tmp/tc_run.out /tmp/tc_sl_filt.log; pkill -f "journalctl.*docker-loader.*-f" 2>/dev/null; pkill -f "mosquitto_sub.*emsp" 2>/dev/null; sleep 1; echo M_CLEANUP'
        WaitFor 'M_CLEANUP' 8000 | Out-Null
        # capture 시작
        SendLine 'journalctl -b 0 -u docker-loader -f --no-pager -o short-iso > /tmp/tc_journal.log 2>&1 &'
        Pump 400
        SendLine 'echo M_JOURNAL_PID_$!'
        WaitFor 'M_JOURNAL_PID_' 3000 | Out-Null
        SendLine "mosquitto_sub -h localhost -t 'emsp/#' -v > /tmp/tc_mqtt.log 2>&1 &"
        Pump 400
        SendLine 'echo M_MQTT_PID_$!'
        WaitFor 'M_MQTT_PID_' 3000 | Out-Null
        # TC01~TC09 실행 (TC04 dummy 주입 + TC02 70초 sleep 포함 → 약 3분)
        SendLine '/tmp/tc_system_log.sh --tc-nmon > /tmp/tc_run.out 2>&1; echo M_TC09_DONE_END'
        # TC04 5사이즈 (100MB ~ 1.8GB) systemd-cat 주입 포함 → 최대 60분
        $ok = WaitFor 'M_TC09_DONE_END' 3600000
        Write-Host ('TC09_RUN matched=' + $ok)
        # capture 중단
        SendLine 'kill %1 %2 2>/dev/null; sleep 2; wc -l /tmp/tc_journal.log /tmp/tc_mqtt.log /tmp/tc_run.out; echo M_STOPCAP'
        WaitFor 'M_STOPCAP' 10000 | Out-Null
        # [SL]/[SM]/req|res 필터링 작은 파일 만들기 (corruption 위험 낮춤)
        SendLine 'fgrep -e "[SL]" -e "[SM]" -e "task_capture" -e "task_merge" -e "task_rotate" -e "delete_log" -e "clear_all_logs" -e "Created meta" -e "handle_request" /tmp/tc_journal.log > /tmp/tc_sl_filt.log; wc -l /tmp/tc_sl_filt.log; echo M_FILT_DONE'
        WaitFor 'M_FILT_DONE' 30000 | Out-Null
        # MQTT는 system_log 관련만 filter
        SendLine 'fgrep -e "emsp/system_log" -e "emsp/tc_runner/system_log" -e "emsp/sys_manager/system_log" -e "emsp/system_log/sys_manager" /tmp/tc_mqtt.log > /tmp/tc_mqtt_filt.log; wc -l /tmp/tc_mqtt_filt.log; echo M_MQTTFILT_DONE'
        WaitFor 'M_MQTTFILT_DONE' 30000 | Out-Null
        # 명령어 결과 캡처 (timer_loop 확인 + ls + xz --test + md5sum + journalctl --disk-usage)
        SendLine 'echo M_CMDOUT_BEGIN; echo "---timer_loop check---"; journalctl -u docker-loader --no-pager -o cat | grep -F "[system_log_timer_loop]" | tail -3; echo "---ls toupload---"; ls -la /edge/log/toupload/system/ 2>&1; echo "---xz --test---"; for f in /edge/log/toupload/system/*.log.xz; do echo "$f: $(xz --test "$f" 2>&1 && echo OK)"; done; echo "---md5sum---"; md5sum /edge/log/toupload/system/*.log.xz 2>&1; echo "---journalctl disk usage---"; journalctl --disk-usage; echo M_CMDOUT_END'
        WaitFor 'M_CMDOUT_END' 30000 | Out-Null
        # dump 작은 파일들만 (chunked 큰 파일은 corruption 위험 + 시간 소모)
        DumpSmall 'tc_run_out'   'cat /tmp/tc_run.out' | Out-Null
        DumpSmall 'tc_sl_filt'   'cat /tmp/tc_sl_filt.log' | Out-Null
        DumpSmall 'tc_mqtt_filt' 'cat /tmp/tc_mqtt_filt.log' | Out-Null
        Write-Host 'RUN_MAIN_DONE'
    }
    elseif ($Phase -eq 'fetch_only') {
        CtrlC; CtrlC; CtrlC
        Pump 1000
        EnsureLogin
        MakeQuiet
        SendLine 'pkill -f "journalctl.*docker-loader.*-f" 2>/dev/null; pkill -f "mosquitto_sub.*emsp" 2>/dev/null; sleep 1; wc -l /tmp/tc_journal.log /tmp/tc_mqtt.log /tmp/tc_run.out 2>/dev/null; echo M_WC'
        WaitFor 'M_WC' 8000 | Out-Null
        DumpSmall 'tc_run_out'   'cat /tmp/tc_run.out' | Out-Null
        DumpChunked 'tc_journal' '/tmp/tc_journal.log' | Out-Null
        DumpChunked 'tc_mqtt'    '/tmp/tc_mqtt.log' | Out-Null
        Write-Host 'FETCH_DONE'
    }
    elseif ($Phase -eq 'tc10pre') {
        EnsureLogin
        MakeQuiet
        SendLine 'sync; /tmp/tc_system_log.sh --tc10-pre 2>&1 | tee /tmp/tc10pre.out'
        WaitFor 'reboot' 30000 | Out-Null
        Pump 30000
        Write-Host 'TC10PRE_CAPTURED'
    }
    elseif ($Phase -eq 'tc10post') {
        Pump 5000
        SendLine ''
        Pump 2000
        EnsureLogin
        MakeQuiet
        SendLine '/tmp/tc_system_log.sh --tc10-post > /tmp/tc10post.out 2>&1; echo M_POST_DONE_END'
        WaitFor 'M_POST_DONE_END' 60000 | Out-Null
        # 명령어 결과 캡처
        SendLine 'echo M_CMDOUT_BEGIN; echo "---toupload---"; ls -la /edge/log/toupload/system/ 2>&1; echo "---staging---"; ls -la /edge/log/system/systemlog_* /edge/log/system/shutdown_done 2>&1; echo "---xz --test---"; for f in /edge/log/toupload/system/*.log.xz; do echo "$f: $(xz --test "$f" 2>&1 && echo OK)"; done; echo M_CMDOUT_END'
        WaitFor 'M_CMDOUT_END' 20000 | Out-Null
        DumpSmall 'tc10post_out' 'cat /tmp/tc10post.out' | Out-Null
        # boot 0 [SL] filter
        SendLine 'journalctl -b 0 -u docker-loader --no-pager -o short-iso | fgrep -e "[SL]" -e "[SM]" -e "task_capture" -e "task_merge" -e "shutdown_done" > /tmp/tc10post_sl.log; wc -l /tmp/tc10post_sl.log; echo M_TC10FILT_DONE'
        WaitFor 'M_TC10FILT_DONE' 30000 | Out-Null
        DumpSmall 'tc10post_sl' 'cat /tmp/tc10post_sl.log' | Out-Null
        Write-Host 'TC10POST_DONE'
    }
    elseif ($Phase -eq 'full_run') {
        CtrlC; CtrlC; CtrlC
        Pump 1500
        EnsureLogin
        MakeQuiet
        # NTP off (TC02 시간 이동 전 선제 처리)
        SendLine 'timedatectl set-ntp false 2>/dev/null; systemctl stop chronyd 2>/dev/null; systemctl stop systemd-timesyncd 2>/dev/null; echo M_NTPOFF'
        WaitFor 'M_NTPOFF' 5000 | Out-Null
        # 이전 잔여 정리
        SendLine 'rm -f /tmp/tc_journal.log /tmp/tc_mqtt.log /tmp/tc_run.out /tmp/tc_sl_filt.log /tmp/tc14.out; pkill -f "journalctl.*docker-loader.*-f" 2>/dev/null; pkill -f "mosquitto_sub.*emsp" 2>/dev/null; sleep 1; echo M_CLEANUP'
        WaitFor 'M_CLEANUP' 8000 | Out-Null
        # journal + mqtt 백그라운드 캡처
        SendLine 'journalctl -b 0 -u docker-loader -f --no-pager -o short-iso > /tmp/tc_journal.log 2>&1 &'
        Pump 400
        SendLine 'echo M_JOURNAL_PID_$!'
        WaitFor 'M_JOURNAL_PID_' 3000 | Out-Null
        SendLine "mosquitto_sub -h localhost -t 'emsp/#' -v > /tmp/tc_mqtt.log 2>&1 &"
        Pump 400
        SendLine 'echo M_MQTT_PID_$!'
        WaitFor 'M_MQTT_PID_' 3000 | Out-Null
        # 메인 TC 실행 (TC01~TC09, TC12, TC13 — TC02 70s + TC04 주입 포함 → 최대 60분)
        SendLine '/tmp/tc_system_log.sh > /tmp/tc_run.out 2>&1; echo M_MAIN_DONE_END'
        $ok = WaitFor 'M_MAIN_DONE_END' 3600000
        Write-Host ('MAIN_RUN matched=' + $ok)
        # TC11 이어서 실행 (nmon upload happy path — sleep 5 포함 약 40s)
        SendLine '/tmp/tc_system_log.sh --tc11 >> /tmp/tc_run.out 2>&1; echo M_TC11_DONE_END'
        $ok11 = WaitFor 'M_TC11_DONE_END' 120000
        Write-Host ('TC11_RUN matched=' + $ok11)
        # TC14 이어서 실행 (별도 출력에 append)
        SendLine '/tmp/tc_system_log.sh --tc14 >> /tmp/tc_run.out 2>&1; echo M_TC14_DONE_END'
        $ok14 = WaitFor 'M_TC14_DONE_END' 180000
        Write-Host ('TC14_RUN matched=' + $ok14)
        # 캡처 중단 + NTP 복원
        SendLine 'kill %1 %2 2>/dev/null; sleep 2; timedatectl set-ntp yes 2>/dev/null; echo M_STOPCAP'
        WaitFor 'M_STOPCAP' 10000 | Out-Null
        # journal 필터 (SL/task 관련만)
        SendLine 'grep -F -e "[SL]" -e "[SM]" -e "task_capture" -e "task_merge" -e "task_rotate" -e "delete_log" -e "clear_all_logs" -e "Created meta" -e "handle_request_get_log" /tmp/tc_journal.log > /tmp/tc_sl_filt.log; wc -l /tmp/tc_sl_filt.log /tmp/tc_run.out; echo M_FILT_DONE'
        WaitFor 'M_FILT_DONE' 30000 | Out-Null
        SendLine 'grep -F -e "emsp/system_log" -e "emsp/tc_runner/system_log" -e "emsp/sys_manager/system_log" /tmp/tc_mqtt.log > /tmp/tc_mqtt_filt.log; wc -l /tmp/tc_mqtt_filt.log; echo M_MQTTFILT_DONE'
        WaitFor 'M_MQTTFILT_DONE' 30000 | Out-Null
        # 결과 dump
        DumpSmall 'tc_run_out'   'cat /tmp/tc_run.out' | Out-Null
        DumpSmall 'tc_sl_filt'   'cat /tmp/tc_sl_filt.log' | Out-Null
        DumpSmall 'tc_mqtt_filt' 'cat /tmp/tc_mqtt_filt.log' | Out-Null
        Write-Host 'FULL_RUN_DONE'
    }
    elseif ($Phase -eq 'tc05') {
        CtrlC; CtrlC
        Pump 500
        EnsureLogin
        MakeQuiet
        SendLine 'rm -f /tmp/tc05.out; echo M_TC05_READY'
        WaitFor 'M_TC05_READY' 5000 | Out-Null
        SendLine '/tmp/tc_system_log.sh --tc05 > /tmp/tc05.out 2>&1; echo M_TC05_DONE_END'
        $ok = WaitFor 'M_TC05_DONE_END' 60000
        Write-Host ('TC05_RUN matched=' + $ok)
        DumpSmall 'tc05_out' 'cat /tmp/tc05.out' | Out-Null
        Write-Host 'TC05_DONE'
    }
    elseif ($Phase -eq 'tc14') {
        CtrlC; CtrlC
        Pump 1000
        EnsureLogin
        MakeQuiet
        # 이전 결과 정리
        SendLine 'rm -f /tmp/tc14.out /tmp/tc14_journal.log; echo M_TC14_READY'
        WaitFor 'M_TC14_READY' 5000 | Out-Null
        # journald 백그라운드 캡처 (task_capture_boot_log + task_merge 로그용)
        SendLine 'journalctl -b 0 -u docker-loader -f --no-pager -o cat > /tmp/tc14_journal.log 2>&1 &'
        Pump 500
        # TC14 실행 (90초 wait loop + 재시작 overhead → 최대 150초)
        SendLine '/tmp/tc_system_log.sh --tc14 > /tmp/tc14.out 2>&1; echo M_TC14_DONE_END'
        $ok = WaitFor 'M_TC14_DONE_END' 180000
        Write-Host ('TC14_RUN matched=' + $ok)
        # 캡처 중단
        SendLine 'kill %1 2>/dev/null; sleep 1; wc -l /tmp/tc14.out /tmp/tc14_journal.log; echo M_TC14_STOPCAP'
        WaitFor 'M_TC14_STOPCAP' 8000 | Out-Null
        # 결과 dump
        DumpSmall 'tc14_out'     'cat /tmp/tc14.out' | Out-Null
        DumpSmall 'tc14_journal' 'grep -E "task_capture|task_merge|staged|Single|Merging|toupload|BOOT_START" /tmp/tc14_journal.log | tail -40' | Out-Null
        # 상태 스냅샷
        SendLine 'echo M_SNAP_BEGIN; echo "---staging---"; ls -lh /edge/log/system/systemlog_*.log.xz 2>&1 || echo "(empty)"; echo "---toupload---"; ls -lht /edge/log/toupload/system/systemlog_*.log.xz 2>&1 | head -5; echo M_SNAP_END'
        WaitFor 'M_SNAP_END' 10000 | Out-Null
        Write-Host 'TC14_DONE'
    }
    else {
        Write-Host ('UNKNOWN_PHASE: ' + $Phase)
    }
}
catch {
    Write-Host ('ERROR: ' + $_)
    Add-Content -Path $LogFile -Value ("`n[ERROR] " + $_ + "`n") -Encoding UTF8
}
finally {
    if ($port.IsOpen) { $port.Close() }
    Add-Content -Path $LogFile -Value ("`n=== PHASE " + $Phase + " END " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " ===`n") -Encoding UTF8
}
