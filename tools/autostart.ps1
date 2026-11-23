# autostart.ps1 - resident guardian: keeps zapret running and healthy.
# Started hidden by the scheduled task (AUTOSTART-INSTALL.bat). Loops forever.
. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Continue'

$logFile = 'guardian.log'
$initialDelay = 20
$stepSleep = 30
$backoff = 0
$lastCheck = [datetime]::MinValue
$foreignWarned = $false
$coolDown = 0
Write-Log 'guardian started' $logFile
Start-Sleep -Seconds $initialDelay

# avoid two guardians
$me = $PID
$others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -like '*autostart.ps1*' })
if ($others.Count -gt 0) {
    Write-Log ('another guardian found (pid {0}) - exiting' -f $others[0].ProcessId) $logFile
    exit 0
}

function Get-NextStrategy {
    param([int]$Current)
    $strats = Get-Strategies
    $nums = @($strats | ForEach-Object { $_.Num })
    if ($nums.Count -eq 0) { return 0 }
    $idx = [array]::IndexOf($nums, $Current)
    if ($idx -lt 0 -or $idx -ge $nums.Count - 1) { return $nums[0] }
    return $nums[$idx + 1]
}

while ($true) {
    try {
        $cfg = Read-Config
        $cur = 1
        if ($cfg.ContainsKey('STRATEGY')) { try { $cur = [int]$cfg.STRATEGY } catch { } }
        $watch = 180
        if ($cfg.ContainsKey('WATCHDOG_INTERVAL')) { try { $watch = [Math]::Max(60, [int]$cfg.WATCHDOG_INTERVAL) } catch { } }
        $ipset = $true
        if ($cfg.ContainsKey('IPSET')) { $ipset = ($cfg.IPSET -eq '1') }

        # 1) ensure winws is alive - unless a foreign manager (ZapretGUI) is active:
        #    fighting it would cause a kill-war, so guardian stays passive and logs it
        $foreign = $false
        foreach ($m in (Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue)) {
            $ip = (Get-ItemProperty $m.PSPath -ErrorAction SilentlyContinue).ImagePath
            if ($ip -and $ip -match 'ZapretGUI') {
                $svc = Get-Service -Name $m.PSChildName -ErrorAction SilentlyContinue
                if ($svc -and $svc.StartType -ne 'Disabled') { $foreign = $true }
            }
        }
        if ($foreign) {
            if ((Get-Date).Minute % 10 -eq 0 -and -not $foreignWarned) {
                Write-Log 'foreign manager (ZapretGUI) active - guardian passive. Run TAKE-CONTROL.bat to disable it.' $logFile
                $script:foreignWarned = $true
            }
            Start-Sleep -Seconds $stepSleep
            continue
        }
        $procs = Get-ZapretProcess
        if ($procs.Count -eq 0) {
            if ($backoff -gt 0) {
                $backoff--
            } else {
                Set-IpsetActive -On $ipset
                $r = Start-Zapret -Num $cur -WaitSec 3
                if ($r.Ok) {
                    Write-Log ('winws was dead -> started strategy {0} (pid {1})' -f $cur, $r.Proc.Id) $logFile
                    $lastCheck = [datetime]::MinValue
                } else {
                    Write-Log ('start failed: {0} - backoff' -f $r.Error) $logFile
                    $backoff = 4
                }
            }
        }
        elseif (((New-TimeSpan $lastCheck (Get-Date)).TotalSeconds -ge $watch)) {
            # 2) periodic health check
            if ($coolDown -gt 0) { $coolDown--; $lastCheck = Get-Date }
            else {
            $lastCheck = Get-Date
            $t = Test-Targets -Timeout 4
            if (-not $t.All) {
                Write-Log ('health check failed (YT={0} DC={1} score={2}/6) - switching strategy' -f $t.YouTube, $t.Discord, $t.Score) $logFile
                Set-IpsetActive -On $ipset
                $found = 0
                for ($k = 1; $k -le 6; $k++) {
                    $alt = Get-NextStrategy -Current $cur
                    if ($alt -le 0) { break }
                    $r = Start-Zapret -Num $alt -WaitSec 2
                    if (-not $r.Ok) { $cur = $alt; continue }
                    Clear-DnsCache
                    $t2 = Test-Targets -Timeout 4
                    Write-Log ('try {0:D2} ({1}) -> score {2}/6' -f $alt, (Get-StrategyName -Num $alt), $t2.Score) $logFile
                    if ($t2.All) { $found = $alt; break }
                    if ($t2.Score -ge $t.Score) { $found = $alt; $t = $t2 }
                    $cur = $alt
                }
                if ($found -gt 0) {
                    $cur = $found
                    Set-ConfigKey -Key 'STRATEGY' -Value ([string]$cur)
                    Set-ConfigKey -Key 'TUNED_AT' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm')
                    Write-Log ('guardian picked strategy {0} ({1})' -f $cur, (Get-StrategyName -Num $cur)) $logFile
                } else {
                    $r = Start-Zapret -Num $cur -WaitSec 2
                    Write-Log 'no better strategy found - restored saved one' $logFile
                    # nothing improved: cool down so we don't churn strategies every cycle
                    $coolDown = 5
                }
            }
            }
        }
    } catch {
        Write-Log ('guardian loop error: {0}' -f $_.Exception.Message) $logFile
    }
    Start-Sleep -Seconds $stepSleep
}
