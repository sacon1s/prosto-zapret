# autostart.ps1 - resident guardian v4: tray icon + visible status window.
# The UI thread only draws; every slow job (health checks, strategy switching) runs in a
# dedicated background runspace. Balloon tips are not used for feedback - Windows 11 drops
# them silently for scripts - so the guardian shows real windows instead.
#   -SelfTest : build the tray, open the status window and a notice once, save screenshots
#               to logs\selftest-*.png and exit. Never starts or stops anything.
param([switch]$SelfTest)
. (Join-Path $PSScriptRoot 'common.ps1')
$logFile = 'guardian.log'
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { [Windows.Forms.Application]::EnableVisualStyles() } catch { }

# ---------- compiled helpers: dark context menu + a popup that never steals focus ----------
$helperCs = @'
using System;
using System.Drawing;
using System.Windows.Forms;

namespace ProstoZapret {
    public class DarkTable : ProfessionalColorTable {
        public override Color ToolStripDropDownBackground { get { return Color.FromArgb(15, 23, 42); } }
        public override Color ImageMarginGradientBegin { get { return Color.FromArgb(15, 23, 42); } }
        public override Color ImageMarginGradientMiddle { get { return Color.FromArgb(15, 23, 42); } }
        public override Color ImageMarginGradientEnd { get { return Color.FromArgb(15, 23, 42); } }
        public override Color MenuBorder { get { return Color.FromArgb(51, 65, 85); } }
        public override Color MenuItemSelected { get { return Color.FromArgb(51, 65, 85); } }
        public override Color MenuItemBorder { get { return Color.FromArgb(51, 65, 85); } }
        public override Color SeparatorDark { get { return Color.FromArgb(51, 65, 85); } }
        public override Color SeparatorLight { get { return Color.FromArgb(15, 23, 42); } }
    }
    public class DarkRenderer : ToolStripProfessionalRenderer {
        public DarkRenderer() : base(new DarkTable()) { RoundedEdges = false; }
        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
            if (!e.Item.Selected) { e.TextColor = Color.FromArgb(226, 232, 240); }
            base.OnRenderItemText(e);
        }
        protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e) {
            e.ArrowColor = Color.FromArgb(148, 163, 184);
            base.OnRenderArrow(e);
        }
    }
    public class PassiveForm : Form {
        protected override bool ShowWithoutActivation { get { return true; } }
    }
}
'@
$script:hasPassive = $false
try {
    if (-not ('ProstoZapret.PassiveForm' -as [type])) {
        Add-Type -TypeDefinition $helperCs -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -ErrorAction Stop
    }
    $script:hasPassive = $true
} catch { Write-Log ('helper compile failed: {0}' -f $_.Exception.Message) $logFile }

# ---------- shared state (UI thread <-> worker runspace) ----------
$State = [hashtable]::Synchronized(@{})
$State.Paused = $false
$State.Busy = $false
$State.ReadOnly = $false
$State.LogFile = 'guardian.log'
$State.Queue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
$State.Notices = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
$State.Message = 'Сторож запущен'
$State.Health = 'ещё не проверял'
$State.HealthAt = ''
$State.HealthOk = $null
$State.Tunnel = ''
$State.TunnelAnnounced = $false
$State.HoldUntil = [datetime]::MinValue
$State.NextEnsureAt = [datetime]::MinValue
$State.NextHealthAt = (Get-Date).AddSeconds(45)
$State.LastAutoTuneAt = [datetime]::MinValue
$State.Games = [ordered]@{
    'Отключить игровой режим' = @('off', '', '')
    'CS2'                     = @('udp', '', '27000-27100')
    'Dota 2'                  = @('udp', '', '27000-27100')
    'Minecraft'               = @('tcp', '25565', '')
    'Valorant'                = @('udp', '', '7000-8000')
    'Warframe'                = @('udp', '', '4950,4955')
}

