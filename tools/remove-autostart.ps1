# remove-autostart.ps1 - remove scheduled task, stop guardian and winws
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Admin
$ErrorActionPreference = 'Continue'

$taskName = 'ZapretPro'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host '[+] Задача автозапуска удалена.' -ForegroundColor Green
} else {
    Write-Host '[i] Задача автозапуска не найдена.' -ForegroundColor DarkGray
}

$g = @(Get-GuardianProcesses)
if ($g.Count) {
    $null = Stop-GuardianGraceful
    Write-Host '[+] Сторож остановлен.' -ForegroundColor Green
}

$n = Stop-Zapret
if ($n -gt 0) { Write-Host '[+] zapret остановлен.' -ForegroundColor Green }
Write-Log 'autostart task removed'
exit 0
