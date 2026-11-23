# uninstall.ps1 - remove everything Zapret Pro created (winws, task, guardian, media pins)
# and restore previously disabled foreign managers (ZapretGUI) if we disabled them.
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Admin
$ErrorActionPreference = 'Continue'

Write-Host ''
Write-Host '=== Zapret Pro: полное удаление ===' -ForegroundColor Cyan

# 1. scheduled task + guardian
$task = Get-ScheduledTask -TaskName 'ZapretPro' -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName 'ZapretPro' -Confirm:$false
    Write-Host '[+] Задача автозапуска удалена.' -ForegroundColor Green
}
$g = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*autostart.ps1*' })
foreach ($p in $g) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
if ($g.Count) { Write-Host '[+] Сторож остановлен.' -ForegroundColor Green }

# 2. winws
$n = Stop-Zapret
if ($n -gt 0) { Write-Host '[+] winws остановлен.' -ForegroundColor Green }

# 3. media pins in hosts
& (Join-Path $PSScriptRoot 'fix-media-hosts.ps1') -Action remove

# 4. restore foreign managers we disabled
$cfg = Read-Config
foreach ($k in @($cfg.Keys)) {
    if ($k -like 'RESTORED_SERVICE_START_*') {
        $name = $k -replace '^RESTORED_SERVICE_START_', ''
        $start = 3
        try { $start = [int]$cfg[$k] } catch { }
        if ($start -eq 4) { $start = 3 }
        try {
            Set-Service -Name $name -StartupType $start -ErrorAction Stop
            Start-Service -Name $name -ErrorAction SilentlyContinue
            Write-Host ('[+] Служба ' + $name + ' возвращена и запущена.') -ForegroundColor Green
        } catch { Write-Host ('[!] ' + $name + ': ' + $_.Exception.Message) -ForegroundColor Yellow }
    }
}

Write-Host ''
Write-Host 'Готово. Саму папку Zapret Pro удалите вручную, когда захотите.' -ForegroundColor Cyan
Write-Log 'uninstalled'
exit 0