# ---------- worker: everything slow runs here, in its own runspace ----------
$workerStep = {
    param($State, [string]$AppRoot)
    try {
        . (Join-Path $AppRoot 'tools\common.ps1')
        $logFile = 'guardian.log'
        if ($State.ContainsKey('LogFile') -and $State.LogFile) { $logFile = [string]$State.LogFile }
        $cfg = Read-Config
        $cur = 1
        if ($cfg.ContainsKey('STRATEGY')) { try { $cur = [int]$cfg.STRATEGY } catch { } }
        $watch = 180
        if ($cfg.ContainsKey('WATCHDOG_INTERVAL')) { try { $watch = [Math]::Max(60, [int]$cfg.WATCHDOG_INTERVAL) } catch { } }
        $ipset = $true
        if ($cfg.ContainsKey('IPSET')) { $ipset = ($cfg.IPSET -eq '1') }
        $startTune = {
            Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Fast' -f (Join-Path $AppRoot 'tools\tune.ps1'))
        }

        # 1. read-only pass (diagnostics): look, never touch. Only the harmless check command runs.
        if ($State.ReadOnly) {
            $checked = $false
            while ($State.Queue.Count -gt 0) {
                if ([string]$State.Queue.Dequeue() -eq 'check') {
                    $checked = $true
                    $t = Test-Targets -Timeout 5
                    $State.Health = Get-HealthText $t
                    $State.HealthAt = (Get-Date).ToString('HH:mm')
                    $State.HealthOk = [bool]($t.YouTube -and $t.Discord -and $t.Media)
                    $State.Message = 'Проверка: всё работает'
                    if (-not ($t.YouTube -and $t.Discord)) { $State.Message = 'Проверка: есть проблемы' }
                }
            }
            $State.Tunnel = Get-TunnelText
            if (-not $checked) {
                $t = Test-Targets -Timeout 5
                $State.Health = Get-HealthText $t
                $State.HealthAt = (Get-Date).ToString('HH:mm')
                $State.Message = 'Самопроверка выполнена'
            }
            return
        }
        # 2. commands queued from the tray
        $hadCommand = $false
        while ($State.Queue.Count -gt 0) {
            $cmd = [string]$State.Queue.Dequeue()
            $hadCommand = $true
            Write-Log ('command: ' + $cmd) $logFile
            if ($cmd -eq 'check') {
                $t = Test-Targets -Timeout 5
                $State.Health = Get-HealthText $t
                $State.HealthAt = (Get-Date).ToString('HH:mm')
                $State.HealthOk = [bool]($t.YouTube -and $t.Discord -and $t.Media)
                if ($t.YouTube -and $t.Discord) { $State.Message = 'Проверка: всё работает' }
                else { $State.Message = 'Проверка: есть проблемы - ищу рабочую стратегию'; $State.NextHealthAt = [datetime]::MinValue }
            }
            elseif ($cmd -eq 'start') {
                $State.Paused = $false
                $State.HoldUntil = [datetime]::MinValue
                $r = Start-Zapret -Num $cur -WaitSec 3
                if ($r.Ok) {
                    Write-Stats 'manual-start' $cur
                    $State.Message = ('Обход включён — стратегия {0:D2}' -f $cur)
                    $State.NextHealthAt = (Get-Date).AddSeconds(20)
                } else { $State.Message = ('Не удалось запустить: {0}' -f $r.Error) }
            }
            elseif ($cmd -eq 'stop') {
                $null = Stop-Zapret
                Write-Stats 'manual-stop'
                $State.Message = 'Обход выключен (пауза)'
            }
            elseif ($cmd -like 'game:*') {
                $gname = $cmd.Substring(5)
                $preset = $State.Games[$gname]
                if ($preset) {
                    Set-ConfigKey -Key 'GAME_FILTER' -Value $preset[0]
                    Set-ConfigKey -Key 'GAME_FILTER_TCP' -Value $preset[1]
                    Set-ConfigKey -Key 'GAME_FILTER_UDP' -Value $preset[2]
                    Set-ConfigKey -Key 'GAME_FILTER_GAME' -Value $gname
                    $r = Start-Zapret -Num $cur -WaitSec 3
                    if ($r.Ok) { Write-Stats 'game-preset' $gname; $State.Message = ('Игровой режим: ' + $gname) }
                    else { $State.Message = ('Игровой режим не применился: {0}' -f $r.Error) }
                }
            }
        }
        if ($hadCommand) { return }

        # 3. paused by the user
        if ($State.Paused) { return }

        # 4. a full sweep is running (manual or automatic): hands off
        $tuneRunning = $false
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
            if ($p.ProcessId -ne $PID -and $p.CommandLine -match '-File\s+"?[^"]*\\tools\\tune\.ps1') { $tuneRunning = $true; break }
        }
        if ($tuneRunning) { return }

        # 5. tunnels: if the blocked sites travel through a VPN/ExitLag tunnel, the bypass is not their path
        $tun = Get-TunnelState
        $State.Tunnel = Get-TunnelText -T $tun
        if ($tun.Active) {
            if (-not $State.TunnelAnnounced) {
                $State.TunnelAnnounced = $true
                Write-Log 'tunnel carries the blocked sites (VPN/ExitLag) - guardian stops switching strategies' $logFile
                $State.Notices.Enqueue('Трафик идёт через VPN-туннель — сторож не трогает стратегии')
            }
        } else { $State.TunnelAnnounced = $false }

        # 6. keep winws alive
        if (@(Get-ZapretProcess).Count -eq 0) {
            Set-IpsetActive -On $ipset
            $r = Start-Zapret -Num $cur -WaitSec 3
            if ($r.Ok) {
                Write-Log ('winws was dead -> started strategy {0} (pid {1})' -f $cur, $r.Proc.Id) $logFile
                Write-Stats 'start' $cur
                $State.Message = ('Обход запущен — стратегия {0:D2}' -f $cur)
                $State.Notices.Enqueue($State.Message)
                $State.NextHealthAt = (Get-Date).AddSeconds(20)
            } else {
                Write-Log ('start failed: {0}' -f $r.Error) $logFile
                $State.Message = 'Не удалось запустить winws — повтор через минуту'
                $State.HoldUntil = (Get-Date).AddSeconds(60)
            }
            return
        }
        if ($tun.Active) { return }

        # 7. nightly recalibration - only when the current strategy is not fully healthy
        $recOn = '1'
        if ($cfg.ContainsKey('RECALIBRATE')) { $recOn = $cfg.RECALIBRATE }
        $recHour = 4
        if ($cfg.ContainsKey('RECALIBRATE_HOUR')) { try { $recHour = [int]$cfg.RECALIBRATE_HOUR } catch { } }
        $recLast = ''
        if ($cfg.ContainsKey('RECALIB_LAST')) { $recLast = $cfg.RECALIB_LAST }
        if ($recOn -eq '1' -and (Get-Date).Hour -eq $recHour -and $recLast -ne (Get-Date).ToString('yyyy-MM-dd')) {
            Set-ConfigKey -Key 'RECALIB_LAST' -Value (Get-Date).ToString('yyyy-MM-dd')
            if ($State.HealthOk -eq $true) {
                Write-Log 'recalibration: strategy is healthy - nothing to do' $logFile
            } else {
                Write-Log 'recalibration: not healthy - running a hidden fast sweep' $logFile
                $State.Notices.Enqueue('Ночная перекалибровка: перебираю стратегии (~6 мин)')
                & $startTune
            }
        }

        # 8. health
        if ((Get-Date) -lt $State.NextHealthAt) { return }
        if (-not (Test-BasicInternet)) {
            Write-Log 'no internet at all - not a blocking problem, skipping the health check' $logFile
            $State.Message = 'Нет интернета — проверка отложена'
            $State.NextHealthAt = (Get-Date).AddSeconds(90)
            return
        }
        $t = Test-Targets -Timeout 5
        $State.Health = Get-HealthText $t
        $State.HealthAt = (Get-Date).ToString('HH:mm')
        $State.HealthOk = [bool]($t.YouTube -and $t.Discord -and $t.Media)
        if ($t.YouTube -and $t.Discord) {
            $State.NextHealthAt = (Get-Date).AddSeconds($watch)
            return
        }
        $State.Message = 'Доступ пропал — ищу рабочую стратегию'
        Write-Log ('health check failed ({0}) - switching strategy' -f $State.Health) $logFile
        Set-IpsetActive -On $ipset
        $best = 0
        $bestScore = $t.Score
        $fixed = $false
        for ($k = 1; $k -le 6; $k++) {
            if ($State.Paused) { return }
            $nums = @(Get-Strategies | ForEach-Object { $_.Num })
            if ($nums.Count -eq 0) { break }
            $idx = [array]::IndexOf($nums, $cur)
            if ($idx -lt 0 -or $idx -ge $nums.Count - 1) { $alt = $nums[0] } else { $alt = $nums[$idx + 1] }
            $r = Start-Zapret -Num $alt -WaitSec 2
            if (-not $r.Ok) { $cur = $alt; continue }
            Clear-DnsCache
            $t2 = Test-Targets -Timeout 5
            Write-Log ('try {0:D2} ({1}) -> {2}' -f $alt, (Get-StrategyName -Num $alt), (Get-HealthText $t2)) $logFile
            if ($t2.YouTube -and $t2.Discord) { $best = $alt; $fixed = $true; break }
            if ($t2.Score -gt $bestScore) { $bestScore = $t2.Score; $best = $alt }
            $cur = $alt
        }
        if ($fixed) {
            Set-ConfigKey -Key 'STRATEGY' -Value ([string]$best)
            Set-ConfigKey -Key 'TUNED_AT' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm')
            Write-Stats 'switch' $best
            $State.Message = ('Доступ пропал — переключился на стратегию {0:D2}' -f $best)
            $State.Health = 'переключился, проверю через несколько минут'
            $State.Notices.Enqueue($State.Message)
            $State.NextHealthAt = (Get-Date).AddSeconds($watch)
        } else {
            if ($best -gt 0) { Set-ConfigKey -Key 'STRATEGY' -Value ([string]$best); Write-Stats 'switch' $best; $cur = $best }
            $null = Start-Zapret -Num $cur -WaitSec 2
            $lastAuto = [datetime]::MinValue
            if ($State.LastAutoTuneAt) { $lastAuto = $State.LastAutoTuneAt }
            if (((Get-Date) - $lastAuto).TotalHours -ge 2) {
                $State.LastAutoTuneAt = Get-Date
                Write-Log 'neighbour strategies did not help - running a full fast sweep' $logFile
                $State.Message = 'Ищу рабочую стратегию — полный подбор (~6 минут)'
                $State.Notices.Enqueue('Соседние стратегии не помогли — запускаю полный подбор')
                $State.NextHealthAt = [datetime]::MinValue
                & $startTune
            } else {
                Write-Log 'no working strategy found - will retry later' $logFile
                $State.Message = 'Рабочая стратегия пока не найдена — повторю через 10 минут'
                $State.NextHealthAt = (Get-Date).AddMinutes(10)
            }
        }
    } catch {
        try { Write-Log ('worker error: {0}' -f $_.Exception.Message) 'guardian.log' } catch { }
    } finally {
        $State.Busy = $false
        $State.NextEnsureAt = (Get-Date).AddSeconds(30)
    }
}

