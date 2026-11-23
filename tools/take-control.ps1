# take-control.ps1 - stop & disable third-party winws managers (ZapretGUI etc.)
# so that THIS build (guardian) becomes the single manager of winws. Reversible.
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Admin
$ErrorActionPreference = 'Continue'

Write-Host ''
Write-Host '=== Zapret Pro: передача управления ===' -ForegroundColor Cyan

# find services whose ImagePath references ZapretGUI (other winws managers)
$svcNames = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue |
    Where-Object {
        $ip = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ImagePath
        $ip -and ($ip -match 'ZapretGUI')
    } | Select-Object -ExpandProperty PSChildName)

if ($svcNames.Count -eq 0) {
    Write-Host '[i] Службы-менеджеры winws (ZapretGUI) не найдены - конфликтов нет.' -ForegroundColor DarkGray
} else {
    foreach ($n in $svcNames) {
        $wasStart = (Get-ItemProperty ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $n) -ErrorAction SilentlyContinue).Start
        Write-Host ('Останавливаю и отключаю службу: ' + $n) -ForegroundColor DarkGray
        Stop-Service -Name $n -Force -ErrorAction SilentlyContinue
        Set-Service -Name $n -StartupType Disabled -ErrorAction SilentlyContinue
        Set-ConfigKey -Key 'RESTORED_SERVICE' -Value $n
        Set-ConfigKey -Key ('RESTORED_SERVICE_START_' + $n) -Value ([string]$wasStart)
        Write-Host ('[+] Служба отключена (была Start=' + $wasStart + '). Вернуть: RESTORE-ZAPRETGUI.bat') -ForegroundColor Green
    }
}

# also remove leftover stale WinDivert service registrations from old installs (harmless cleanup)
$wd = Get-Service -Name 'WinDivert' -ErrorAction SilentlyContinue
if ($wd -and $wd.Status -eq 'Running') { Stop-Service -Name 'WinDivert' -Force -ErrorAction SilentlyContinue }
if ($wd) {
    $ip = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\WinDivert' -ErrorAction SilentlyContinue).ImagePath
    if ($ip -and $ip -notmatch [regex]::Escape($RootDir)) {
        & sc.exe delete WinDivert | Out-Null
        Write-Host '[i] Устаревшая регистрация драйвера WinDivert (чужой путь) удалена - наша пересоздастся при запуске.' -ForegroundColor DarkGray
    }
}

# make sure no foreign winws remains, then start ours
Start-Sleep -Seconds 2
$null = Stop-Zapret
$cfg = Read-Config
$strat = 1
if ($cfg.ContainsKey('STRATEGY')) { try { $strat = [int]$cfg.STRATEGY } catch { } }
$ipset = $true
if ($cfg.ContainsKey('IPSET')) { $ipset = ($cfg.IPSET -eq '1') }
Set-IpsetActive -On $ipset
$r = Start-Zapret -Num $strat -WaitSec 3
if ($r.Ok) {
    Write-Host ('[+] zapret запущен под управлением сторожа (стратегия {0:D2}, PID {1}).' -f $strat, $r.Proc.Id) -ForegroundColor Green
    Write-Log 'take-control: foreign manager disabled, zapret started'
} else {
    Write-Host ('[!] Не удалось запустить zapret: ' + $r.Error) -ForegroundColor Yellow
}

# reminder about guardian
$task = Get-ScheduledTask -TaskName 'ZapretPro' -ErrorAction SilentlyContinue
if (-not $task) {
    Write-Host '[~] Сторож ещё не установлен - запустите AUTOSTART-INSTALL.bat, чтобы всё работало само.' -ForegroundColor Yellow
}
Write-Host ''
Write-Host 'Проверьте Discord/YouTube. Откат (вернуть ZapretGUI): RESTORE-ZAPRETGUI.bat' -ForegroundColor DarkGray
exit 0
