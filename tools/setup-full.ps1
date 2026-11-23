# setup-full.ps1 - one-shot full setup:
# 1) unlock WinDivert driver service + disable foreign winws managers (ZapretGUI)
# 2) find a strategy that fixes Discord media (images)
# 3) install autostart + guardian
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Admin
$ErrorActionPreference = 'Continue'
$transcript = Join-Path $LogsDir 'setup-full.log'
Start-Transcript -Path $transcript -Force | Out-Null

Write-Host ''
Write-Host '=== Zapret Pro: полная настройка ===' -ForegroundColor Cyan

# --- 0. kill stuck previous setups, guardians and winws FIRST: nothing may hold the driver ---
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and ($_.CommandLine -like '*setup-full.ps1*' -or $_.CommandLine -like '*autostart.ps1*') } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$null = Stop-Zapret
Start-Sleep -Seconds 2
Write-Host '[+] Прошлые сетапы/сторожа/winws остановлены.' -ForegroundColor Green

# --- 1. driver: remove stale WinDivert registration (winws recreates it from our bin) ---
$wdReg = 'HKLM:\SYSTEM\CurrentControlSet\Services\WinDivert'
$wd = Get-ItemProperty $wdReg -ErrorAction SilentlyContinue
if ($wd) {
    $ip = $wd.ImagePath
    $ours = $ip -and ($ip -match [regex]::Escape($RootDir))
    if (-not $ours) {
        # non-blocking stop via sc.exe (Stop-Service can hang if a process still holds the driver)
        & sc.exe stop WinDivert 2>$null | Out-Null
        & sc.exe delete WinDivert | Out-Null
        Write-Host ('[+] Устаревшая регистрация WinDivert удалена (была: ' + $ip + '). Наша пересоздастся при запуске.') -ForegroundColor Green
    }
    elseif ($wd.Start -eq 4) {
        # ours but disabled -> set to demand start
        & sc.exe config WinDivert start= demand | Out-Null
        Write-Host '[+] Служба WinDivert была отключена - переведена на запуск по требованию.' -ForegroundColor Green
    }
}

# --- 2. foreign managers: stop + disable (reversible via extra\RESTORE-ZAPRETGUI.bat) ---
$mgrNames = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue |
    Where-Object {
        $ip2 = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ImagePath
        $ip2 -and ($ip2 -match 'ZapretGUI')
    } | Select-Object -ExpandProperty PSChildName)
foreach ($n in $mgrNames) {
    $wasStart = (Get-ItemProperty ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $n) -ErrorAction SilentlyContinue).Start
    Stop-Service -Name $n -Force -ErrorAction SilentlyContinue
    Set-Service -Name $n -StartupType Disabled -ErrorAction SilentlyContinue
    Set-ConfigKey -Key ('RESTORED_SERVICE_START_' + $n) -Value ([string]$wasStart)
    Write-Host ('[+] Служба ' + $n + ' остановлена и отключена (откат: extra\RESTORE-ZAPRETGUI.bat).') -ForegroundColor Green
}

# --- 3. media fix (also saves the best strategy) ---
& (Join-Path $PSScriptRoot 'fix-discord-media.ps1')

# --- 4. autostart + guardian ---
& (Join-Path $PSScriptRoot 'install-autostart.ps1')

# --- 5. final verification ---
Write-Host ''
Write-Host '=== Итоговая проверка ===' -ForegroundColor Cyan
Clear-DnsCache
$t = Test-Targets -Timeout 6
foreach ($k in $t.Results.Keys) {
    $res = $t.Results[$k]
    $col = 'Green'; $mark = 'OK  '
    if (-not $res.Ok) { $col = 'Red'; $mark = 'FAIL' }
    Write-Host ('  {0,-8} {1} {2} {3}ms (HTTP {4})' -f $k, $mark, $CheckTargets[$k].PadRight(38), $res.Ms, $res.Code) -ForegroundColor $col
}
if ($t.Media) { Write-Host '[+] Картинки Discord (media.discordapp.net): РАБОТАЮТ' -ForegroundColor Green }
else { Write-Host '[x] media.discordapp.net всё ещё закрыт - смотрите logs\media-fix.log' -ForegroundColor Red }
$procs = Get-ZapretProcess
if ($procs.Count) { Write-Host ('[+] winws жив (PID ' + $procs[0].Id + '), сторож установлен.') -ForegroundColor Green }
Write-Host 'Готово. Перезапустите Discord (Ctrl+R).' -ForegroundColor Cyan
Stop-Transcript | Out-Null
exit 0