# ---------- look ----------
$script:cBg   = [System.Drawing.Color]::FromArgb(15, 23, 42)
$script:cCard = [System.Drawing.Color]::FromArgb(30, 41, 59)
$script:cLine = [System.Drawing.Color]::FromArgb(51, 65, 85)
$script:cFg   = [System.Drawing.Color]::FromArgb(226, 232, 240)
$script:cDim  = [System.Drawing.Color]::FromArgb(148, 163, 184)
$script:cOn   = [System.Drawing.Color]::FromArgb(52, 211, 153)
$script:cOff  = [System.Drawing.Color]::FromArgb(100, 116, 139)
$script:cWarn = [System.Drawing.Color]::FromArgb(251, 191, 36)

# logo = rounded tile + lightning bolt, drawn at any size
function New-LogoBitmap {
    param([int]$Size = 64, [System.Drawing.Color]$Tile = [System.Drawing.Color]::FromArgb(52, 211, 153))
    $k = [single]($Size / 64.0)
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $x = 2 * $k; $y = 2 * $k; $w = 60 * $k; $h = 60 * $k; $d = 28 * $k
    $path.AddArc($x, $y, $d, $d, 180, 90)
    $path.AddArc(($x + $w - $d), $y, $d, $d, 270, 90)
    $path.AddArc(($x + $w - $d), ($y + $h - $d), $d, $d, 0, 90)
    $path.AddArc($x, ($y + $h - $d), $d, $d, 90, 90)
    $path.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush $Tile), $path)
    $bolt = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $pts = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF ([single](36 * $k)), ([single](6 * $k))),
        (New-Object System.Drawing.PointF ([single](19 * $k)), ([single](36 * $k))),
        (New-Object System.Drawing.PointF ([single](29 * $k)), ([single](36 * $k))),
        (New-Object System.Drawing.PointF ([single](24 * $k)), ([single](58 * $k))),
        (New-Object System.Drawing.PointF ([single](46 * $k)), ([single](28 * $k))),
        (New-Object System.Drawing.PointF ([single](36 * $k)), ([single](28 * $k))),
        (New-Object System.Drawing.PointF ([single](46 * $k)), ([single](6 * $k)))
    )
    $g.FillPolygon((New-Object System.Drawing.SolidBrush $bolt), $pts)
    $g.Dispose()
    return $bmp
}
function New-LogoIcon {
    param([System.Drawing.Color]$Tile)
    $bmp = New-LogoBitmap 32 $Tile
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function New-Label {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text = '')
    $l = New-Object Windows.Forms.Label
    $l.Location = [System.Drawing.Point]::new($X, $Y)
    $l.Size = [System.Drawing.Size]::new($W, $H)
    $l.Text = $Text
    $l.BackColor = $script:cBg
    $l.ForeColor = $script:cFg
    return $l
}
function New-Button {
    param([string]$Text, [int]$X, [int]$W, [string]$Tag)
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text
    $b.Tag = $Tag
    $b.Location = [System.Drawing.Point]::new($X, 266)
    $b.Size = [System.Drawing.Size]::new($W, 34)
    $b.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderColor = $script:cLine
    $b.BackColor = $script:cCard
    $b.ForeColor = $script:cFg
    $b.Cursor = [Windows.Forms.Cursors]::Hand
    $b.Add_Click({ param($s, $e) Invoke-Action ([string]$s.Tag) })
    return $b
}

