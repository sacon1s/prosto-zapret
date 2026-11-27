# autostart.ps1 - resident guardian v3: tray UI thread stays always responsive;
# all heavy work (health checks, switching, recalibration) runs in a background runspace.
. (Join-Path $PSScriptRoot 'common.ps1')
Write-Log 'boot: common loaded' $logFile
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Write-Log 'boot: winforms assemblies loaded' $logFile

# background step script: runs in its own runspace so the UI never blocks
$stepScript = {
    param([bool]$IsPaused, [string]$AppRoot)
    . (Join-Path $AppRoot 'tools\common.ps1')
    $logFile = 'guardian.log'
    if ($IsPaused) { return 'paused' }

    # manual tune or nightly recalibration running -> hands off completely
    $tuneRunning = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*tune.ps1*' }).Count -gt 0
    if ($tuneRunning) { return 'tune-running' }

    $cfg = Read-Config
    $cur = 1
    if ($cfg.ContainsKey('STRATEGY')) { try { $cur = [int]$cfg.STRATEGY } catch { } }

    # nightly recalibration (stateless via config)
    $on = '1'
    if ($cfg.ContainsKey('RECALIBRATE')) { $on = $cfg.RECALIBRATE }
    $hour = 4
    if ($cfg.ContainsKey('RECALIBRATE_HOUR')) { try { $hour = [Math]::Max(0, [Math]::Min(23, [int]$cfg.RECALIBRATE_HOUR)) } catch { } }
    $last = ''
    if ($cfg.ContainsKey('RECALIB_LAST')) { $last = $cfg.RECALIB_LAST }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($on -eq '1' -and $last -ne $today -and (Get-Date).Hour -eq $hour) {
        Set-ConfigKey -Key 'RECALIB_LAST' -Value $today
        Write-Log 'nightly recalibration started (hidden fast sweep)' $logFile
        Show-Toast -Title 'Prosto Zapret' -Text 'Ночная перекалибровка (~6 мин)...'
        Start-Process powershell -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Fast' -f (Join-Path $AppRoot 'tools\tune.ps1'))
        return 'recalib'
    }

    $ipset = $true
    if ($cfg.ContainsKey('IPSET')) { $ipset = ($cfg.IPSET -eq '1') }

    # foreign manager active -> passive
    foreach ($m in (Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue)) {
        $ip = (Get-ItemProperty $m.PSPath -ErrorAction SilentlyContinue).ImagePath
        if ($ip -and $ip -match 'ZapretGUI') {
            $svc = Get-Service -Name $m.PSChildName -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartType -ne 'Disabled') { return 'foreign' }
        }
    }

    # ensure alive
    $procs = Get-ZapretProcess
    if ($procs.Count -eq 0) {
        Set-IpsetActive -On $ipset
        $r = Start-Zapret -Num $cur -WaitSec 3
        if ($r.Ok) {
            Write-Log ('winws was dead -> started strategy {0}' -f $cur) $logFile
            Write-Stats 'start' $cur
            Show-Toast -Title 'Prosto Zapret' -Text ('Обход запущен (стратегия {0}).' -f $cur)
            Set-ConfigKey -Key 'LAST_CHECK' -Value (Get-Date).ToString('s')
            return 'started'
        }
        Write-Log 'start failed - will retry next tick' $logFile
        return 'start-failed'
    }

    # periodic health (state kept in config: LAST_CHECK / COOL_DOWN_UNTIL)
    $watch = 180
    if ($cfg.ContainsKey('WATCHDOG_INTERVAL')) { try { $watch = [Math]::Max(60, [int]$cfg.WATCHDOG_INTERVAL) } catch { } }
    $now = Get-Date
    $lastCheck = [datetime]::MinValue
    if ($cfg.ContainsKey('LAST_CHECK')) { try { $lastCheck = [datetime]$cfg.LAST_CHECK } catch { } }
    if ($cfg.ContainsKey('COOL_DOWN_UNTIL')) {
        try { if ($now -lt ([datetime]$cfg.COOL_DOWN_UNTIL)) { return 'cooldown' } } catch { }
    }
    if (((New-TimeSpan $lastCheck $now).TotalSeconds -lt $watch)) { return 'ok-wait' }
    Set-ConfigKey -Key 'LAST_CHECK' -Value $now.ToString('s')

    $t = Test-Targets -Timeout 4
    if ($t.All) { return 'healthy' }

    Write-Log ('health check failed (YT={0} DC={1} score={2}/6) - switching' -f $t.YouTube, $t.Discord, $t.Score) $logFile
    Set-IpsetActive -On $ipset
    $found = 0
    for ($k = 1; $k -le 6; $k++) {
        $strats = Get-Strategies
        $nums = @($strats | ForEach-Object { $_.Num })
        if ($nums.Count -eq 0) { break }
        $idx = [array]::IndexOf($nums, $cur)
        $alt = if ($idx -lt 0 -or $idx -ge $nums.Count - 1) { $nums[0] } else { $nums[$idx + 1] }
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
        Set-ConfigKey -Key 'STRATEGY' -Value ([string]$found)
        Set-ConfigKey -Key 'TUNED_AT' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm')
        Write-Log ('guardian picked strategy {0} ({1})' -f $found, (Get-StrategyName -Num $found)) $logFile
        Write-Stats 'switch' $found
        Show-Toast -Title 'Prosto Zapret' -Text ('Пропал доступ - переключился на стратегию {0}.' -f $found)
        return ('switched:' + $found)
    }
    $r = Start-Zapret -Num $cur -WaitSec 2
    Set-ConfigKey -Key 'COOL_DOWN_UNTIL' -Value ((Get-Date).AddMinutes(15).ToString('s'))
    Write-Log 'no better strategy found - restored saved one, cooldown 15 min' $logFile
    return 'cooldown-set'
}

