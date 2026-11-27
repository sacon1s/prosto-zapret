# autostart.ps1 - resident guardian with tray icon: keeps zapret running and healthy.
# Started hidden by the scheduled task ("3 - АВТОЗАПУСК.bat"). WinForms message pump keeps tray alive.
. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$logFile = 'guardian.log'
$script:initialDelay = 15
$script:stepMs = 5000
$script:backoff = 0
$script:lastCheck = [datetime]::MinValue
$script:coolDown = 0
$script:paused = $false
$script:foreignWarned = $false
$script:foreignCheckedAt = [datetime]::MinValue
$script:foreignActive = $false
$script:recalibProc = $null
$script:lastRecalibDate = ''
$script:wasRunningAtStart = (Get-ZapretProcess).Count -gt 0

function Write-Stats {
    param([string]$Event, [string]$Detail = '')
    $csv = Join-Path $LogsDir 'strategy-history.csv'
    try {
        if (-not (Test-Path $csv)) { 'time,event,strategy,detail' | Set-Content $csv -Encoding ASCII }
        Add-Content -Path $csv -Value ('{0},{1},{2},{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Event, $Detail, '') -Encoding UTF8
    } catch { }
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

function Invoke-ForeignCheck {
    if ((New-TimeSpan $script:foreignCheckedAt (Get-Date)).TotalSeconds -lt 60) { return $script:foreignActive }
    $script:foreignCheckedAt = Get-Date
    $script:foreignActive = $false
    foreach ($m in (Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue)) {
        $ip = (Get-ItemProperty $m.PSPath -ErrorAction SilentlyContinue).ImagePath
        if ($ip -and $ip -match 'ZapretGUI') {
            $svc = Get-Service -Name $m.PSChildName -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartType -ne 'Disabled') { $script:foreignActive = $true }
        }
    }
    if ($script:foreignActive) { Write-Log 'foreign manager (ZapretGUI) active - guardian passive' $logFile }
    return $script:foreignActive
}

function Invoke-RecalibrateCheck {
    param([hashtable]$Cfg)
    # nightly silent recalibration: once a day at RECALIBRATE_HOUR, fast sweep, guardian pauses meanwhile
    $on = '1'
    if ($Cfg.ContainsKey('RECALIBRATE')) { $on = $Cfg.RECALIBRATE }
    if ($on -ne '1') { return }
    $hour = 4
    if ($Cfg.ContainsKey('RECALIBRATE_HOUR')) { try { $hour = [Math]::Min(23, [Math]::Max(0, [int]$Cfg.RECALIBRATE_HOUR)) } catch { } }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($script:lastRecalibDate -eq $today) { return }
    if ((Get-Date).Hour -ne $hour) { return }
    $script:lastRecalibDate = $today
    Write-Log ('nightly recalibration started (hidden, fast sweep)') $logFile
    Show-Toast -Title 'Prosto Zapret' -Text 'Ночная перекалибровка: перебираю стратегии (~6 мин)...'
    $script:recalibProc = Start-Process powershell -WindowStyle Hidden -PassThru `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Fast' -f (Join-Path $PSScriptRoot 'tune.ps1'))
}

function Invoke-GuardianStep {
    try {
        $cfg = Read-Config
        $cur = 1
        if ($cfg.ContainsKey('STRATEGY')) { try { $cur = [int]$cfg.STRATEGY } catch { } }
        $watch = 180
        if ($cfg.ContainsKey('WATCHDOG_INTERVAL')) { try { $watch = [Math]::Max(60, [int]$cfg.WATCHDOG_INTERVAL) } catch { } }
        $ipset = $true
        if ($cfg.ContainsKey('IPSET')) { $ipset = ($cfg.IPSET -eq '1') }

        Invoke-RecalibrateCheck -Cfg $cfg

        # recalibration is running -> guardian stays fully hands-off until it finishes
        if ($script:recalibProc) {
            $alive = $false
            try { $alive = -not $script:recalibProc.HasExited } catch { }
            if ($alive) { return }
            Write-Log 'recalibration finished - resuming guardian' $logFile
            Show-Toast -Title 'Prosto Zapret' -Text ('Перекалибровка завершена. Стратегия: {0}' -f (Get-StrategyName -Num $cur))
            $script:recalibProc = $null
            $script:lastCheck = [datetime]::MinValue
        }

        if ($script:paused) { return }
        if (Invoke-ForeignCheck) { return }

        $procs = Get-ZapretProcess
        if ($procs.Count -eq 0) {
            if ($script:backoff -gt 0) {
                $script:backoff--
            } else {
                Set-IpsetActive -On $ipset
                $r = Start-Zapret -Num $cur -WaitSec 3
                if ($r.Ok) {
                    Write-Log ('winws was dead -> started strategy {0} (pid {1})' -f $cur, $r.Proc.Id) $logFile
                    Write-Stats 'start' $cur
                    Show-Toast -Title 'Prosto Zapret' -Text ('Обход запущен (стратегия {0}).' -f $cur)
                    $script:lastCheck = [datetime]::MinValue
                } else {
                    Write-Log ('start failed: {0} - backoff' -f $r.Error) $logFile
                    $script:backoff = 4
                }
            }
            return
        }

        if (((New-TimeSpan $script:lastCheck (Get-Date)).TotalSeconds -lt $watch)) { return }
        if ($script:coolDown -gt 0) { $script:coolDown--; $script:lastCheck = Get-Date; return }
        $script:lastCheck = Get-Date
        $t = Test-Targets -Timeout 4
        if ($t.All) { return }

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
            Write-Stats 'switch' $cur
            Show-Toast -Title 'Prosto Zapret' -Text ('Пропал доступ - переключился на стратегию {0}.' -f $cur)
        } else {
            $r = Start-Zapret -Num $cur -WaitSec 2
            Write-Log 'no better strategy found - restored saved one' $logFile
            $script:coolDown = 5
        }
    } catch {
        Write-Log ('guardian error: {0}' -f $_.Exception.Message) $logFile
    }
}

# ---------- first start ----------
Write-Log 'guardian (tray) started' $logFile
Start-Sleep -Seconds $script:initialDelay
$me = $PID
$others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -like '*autostart.ps1*' })
if ($others.Count -gt 0) {
    Write-Log ('another guardian found (pid {0}) - exiting' -f $others[0].ProcessId) $logFile
    exit 0
}

# ---------- tray ----------
$form = New-Object Windows.Forms.Form
$form.ShowInTaskbar = $false
$form.WindowState = 'Minimized'
$form.FormBorderStyle = 'None'
$form.Opacity = 0
$form.AllowTransparency = $true

$icon = New-Object Windows.Forms.NotifyIcon
$icon.Icon = [System.Drawing.SystemIcons]::Shield
$icon.Text = 'Prosto Zapret - сторож'
$icon.Visible = $true

$menu = New-Object Windows.Forms.ContextMenuStrip
$miStart = $menu.Items.Add('Включить обход');      $miStart.Tag = 'start'
$miStop  = $menu.Items.Add('Выключить обход (пауза)'); $miStop.Tag = 'stop'
[void]$menu.Items.Add('-')
$miStatus = $menu.Items.Add('Статус');             $miStatus.Tag = 'status'
$miTune   = $menu.Items.Add('Подбор настроек...'); $miTune.Tag = 'tune'
$miGames  = $menu.Items.Add('Игры');               $miGames.Tag = 'games'
[void]$menu.Items.Add('-')
$miCfg    = $menu.Items.Add('Настройки (config.ini)'); $miCfg.Tag = 'cfg'
$miList   = $menu.Items.Add('Мои списки');         $miList.Tag = 'lists'
$miClose  = $menu.Items.Add('Закрыть значок (обход продолжит работать)'); $miClose.Tag = 'close'
$icon.ContextMenuStrip = $menu

$games = [ordered]@{
    'Выключить игровой режим' = @('off', '', '')
    'CS2'         = @('udp', '', '27000-27100')
    'Dota 2'      = @('udp', '', '27000-27030')
    'Minecraft'   = @('tcp', '25565', '')
    'Valorant'    = @('udp', '', '7000-8000')
    'Warframe'    = @('udp', '', '4950-4960')
}
$gamesMenu = New-Object Windows.Forms.ContextMenuStrip
foreach ($g in $games.Keys) {
    $mi = $gamesMenu.Items.Add($g); $mi.Tag = $g
}
$miGames.DropDownItems.Clear()
foreach ($mi in $gamesMenu.Items) { [void]$miGames.DropDownItems.Add($mi) }

$menu.Add_ItemClicked({
    param($s, $e)
    $tag = $e.Item.Tag
    if (-not $tag) { return }
    switch ($tag) {
        'start' {
            $script:paused = $false
            $cfg = Read-Config
            $cur = 1
            if ($cfg.ContainsKey('STRATEGY')) { try { $cur = [int]$cfg.STRATEGY } catch { } }
            $r = Start-Zapret -Num $cur -WaitSec 3
            if ($r.Ok) { $icon.ShowBalloonTip(3000, 'Prosto Zapret', 'Обход включён.', 'Info'); Write-Stats 'manual-start' $cur }
            else { $icon.ShowBalloonTip(3000, 'Prosto Zapret', 'Не удалось запустить!', 'Error') }
        }
        'stop' {
            $script:paused = $true
            Stop-Zapret | Out-Null
            $icon.ShowBalloonTip(3000, 'Prosto Zapret', 'Обход на паузе (до следующего входа в Windows или Включить).', 'Info')
            Write-Stats 'manual-stop' ''
        }
        'status' {
            $procs = Get-ZapretProcess
            $cfg = Read-Config
            $cur = 1
            if ($cfg.ContainsKey('STRATEGY')) { try { $cur = [int]$cfg.STRATEGY } catch { } }
            $state = 'выключен'
            if ($procs.Count -gt 0) { $state = 'работает' }
            if ($script:paused) { $state = 'на паузе' }
            $icon.ShowBalloonTip(4000, 'Prosto Zapret - статус',
                ('{0}; стратегия {1} ({2})' -f $state, $cur, (Get-StrategyName -Num $cur)), 'Info')
        }
        'tune' {
            Start-Process powershell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $PSScriptRoot 'tune.ps1'))
        }
        'cfg' { Start-Process notepad ($ConfigFile) }
        'lists' { Start-Process explorer "/select,`"$((Join-Path $ListsDir 'list-general-user.txt'))`"" }
        'close' { $icon.Visible = $false; $form.Close() }
        default {
            if ($games.Contains($tag)) {
                $v = $games[$tag]
                Set-ConfigKey -Key 'GAME_FILTER' -Value $v[0]
                if ($v[1]) { Set-ConfigKey -Key 'GAME_FILTER_TCP' -Value $v[1] }
                if ($v[2]) { Set-ConfigKey -Key 'GAME_FILTER_UDP' -Value $v[2] }
                $icon.ShowBalloonTip(3000, 'Игровой режим', ('Пресет: {0}. Перезапуск обхода...' -f $tag), 'Info')
                $cfg = Read-Config
                $cur = 1
                if ($cfg.ContainsKey('STRATEGY')) { try { $cur = [int]$cfg.STRATEGY } catch { } }
                $null = Stop-Zapret
                Set-IpsetActive -On $true
                Start-Zapret -Num $cur -WaitSec 3 | Out-Null
                Write-Stats 'game-preset' $tag
            }
        }
    }
})
$icon.Add_DoubleClick({
    $procs = Get-ZapretProcess
    $state = 'выключен'
    if ($script:paused) { $state = 'на паузе' }
    elseif ($procs.Count -gt 0) { $state = 'работает' }
    $icon.ShowBalloonTip(4000, 'Prosto Zapret', ('Статус: {0}' -f $state), 'Info')
})

# ---------- loop via winforms timer (keeps tray responsive) ----------
$timer = New-Object Windows.Forms.Timer
$timer.Interval = $script:stepMs
$timer.Add_Tick({ Invoke-GuardianStep })
$timer.Start()

if ($script:wasRunningAtStart) {
    Write-Log 'winws already running at guardian start' $logFile
} else {
    $cfg0 = Read-Config
    $cur0 = 1
    if ($cfg0.ContainsKey('STRATEGY')) { try { $cur0 = [int]$cfg0.STRATEGY } catch { } }
    Set-IpsetActive -On ($cfg0.IPSET -ne '0')
    $r = Start-Zapret -Num $cur0 -WaitSec 3
    if ($r.Ok) {
        Write-Log ('initial start strategy {0} (pid {1})' -f $cur0, $r.Proc.Id) $logFile
        Write-Stats 'initial' $cur0
    } else {
        Write-Log ('initial start failed: {0}' -f $r.Error) $logFile
    }
}

[Windows.Forms.Application]::Run($form)
$icon.Visible = $false
Write-Log 'guardian tray closed' $logFile