function Update-StatusWindow {
    $f = $script:statusForm
    if (-not $f -or $f.IsDisposed) { return }
    try {
        $running = (@(Get-Process -Name 'winws' -ErrorAction SilentlyContinue)).Count -gt 0
        if ($script:State.Paused) {
            $script:stState.Text = '○  Обход на паузе'
            $script:stState.ForeColor = $script:cWarn
        } elseif ($running) {
            $script:stState.Text = '●  Обход работает'
            $script:stState.ForeColor = $script:cOn
        } else {
            $script:stState.Text = '○  Обход выключен'
            $script:stState.ForeColor = $script:cOff
        }
        $cfg = Read-Config
        $cur = 1
        if ($cfg.ContainsKey('STRATEGY')) { try { $cur = [int]$cfg.STRATEGY } catch { } }
        if (-not $script:nameCache.ContainsKey($cur)) { $script:nameCache[$cur] = [string](Get-StrategyName -Num $cur) }
        $health = $script:State.Health
        if ($script:State.HealthAt) { $health = $script:State.HealthAt + ' — ' + $health }
        $tun = $script:State.Tunnel
        if (-not $tun) { $tun = 'определяю…' }
        $nl = [Environment]::NewLine
        $script:stInfo.Text = ('Стратегия   {0:D2} · {1}' -f $cur, $script:nameCache[$cur]) + $nl +
            ('Проверка    ' + $health) + $nl + ('Туннель     ' + $tun)
        $script:stMsg.Text = $script:State.Message
        if ($script:State.Message -match 'не удалось|проблем|пропал|Нет интернета|не нашлась|не применился') { $script:stMsg.ForeColor = $script:cWarn }
        else { $script:stMsg.ForeColor = $script:cOn }
    } catch { }
}