# ---------- custom logo: dark rounded square + emerald lightning bolt ----------
function New-ZapretTrayIcon {
    try {
        $bmp = New-Object System.Drawing.Bitmap 64, 64
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        # rounded square background
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $r = 14; $w = 60; $h = 60; $x = 2; $y = 2
        $path.AddArc($x, $y, 2 * $r, 2 * $r, 180, 90)
        $path.AddArc($x + $w - 2 * $r, $y, 2 * $r, 2 * $r, 270, 90)
        $path.AddArc($x + $w - 2 * $r, $y + $h - 2 * $r, 2 * $r, 2 * $r, 0, 90)
        $path.AddArc($x, $y + $h - 2 * $r, 2 * $r, 2 * $r, 90, 90)
        $path.CloseFigure()
        $g.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(15, 23, 42))), $path)
        $g.DrawPath((New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(52, 211, 153), 2)), $path)
        # lightning bolt
        $pts = @(
            (New-Object System.Drawing.PointF 36, 8),
            (New-Object System.Drawing.PointF 22, 36),
            (New-Object System.Drawing.PointF 31, 36),
            (New-Object System.Drawing.PointF 25, 54),
            (New-Object System.Drawing.PointF 42, 27),
            (New-Object System.Drawing.PointF 32, 27),
            (New-Object System.Drawing.PointF 42, 8)
        )
        $g.FillPolygon((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(52, 211, 153))), $pts)
        $g.Dispose()
        $ico = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
        # keep a copy of the logo for the README/distro
        try {
            $logoPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'logo.png'
            $bmp.Save($logoPath, [System.Drawing.Imaging.ImageFormat]::Png)
        } catch { }
        return $ico
    } catch { return [System.Drawing.SystemIcons]::Shield }
}

# ---------- state ----------
$logFile = 'guardian.log'
Write-Log 'boot: winforms assemblies loaded' $logFile
$script:paused = $false
$script:iconAnnounced = $false
$script:stepPS = $null
$script:wasRunningAtStart = (Get-ZapretProcess).Count -gt 0
$timer = $null

# ---------- first start ----------
Write-Log 'boot: functions ready' $logFile
Start-Sleep -Seconds 5
$me = $PID
$others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -like '*autostart.ps1*' })
if ($others.Count -gt 0) {
    Write-Log ('another guardian found (pid {0}) - exiting' -f $others[0].ProcessId) $logFile
    exit 0
}
Write-Log 'boot: duplicate check passed' $logFile

