# install-autostart.ps1 - create scheduled task (hidden, at logon, highest rights)
# that runs the resident guardian (autostart.ps1) and start it now.
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Admin
$ErrorActionPreference = 'Stop'

$taskName = 'ZapretPro'
$guardian = Join-Path $PSScriptRoot 'autostart.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $guardian)
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

$exist = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($exist) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host '[i] Старая задача автозапуска удалена (обновляем).' -ForegroundColor DarkGray
}
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
# kill any leftover guardian processes so the fresh instance is guaranteed to start
$null = Stop-GuardianGraceful

# stop a guardian left from a previous install location so the new one takes over
$null = Stop-GuardianGraceful

Write-Host '[+] Задача автозапуска "ZapretPro" создана:' -ForegroundColor Green
Write-Host '    - старт скрытым при входе в Windows (права администратора);' -ForegroundColor Green
Write-Host '    - сторож следит: упал winws -> перезапуск, пропал доступ -> авто-смена стратегии.' -ForegroundColor Green

# warn about foreign winws managers - they will fight our guardian
$mgr = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue |
    Where-Object {
        $ip = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ImagePath
        $ip -and ($ip -match 'ZapretGUI')
    })
foreach ($m in $mgr) {
    $svc = Get-Service -Name $m.PSChildName -ErrorAction SilentlyContinue
    if ($svc -and $svc.StartType -ne 'Disabled') {
        Write-Host ''
        Write-Host '[!] ВНИМАНИЕ: обнаружена служба ZapretGUI (чужой менеджер winws, автозапуск).' -ForegroundColor Red
        Write-Host '    Она будет убивать наш winws и перезапускать свой. Двум менеджерам нельзя.' -ForegroundColor Red
        Write-Host '    Запустите extra\TAKE-CONTROL.bat, чтобы отключить её (обратимо: extra\RESTORE-ZAPRETGUI.bat).' -ForegroundColor Yellow
    }
}

Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 3
$g = @(Get-GuardianProcesses)
if ($g.Count -gt 0) { Write-Host '[+] Сторож запущен и уже работает.' -ForegroundColor Green }
else { Write-Host '[~] Сторож стартует (подождите до 20 секунд) - лог: logs\guardian.log' -ForegroundColor Yellow }
Write-Log 'autostart task installed'
exit 0