function Show-StatusWindow {
    try {
        if ($script:statusForm -and -not $script:statusForm.IsDisposed) {
            Update-StatusWindow
            $script:statusForm.TopMost = $true
            $script:statusForm.Activate()
            return
        }
        $f = New-Object Windows.Forms.Form
        $f.Text = 'Prosto Zapret'
        $f.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedSingle
        $f.MaximizeBox = $false
        $f.MinimizeBox = $false
        $f.ShowInTaskbar = $false
        $f.StartPosition = [Windows.Forms.FormStartPosition]::Manual
        $f.TopMost = $true
        $f.KeyPreview = $true
        $f.BackColor = $script:cBg
        $f.ForeColor = $script:cFg
        $f.Font = [System.Drawing.Font]::new('Segoe UI', [single]9)
        $f.ClientSize = [System.Drawing.Size]::new(470, 372)
        $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $f.Location = [System.Drawing.Point]::new([int]($wa.Right - $f.Width - 14), [int]($wa.Bottom - $f.Height - 14))

        $pic = New-Object Windows.Forms.PictureBox
        $pic.Location = [System.Drawing.Point]::new(18, 18)
        $pic.Size = [System.Drawing.Size]::new(44, 44)
        $pic.BackColor = $script:cBg
        $pic.Image = New-LogoBitmap 44
        $title = New-Label 72 16 300 28 'Prosto Zapret'
        $title.Font = [System.Drawing.Font]::new('Segoe UI', [single]15, [System.Drawing.FontStyle]::Bold)
        $ver = '—'
        $cfg0 = Read-Config
        if ($cfg0.ContainsKey('PRODUCT_VERSION')) { $ver = $cfg0.PRODUCT_VERSION }
        $sub = New-Label 74 44 300 20 ('v' + $ver + ' · сторож')
        $sub.ForeColor = $script:cDim
        $script:stState = New-Label 20 76 430 34 ''
        $script:stState.Font = [System.Drawing.Font]::new('Segoe UI', [single]13, [System.Drawing.FontStyle]::Bold)
        $script:stInfo = New-Label 20 118 430 92 ''
        $script:stInfo.Font = [System.Drawing.Font]::new('Segoe UI', [single]9.5)
        $script:stMsg = New-Label 20 212 430 46 ''
        $script:stMsg.Font = [System.Drawing.Font]::new('Segoe UI', [single]9.5, [System.Drawing.FontStyle]::Italic)
        $foot = New-Label 20 328 430 40 'Стратегии подбираются сами, доступ проверяется каждые 3 минуты.'
        $foot.ForeColor = $script:cDim
        $foot.Font = [System.Drawing.Font]::new('Segoe UI', [single]8)
        $btns = @(
            (New-Button 'Включить' 20 96 'start'),
            (New-Button 'Пауза' 124 84 'stop'),
            (New-Button 'Проверить сейчас' 216 148 'check'),
            (New-Button 'Подбор…' 372 78 'tune')
        )
        $f.Controls.AddRange([Windows.Forms.Control[]]@($pic, $title, $sub, $script:stState, $script:stInfo, $script:stMsg, $foot))
        $f.Controls.AddRange([Windows.Forms.Control[]]$btns)
        $f.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq [Windows.Forms.Keys]::Escape) { $script:statusForm.Close() } })
        $script:statusForm = $f
        Update-StatusWindow
        $f.Show()
        $f.Activate()
        Write-Log 'status window opened' $logFile
    } catch { Write-Log ('status window failed: {0}' -f $_.Exception.Message) $logFile }
}