# ---------- tray ----------
try {
    $form = New-Object Windows.Forms.Form
    $form.ShowInTaskbar = $false
    $form.WindowState = 'Minimized'
    $form.FormBorderStyle = 'None'
    $form.Opacity = 0

    $icon = New-Object Windows.Forms.NotifyIcon
    $icon.Icon = New-ZapretTrayIcon
    $icon.Text = 'Prosto Zapret - сторож'
    $icon.Visible = $true

    $menu = New-Object Windows.Forms.ContextMenuStrip
    $miStart = $menu.Items.Add('Включить обход');          $miStart.Tag = 'start'
    $miStop  = $menu.Items.Add('Выключить обход (пауза)'); $miStop.Tag = 'stop'
    [void]$menu.Items.Add('-')
    $miStatus = $menu.Items.Add('Статус');                 $miStatus.Tag = 'status'
    $miCheck  = $menu.Items.Add('Проверить сейчас');       $miCheck.Tag = 'checknow'
    $miTune   = $menu.Items.Add('Подбор настроек...');     $miTune.Tag = 'tune'
    $miGames  = $menu.Items.Add('Игры');                   $miGames.Tag = 'games'
    [void]$menu.Items.Add('-')
    $miCfg    = $menu.Items.Add('Настройки (config.ini)'); $miCfg.Tag = 'cfg'
    $miList   = $menu.Items.Add('Мои списки');             $miList.Tag = 'lists'
    $miClose  = $menu.Items.Add('Закрыть значок (обход продолжит работать)'); $miClose.Tag = 'close'
    $icon.ContextMenuStrip = $menu

    $games = [ordered]@{
        'Выключить игровой режим' = @('off', '', '')
        'CS2'                     = @('udp', '', '27000-27100')
        'Dota 2'                  = @('udp', '', '27000-27030')
        'Minecraft'               = @('tcp', '25565', '')
        'Valorant'                = @('udp', '', '7000-8000')
        'Warframe'                = @('udp', '', '4950-4960')
    }
    $script:games = $games
    foreach ($g in $games.Keys) {
        $mi = $menu.Items.Add(('Игра: {0}' -f $g)); $mi.Tag = 'game:' + $g
    }

    $icon.Add_DoubleClick({
        $procs = Get-ZapretProcess
        $state = 'выключен'
        if ($script:paused) { $state = 'на паузе' }
        elseif ($procs.Count -gt 0) { $state = 'работает' }
        $icon.ShowBalloonTip(4000, 'Prosto Zapret', ('Статус: {0}' -f $state), 'Info')
    })

    $icon.Add_MouseClick({
        param($s, $e)
        if ($e.Button -eq [Windows.Forms.MouseButtons]::Middle) {
            Start-Process explorer "/select,`"$((Join-Path $ListsDir 'list-general-user.txt'))`""
        }
    })

    $menu.Add_ItemClicked({
        param($s, $e)
        $tag = $e.Item.Tag
        if (-not $tag) { return }
        if ($tag -like 'game:*') {
            $gname = $tag.Substring(5)
            $v = $script:games[$gname]
            if ($v) {
                Set-ConfigKey -Key 'GAME_FILTER' -Value $v[0]
                if ($v[1]) { Set-ConfigKey -Key 'GAME_FILTER_TCP' -Value $v[1] }
                if ($v[2]) { Set-ConfigKey -Key 'GAME_FILTER_UDP' -Value $v[2] }
                Set-ConfigKey -Key 'LAST_CHECK' -Value (Get-Date).AddMinutes(-10).ToString('s')  # force health check -> restart with new ports
                $icon.ShowBalloonTip(3000, 'Игровой режим', ('Пресет: {0}. Применю при следующем тике (до 5 сек).' -f $gname), 'Info')
                Write-Stats 'game-preset' $gname
            }
            return
        }
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
                $icon.ShowBalloonTip(3000, 'Prosto Zapret', 'Обход на паузе (до следующего входа в Windows).', 'Info')
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
            'checknow' {
                Set-ConfigKey -Key 'LAST_CHECK' -Value (Get-Date).AddMinutes(-10).ToString('s')
                $icon.ShowBalloonTip(3000, 'Prosto Zapret', 'Проверю в ближайшие 5 секунд.', 'Info')
            }
            'tune' {
                Start-Process powershell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $PSScriptRoot 'tune.ps1'))
            }
            'cfg' { Start-Process notepad $ConfigFile }
            'lists' { Start-Process explorer "/select,`"$((Join-Path $ListsDir 'list-general-user.txt'))`"" }
            'close' { $icon.Visible = $false; $form.Close() }
        }
    })

    # ---------- background step: UI thread never blocks ----------
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 5000
    $timer.Add_Tick({
        try {
            if ($script:stepPS -and $script:stepPS.InvocationStateInfo.State -eq 'Running') { return }
            if (-not $script:iconAnnounced) {
                $script:iconAnnounced = $true
                $icon.ShowBalloonTip(5000, 'Prosto Zapret', 'Сторож в трее: значок молнии. Правый клик - меню.', 'Info')
                Write-Log 'tray icon announced' $logFile
            }
            if ($script:stepPS) { try { $script:stepPS.Dispose() } catch { } }
            $script:stepPS = [powershell]::Create()
            $null = $script:stepPS.AddScript($stepScript).AddArgument($script:paused).AddArgument($RootDir)
            $null = $script:stepPS.BeginInvoke()
        } catch {
            Write-Log ('tick error: {0}' -f $_.Exception.Message) $logFile
        }
    })
    $timer.Start()
    Write-Log 'boot: tray created, background worker ready, message pump starting' $logFile
} catch {
    Write-Log ('tray init failed: {0} - fallback to headless loop' -f $_.Exception.Message) $logFile
}

# ---------- headless fallback loop (only if tray failed) ----------
if (-not $timer) {
    Write-Log 'running headless loop' $logFile
    while ($true) {
        try {
            & $stepScript $script:paused $RootDir | Out-Null
        } catch { Write-Log ('loop error: {0}' -f $_.Exception.Message) $logFile }
        Start-Sleep -Seconds 30
    }
}

# wait for first tick to fire initial start via the background step:
# if nothing is running after ~8s and not paused, kick the step immediately
Start-Sleep -Seconds 8
if (-not $script:paused -and (Get-ZapretProcess).Count -eq 0) {
    try {
        if (-not ($script:stepPS -and $script:stepPS.InvocationStateInfo.State -eq 'Running')) {
            $script:stepPS = [powershell]::Create()
            $null = $script:stepPS.AddScript($stepScript).AddArgument($script:paused).AddArgument($RootDir)
            $null = $script:stepPS.BeginInvoke()
        }
    } catch { }
}

if ($timer) {
    Write-Log 'boot: message pump running' $logFile
    [Windows.Forms.Application]::Run($form)
    $icon.Visible = $false
    Write-Log 'guardian tray closed' $logFile
}