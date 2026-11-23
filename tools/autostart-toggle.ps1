# autostart-toggle.ps1 - toggle the autostart task: installed -> remove, missing -> install
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Admin
$ErrorActionPreference = 'Continue'

$task = Get-ScheduledTask -TaskName 'ZapretPro' -ErrorAction SilentlyContinue
if ($task) {
    Write-Host ''
    Write-Host 'Автозапуск сейчас: ВКЛЮЧЁН -> снимаю с автозапуска...' -ForegroundColor Yellow
    Write-Host ''
    & (Join-Path $PSScriptRoot 'remove-autostart.ps1')
} else {
    Write-Host ''
    Write-Host 'Автозапуска сейчас: НЕТ -> ставлю на автозапуск...' -ForegroundColor Green
    Write-Host ''
    & (Join-Path $PSScriptRoot 'install-autostart.ps1')
}
exit 0