# small card near the tray; replaces balloon tips. Never takes keyboard focus.
function Show-Notice {
    param([string]$Text, [int]$Ms = 4500)
    try {
        if (-not $script:noticeForm -or $script:noticeForm.IsDisposed) {
            if ($script:hasPassive) { $nf = New-Object ProstoZapret.PassiveForm } else { $nf = New-Object Windows.Forms.Form }
            $nf.FormBorderStyle = [Windows.Forms.FormBorderStyle]::None
            $nf.ShowInTaskbar = $false
            $nf.TopMost = $true
            $nf.StartPosition = [Windows.Forms.FormStartPosition]::Manual
            $nf.BackColor = $script:cBg
            $nf.ClientSize = [System.Drawing.Size]::new(400, 78)
            $pic = New-Object Windows.Forms.PictureBox
            $pic.Location = [System.Drawing.Point]::new(15, 15)
            $pic.Size = [System.Drawing.Size]::new(48, 48)
            $pic.BackColor = $script:cBg
            $pic.Image = New-LogoBitmap 48
            $lbl = New-Object Windows.Forms.Label
            $lbl.Location = [System.Drawing.Point]::new(76, 10)
            $lbl.Size = [System.Drawing.Size]::new(312, 58)
            $lbl.BackColor = $script:cBg
            $lbl.ForeColor = $script:cFg
            $lbl.Font = [System.Drawing.Font]::new('Segoe UI', [single]9.5)
            $nf.Controls.AddRange([Windows.Forms.Control[]]@($pic, $lbl))
            $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
            $d = 24; $w = $nf.Width - 1; $h = $nf.Height - 1
            $gp.AddArc(0, 0, $d, $d, 180, 90)
            $gp.AddArc(($w - $d), 0, $d, $d, 270, 90)
            $gp.AddArc(($w - $d), ($h - $d), $d, $d, 0, 90)
            $gp.AddArc(0, ($h - $d), $d, $d, 90, 90)
            $gp.CloseFigure()
            $nf.Region = [System.Drawing.Region]::new($gp)
            $script:noticePen = New-Object System.Drawing.Pen $script:cLine, 1
            $script:noticePath = $gp
            $nf.Add_Paint({ param($s, $e) try { $e.Graphics.DrawPath($script:noticePen, $script:noticePath) } catch { } })
            $tmr = New-Object Windows.Forms.Timer
            $tmr.Add_Tick({ try { $script:noticeTimer.Stop(); $script:noticeForm.Close() } catch { } })
            $close = { try { $script:noticeTimer.Stop(); $script:noticeForm.Close() } catch { } }
            $nf.Add_Click($close)
            $lbl.Add_Click($close)
            $pic.Add_Click($close)
            $script:noticeTimer = $tmr
            $script:noticeForm = $nf
            $script:noticeLabel = $lbl
        }
        $script:noticeLabel.Text = $Text
        $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $y = $wa.Bottom - $script:noticeForm.Height - 14
        if ($script:statusForm -and -not $script:statusForm.IsDisposed -and $script:statusForm.Visible) {
            $y = [Math]::Max($wa.Top, $script:statusForm.Top - $script:noticeForm.Height - 10)
        }
        $script:noticeForm.Location = [System.Drawing.Point]::new([int]($wa.Right - $script:noticeForm.Width - 14), [int]$y)
        if (-not $script:noticeForm.Visible) { $script:noticeForm.Show() }
        $script:noticeTimer.Interval = $Ms
        $script:noticeTimer.Stop()
        $script:noticeTimer.Start()
    } catch { Write-Log ('notice failed: {0}' -f $_.Exception.Message) $logFile }
}

function Update-TrayIcon {
    try {
        $running = (@(Get-Process -Name 'winws' -ErrorAction SilentlyContinue)).Count -gt 0
        $cfg = Read-Config
        $cur = 1
        if ($cfg.ContainsKey('STRATEGY')) { try { $cur = [int]$cfg.STRATEGY } catch { } }
        $st = 'off'
        $txt = 'обход выключен'
        if ($script:State.Paused) { $st = 'paused'; $txt = 'на паузе' }
        elseif ($running) { $st = 'on'; $txt = 'обход работает' }
        if ($st -ne $script:iconState) {
            $script:iconState = $st
            if ($st -eq 'on') { $script:icon.Icon = $script:icoOn }
            elseif ($st -eq 'paused') { $script:icon.Icon = $script:icoPaused }
            else { $script:icon.Icon = $script:icoOff }
        }
        $script:icon.Text = 'Prosto Zapret — ' + $txt + (' · стратегия {0:D2}' -f $cur)
        if ($script:miHead) { $script:miHead.Text = $script:icon.Text }
    } catch { }
}

function Start-Worker {
    # returns $true when a worker pass was started, $false when one is already running
    if ($script:State.Busy) { return $false }
    try {
        if (-not $script:workerRs) { return $false }
        if ($script:workerPs) {
            if ($script:workerPs.InvocationStateInfo.State -eq 'Running') { return $false }
            try { $null = $script:workerPs.EndInvoke($script:workerAsync) } catch { Write-Log ('worker ended with an error: {0}' -f $_.Exception.Message) $logFile }
            $script:workerPs.Dispose()
        }
        $script:State.Busy = $true
        $script:workerPs = [powershell]::Create()
        $script:workerPs.Runspace = $script:workerRs
        $null = $script:workerPs.AddScript($workerStep).AddArgument($script:State).AddArgument($RootDir)
        $script:workerAsync = $script:workerPs.BeginInvoke()
        return $true
    } catch {
        Write-Log ('worker start failed: {0}' -f $_.Exception.Message) $logFile
        $script:State.Busy = $false
        return $false
    }
}

function Invoke-Action {
    param([string]$Tag)
    try {
        Write-Log ('action: ' + $Tag) $logFile
        if ($Tag -eq 'status') { Show-StatusWindow; return }
        if ($Tag -eq 'close') { $script:icon.Visible = $false; $script:trayForm.Close(); return }
        if ($Tag -eq 'tune') {
            Start-Process -FilePath (Join-Path $RootDir '5 - ПОДБОР НАСТРОЕК.bat') -WorkingDirectory $RootDir
            return
        }
        if ($Tag -eq 'cfg') { Start-Process notepad.exe $ConfigFile; return }
        if ($Tag -eq 'lists') { Start-Process explorer.exe ('/select,"{0}"' -f (Join-Path $ListsDir 'list-general-user.txt')); return }
        if ($Tag -eq 'stop') {
            $script:State.Paused = $true
            $script:State.Message = 'Выключаю…'
            if (-not (Start-Worker)) { $null = Stop-Zapret; $script:State.Message = 'Обход выключен (пауза)' }
            Show-StatusWindow
            return
        }
        if ($Tag -eq 'start' -or $Tag -eq 'check' -or $Tag -like 'game:*') {
            $script:State.Message = 'Выполняю…'
            $script:State.Queue.Enqueue($Tag)
            $null = Start-Worker
            Show-StatusWindow
        }
    } catch { Write-Log ('action failed: {0}' -f $_.Exception.Message) $logFile }
}

