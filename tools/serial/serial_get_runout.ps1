$ErrorActionPreference = 'Continue'
$LogFile = "C:\Users\hyunje.sung\AppData\Local\Temp\tc_console.log"
$port = New-Object System.IO.Ports.SerialPort('COM7', 115200, 'None', 8, 'One')
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
        if ($global:matchBuf.Length -gt 32768) {
            $global:matchBuf = $global:matchBuf.Substring($global:matchBuf.Length - 16384)
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

try {
    $port.Open()
    Start-Sleep -Milliseconds 300
    [void]$port.ReadExisting()
    SendLine ''
    Pump 800
    SendLine ''
    Pump 800
    SendLine 'dmesg -n 1'
    Pump 400
    SendLine 'export PS1="P> "'
    Pump 400
    SendLine 'stty -echo'
    Pump 400
    $global:matchBuf = ''
    Start-Sleep -Milliseconds 500
    [void]$port.ReadExisting()
    Add-Content -Path $LogFile -Value "`n=== GET_RUNOUT START ===`n" -Encoding UTF8

    SendLine 'echo XXXX_RUN_BEG; cat /tmp/tc_run.out; echo XXXX_RUN_END'
    WaitFor 'XXXX_RUN_END' 30000 | Out-Null
    SendLine 'echo XXXX_LS_BEG; ls -la /edge/log/toupload/system/ 2>&1; echo XXXX_LS_END'
    WaitFor 'XXXX_LS_END' 10000 | Out-Null
    Write-Host 'DONE'
}
catch { Write-Host "ERROR: $_" }
finally { if ($port.IsOpen) { $port.Close() } }
