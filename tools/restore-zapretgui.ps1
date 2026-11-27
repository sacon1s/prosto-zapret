# restore-zapretgui.ps1 - undo take-control: re-enable the previously disabled service
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Admin
$ErrorActionPreference = 'Continue'

$cfg = Read-Config
$names = @()
foreach ($k in $cfg.Keys) { if ($k -like 'RESTORED_SERVICE_START_*') { $names += ($k -replace '^RESTORED_SERVICE_START_', '') } }

if ($names.Count -eq 0) {
    Write-Host '[i] Отключённых служб не найдено - возвращать нечего.' -ForegroundColor DarkGray
    exit 0
}

foreach ($n in $names) {
    $start = 2
    $key = 'RESTORED_SERVICE_START_' + $n
    if ($cfg.ContainsKey($key)) { try { $start = [int]$cfg.$key } catch { } }
    if ($start -eq 4) { $start = 3 }  # do not restore "disabled"
    try {
        Set-Service -Name $n -StartupType $start -ErrorAction Stop
        Start-Service -Name $n -ErrorAction SilentlyContinue
        Write-Host ('[+] Служба ' + $n + ' возвращена (Start=' + $start + ') и запущена.') -ForegroundColor Green
        Set-ConfigKey -Key $key -Value ''
    } catch {
        Write-Host ('[!] ' + $n + ': ' + $_.Exception.Message) -ForegroundColor Yellow
    }
}

# stop our winws and guardian so the returned manager takes over
$null = Stop-Zapret
$g = @(Get-GuardianProcesses)
foreach ($p in $g) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
Write-Host '[i] Наш сторож и winws остановлены - управление снова у ZapretGUI.' -ForegroundColor DarkGray
Write-Log 'restore-zapretgui: service re-enabled'
exit 0