# ---------- tray ----------
$script:pendingTag = ''
$onMenuClick = {
    param($s, $e)
    $tag = ''
    try { $tag = [string]$e.Item.Tag } catch { }
    if (-not $tag) { return }
    # defer until the menu has closed, otherwise a window opened here is drawn underneath it
    $script:pendingTag = $tag
    $script:deferTimer.Stop()
    $script:deferTimer.Start()
}
$onEnsureTick = {
    try {
        while ($script:State.Notices.Count -gt 0) { Show-Notice ([string]$script:State.Notices.Dequeue()) }
        Update-TrayIcon
        if (-not $script:announced) {
            $script:announced = $true
            Show-Notice 'Сторож в трее: плитка с молнией. Клик по ней открывает статус.' 6000
        }
        if ($script:State.Busy) { return }
        $need = ($script:State.Queue.Count -gt 0) -or ((Get-Date) -ge $script:State.NextEnsureAt)
        if (-not $script:State.Paused -and @(Get-Process -Name 'winws' -ErrorAction SilentlyContinue).Count -eq 0) {
            if ((Get-Date) -ge $script:State.HoldUntil) { $need = $true }
        }
        if ($need) { $null = Start-Worker }
    } catch { Write-Log ('tick error: {0}' -f $_.Exception.Message) $logFile }
}

function New-WorkerRunspace {
    try {
        $iss = [initialsessionstate]::CreateDefault2()
        foreach ($m in 'CimCmdlets', 'DnsClient', 'NetAdapter', 'NetTCPIP') {
            $mi = Get-Module -ListAvailable $m | Select-Object -First 1
            if ($mi) { $iss.ImportPSModule($mi.Path) }
        }
        $script:workerRs = [runspacefactory]::CreateRunspace($iss)
        $script:workerRs.Open()
        Write-Log 'worker runspace ready' $logFile
    } catch {
        Write-Log ('worker runspace failed, trying the default one: {0}' -f $_.Exception.Message) $logFile
        $script:workerRs = [runspacefactory]::CreateRunspace()
        $script:workerRs.Open()
    }
}

function New-Tray {
    $script:icoOn     = New-LogoIcon $script:cOn
    $script:icoOff    = New-LogoIcon $script:cOff
    $script:icoPaused = New-LogoIcon $script:cWarn
    $script:iconState = 'on'
    $script:nameCache = @{}
    $script:statusForm = $null
    $script:noticeForm = $null

    $script:trayForm = New-Object Windows.Forms.Form
    $script:trayForm.ShowInTaskbar = $false
    $null = $script:trayForm.Handle

    $icon = New-Object Windows.Forms.NotifyIcon
    $icon.Icon = $script:icoOn
    $icon.Text = 'Prosto Zapret'
    $script:icon = $icon

    $menu = New-Object Windows.Forms.ContextMenuStrip
    if ($script:hasPassive) { $menu.Renderer = New-Object ProstoZapret.DarkRenderer }
    $menu.Font = [System.Drawing.Font]::new('Segoe UI', [single]10)
    $script:miHead = $menu.Items.Add('Prosto Zapret')
    $script:miHead.Tag = 'status'
    $script:miHead.Font = [System.Drawing.Font]::new('Segoe UI', [single]10, [System.Drawing.FontStyle]::Bold)
    [void]$menu.Items.Add('-')
    $mi = $menu.Items.Add('Открыть статус');          $mi.Tag = 'status'
    $mi = $menu.Items.Add('Проверить сейчас');        $mi.Tag = 'check'
    [void]$menu.Items.Add('-')
    $mi = $menu.Items.Add('Включить обход');          $mi.Tag = 'start'
    $mi = $menu.Items.Add('Выключить обход (пауза)'); $mi.Tag = 'stop'
    [void]$menu.Items.Add('-')
    $mi = $menu.Items.Add('Подбор настроек…');        $mi.Tag = 'tune'
    $miGames = $menu.Items.Add('Игровой режим')
    $gameMenu = New-Object Windows.Forms.ContextMenuStrip
    if ($script:hasPassive) { $gameMenu.Renderer = New-Object ProstoZapret.DarkRenderer }
    foreach ($g in $State.Games.Keys) {
        $gi = $gameMenu.Items.Add([string]$g)
        $gi.Tag = 'game:' + $g
    }
    $miGames.DropDown = $gameMenu
    $gameMenu.Add_ItemClicked($onMenuClick)
    [void]$menu.Items.Add('-')
    $mi = $menu.Items.Add('Настройки (config.ini)');  $mi.Tag = 'cfg'
    $mi = $menu.Items.Add('Мои списки');              $mi.Tag = 'lists'
    $mi = $menu.Items.Add('Скрыть значок и остановить сторожа (обход продолжит работать до перезагрузки)'); $mi.Tag = 'close'

    $menu.Add_ItemClicked($onMenuClick)
    $icon.ContextMenuStrip = $menu
    $icon.Add_MouseClick({ param($s, $e) if ($e.Button -eq [Windows.Forms.MouseButtons]::Left -and $e.Clicks -eq 1) { Invoke-Action 'status' } })
    $script:menu = $menu

    $script:ensureTimer = New-Object Windows.Forms.Timer
    $script:ensureTimer.Interval = 5000
    $script:ensureTimer.Add_Tick($onEnsureTick)
    $script:refreshTimer = New-Object Windows.Forms.Timer
    $script:refreshTimer.Interval = 1000
    $script:refreshTimer.Add_Tick({ try { Update-StatusWindow } catch { } })
    $script:deferTimer = New-Object Windows.Forms.Timer
    $script:deferTimer.Interval = 80
    $script:deferTimer.Add_Tick({ try { $script:deferTimer.Stop(); Invoke-Action $script:pendingTag } catch { Write-Log ('deferred action failed: {0}' -f $_.Exception.Message) $logFile } })
    $icon.Visible = $true
    Update-TrayIcon
    Write-Log 'tray created' $logFile
}

