# stop.ps1 - stop zapret: kill the guardian first (so it does not restart winws), then winws
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Admin
$ErrorActionPreference = 'Continue'

# 1. stop resident guardians (otherwise they would restart winws within ~30s)
$g = @(Get-GuardianProcesses)
foreach ($p in $g) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
if ($g.Count) { Write-Host ('[+] Сторож остановлен ({0} шт.) - перезапуска не будет.' -f $g.Count) -ForegroundColor Green }

# 2. stop winws
$n = Stop-Zapret
if ($n -gt 0) {
    Write-Host '[+] zapret остановлен.' -ForegroundColor Green
    Write-Log 'stopped (with guardian)'
} else {
    Write-Host '[i] zapret и так не запущен.' -ForegroundColor DarkGray
}
if ($task = Get-ScheduledTask -TaskName 'ZapretPro' -ErrorAction SilentlyContinue) {
    Write-Host '[i] Автозапуск остался включён - zapret вернётся при следующем входе в Windows.' -ForegroundColor DarkGray
    Write-Host '    Отключить навсегда: файл "3 - АВТОЗАПУСК.bat".' -ForegroundColor DarkGray
}
exit 0
