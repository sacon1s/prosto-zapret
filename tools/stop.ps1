# stop.ps1 - stop zapret
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Admin
$n = Stop-Zapret
if ($n -gt 0) {
    Write-Host ('[+] zapret остановлен (было процессов: {0})' -f $n) -ForegroundColor Green
    Write-Log 'stopped'
} else {
    Write-Host '[i] zapret и так не запущен.' -ForegroundColor DarkGray
}
exit 0