# ---------- diagnostics: -SelfTest ----------
function Pump {
    param([int]$Ms)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Ms) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 30
    }
}
function Save-Shot {
    param([string]$Name)
    try {
        $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $w = [int][Math]::Min(1000, $wa.Width)
        $h = [int][Math]::Min(760, $wa.Height)
        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($wa.Right - $w, $wa.Bottom - $h, 0, 0, [System.Drawing.Size]::new($w, $h))
        $g.Dispose()
        $path = Join-Path $LogsDir ('selftest-' + $Name + '.png')
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        return $path
    } catch { return ('screenshot failed: ' + $_.Exception.Message) }
}
function Invoke-SelfTest {
    $script:logFile = 'selftest.log'
    Remove-Item (Join-Path $LogsDir 'selftest-*.png') -Force -ErrorAction SilentlyContinue
    $State.ReadOnly = $true
    $State.LogFile = 'selftest.log'
    New-WorkerRunspace
    New-Tray
    $script:ensureTimer.Start()
    $script:refreshTimer.Start()
    Pump 2500

    # 1. the same path a real click on the menu item takes
    $script:pendingTag = 'status'
    $script:deferTimer.Start()
    Pump 900
    $menu = $script:menu
    $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $menu.Show([System.Drawing.Point]::new([int]($wa.Right - 330), [int]($wa.Bottom - 470)))
    Pump 700
    $shotMenu = Save-Shot 'menu'
    $menu.Close()
    Pump 300

    # 2. a real check through the background worker
    $State.Queue.Enqueue('check')
    $null = Start-Worker
    $deadline = (Get-Date).AddSeconds(45)
    while ($State.Busy -and (Get-Date) -lt $deadline) { Pump 250 }
    Pump 1800
    $shotStatus = Save-Shot 'status'

    # 3. notice card
    Show-Notice 'Так выглядит уведомление сторожа — вместо всплывающих подсказок Windows' 9000
    Pump 800
    $shotNotice = Save-Shot 'notice'

    $visible = [bool]($script:statusForm -and -not $script:statusForm.IsDisposed -and $script:statusForm.Visible)
    Write-Host ('status window visible : ' + $visible)
    Write-Host ('worker message         : ' + $State.Message)
    Write-Host ('health                 : ' + $State.Health)
    Write-Host ('tunnel                 : ' + $State.Tunnel)
    Write-Host ('helper types compiled  : ' + $script:hasPassive)
    Write-Host ('notice visible         : ' + [bool]($script:noticeForm -and -not $script:noticeForm.IsDisposed -and $script:noticeForm.Visible))
    Write-Host ('menu screenshot        : ' + $shotMenu)
    Write-Host ('status screenshot      : ' + $shotStatus)
    Write-Host ('notice screenshot      : ' + $shotNotice)

    $script:ensureTimer.Stop(); $script:refreshTimer.Stop(); $script:deferTimer.Stop()
    if ($script:noticeForm) { $script:noticeForm.Close() }
    if ($script:statusForm) { $script:statusForm.Close() }
    $script:icon.Visible = $false
    $script:icon.Dispose()
    try { $script:workerRs.Close() } catch { }
}

# ================= boot =================
if ($SelfTest) { Invoke-SelfTest; return }
Write-Log 'guardian v4 starting' $logFile
Start-Sleep -Seconds 5
$others = @(Get-GuardianProcesses)
if ($others.Count -gt 0) {
    Write-Log ('another guardian is already running (pid {0}) - exiting' -f $others[0].ProcessId) $logFile
    exit 0
}
try {
    New-WorkerRunspace
    New-Tray
    try { (New-LogoBitmap 256).Save((Join-Path $RootDir 'logo.png'), [System.Drawing.Imaging.ImageFormat]::Png) } catch { }
    $script:ensureTimer.Start()
    $script:refreshTimer.Start()
    $null = Start-Worker
    Write-Log 'message pump running' $logFile
    [Windows.Forms.Application]::Run($script:trayForm)
} catch { Write-Log ('fatal: {0}' -f $_.Exception.Message) $logFile }
try { $script:icon.Visible = $false } catch { }
Write-Log 'guardian stopped' $logFile
