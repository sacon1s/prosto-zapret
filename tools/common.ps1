# common.ps1 - shared library for Zapret Pro
# Dot-source this file: . "$PSScriptRoot\common.ps1"

$RootDir = Split-Path $PSScriptRoot -Parent
$BinDir = Join-Path $RootDir 'bin'
$ListsDir = Join-Path $RootDir 'lists'
$StrategiesDir = Join-Path $RootDir 'strategies'
$LogsDir = Join-Path $RootDir 'logs'
$ConfigFile = Join-Path $RootDir 'config.ini'
$WinwsExe = Join-Path $BinDir 'winws.exe'
$ScriptVersion = '1.0.0'

if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir | Out-Null }

# ---------- console: disable QuickEdit (mouse click freezes output until Enter) ----------
function Disable-QuickEdit {
    try {
        if ($Host.Name -ne 'ConsoleHost') { return }
        $sig = @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern System.IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);
'@
        $qe = Add-Type -MemberDefinition $sig -Name 'QuickEditKiller' -Namespace 'Win32Native' -PassThru -ErrorAction Stop
        $h = $qe::GetStdHandle(-10)
        $m = [uint32]0
        [void]$qe::GetConsoleMode($h, [ref]$m)
        $m = ($m -band ([uint32]'0xFFFFFFFF' -bxor 0x1)) -bor 0x80
        [void]$qe::SetConsoleMode($h, $m)
    } catch { }
}
Disable-QuickEdit

# ---------- admin ----------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-Admin)) {
        Write-Host '[!] Нужны права администратора. Запустите через .bat (он сам запросит UAC).' -ForegroundColor Red
        exit 9
    }
}

# ---------- config ----------
function Read-Config {
    # never throws: the UI reads the config every second while the worker may be rewriting it
    $cfg = @{}
    try {
        if ([IO.File]::Exists($ConfigFile)) {
            foreach ($line in [IO.File]::ReadAllLines($ConfigFile)) {
                $t = $line.Trim()
                if ($t -eq '' -or $t.StartsWith('#') -or -not $t.Contains('=')) { continue }
                $k, $v = $t.Split('=', 2)
                $cfg[$k.Trim().ToUpper()] = $v.Trim()
            }
        }
    } catch { }
    return $cfg
}

function Set-ConfigKey {
    # UTF-8 in and out (keeps Cyrillic comments) and a replace instead of an in-place rewrite,
    # so a reader never sees a half-written file.
    param([string]$Key, [string]$Value)
    $Key = $Key.ToUpper()
    $lines = New-Object System.Collections.Generic.List[string]
    try { if ([IO.File]::Exists($ConfigFile)) { foreach ($l in [IO.File]::ReadAllLines($ConfigFile, [Text.Encoding]::UTF8)) { $lines.Add($l) } } } catch { }
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*' + [regex]::Escape($Key) + '\s*=') { $lines[$i] = "$Key=$Value"; $found = $true; break }
    }
    if (-not $found) { $lines.Add("$Key=$Value") }
    try {
        $tmp = $ConfigFile + '.tmp'
        [IO.File]::WriteAllLines($tmp, $lines, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($ConfigFile)) { [IO.File]::Delete($ConfigFile) }
        [IO.File]::Move($tmp, $ConfigFile)
    } catch { }
}

# ---------- logging ----------
function Write-Log {
    param([string]$Message, [string]$File = 'zapret.log')
    $path = Join-Path $LogsDir $File
    try {
        if ((Test-Path $path) -and ((Get-Item $path).Length -gt 1MB)) {
            Move-Item $path ($path + '.old') -Force
        }
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -Path $path -Value "[$ts] $Message" -Encoding UTF8
    } catch { }
}

# ---------- strategies ----------
function Get-Strategies {
    $list = @()
    Get-ChildItem -Path $StrategiesDir -Filter '*.txt' | Where-Object { $_.Name -match '^\d+\.txt$' } |
    Sort-Object { [int]($_.BaseName) } | ForEach-Object {
        $num = [int]($_.BaseName)
        $first = (Get-Content $_.FullName -TotalCount 1)
        $name = $_.BaseName
        if ($first -like '#*') { $name = $first.Substring(1).Trim() }
        $list += @{ Num = $num; Name = $name; File = $_.FullName }
    }
    return $list
}

function Get-StrategyName {
    param([int]$Num)
    foreach ($s in (Get-Strategies)) { if ($s.Num -eq $Num) { return $s.Name } }
    return "?"
}

function Split-WinwsTokens {
    param([string]$Line)
    $tokens = New-Object System.Collections.Generic.List[string]
    $cur = New-Object Text.StringBuilder
    $inQuote = $false
    $started = $false
    foreach ($ch in $Line.ToCharArray()) {
        if ($ch -eq '"') {
            $inQuote = -not $inQuote
            [void]$cur.Append('"')
            $started = $true
        }
        elseif (($ch -eq ' ' -or $ch -eq "`t") -and -not $inQuote) {
            if ($started) {
                $tokens.Add($cur.ToString())
                $cur = New-Object Text.StringBuilder
                $started = $false
            }
        }
        else {
            [void]$cur.Append($ch)
            $started = $true
        }
    }
    if ($started) { $tokens.Add($cur.ToString()) }
    # strip quotes only when they wrap the whole token (CRT-style)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tokens) {
        if ($t.Length -ge 2 -and $t.StartsWith('"') -and $t.EndsWith('"')) {
            $out.Add($t.Substring(1, $t.Length - 2))
        } else { $out.Add($t) }
    }
    return $out
}

function ConvertTo-WinwsArgs {
    param([int]$Num)
    $info = $null
    foreach ($s in (Get-Strategies)) { if ($s.Num -eq $Num) { $info = $s; break } }
    if (-not $info) { return $null }
    $raw = @(Get-Content $info.File | Where-Object { $_ -notmatch '^\s*#' }) -join ' '
    if (-not $raw.Trim()) { return $null }

    $bin = $BinDir.TrimEnd('\') + '\'
    $lists = $ListsDir.TrimEnd('\') + '\'
    $raw = $raw.Replace('%BIN%', $bin).Replace('%LISTS%', $lists)

    $cfg = Read-Config
    $gf = 'off'
    if ($cfg.ContainsKey('GAME_FILTER')) { $gf = $cfg.GAME_FILTER.ToLower() }
    $gfTcp = '12'
    $gfUdp = '12'
    if ($gf -eq 'tcp' -or $gf -eq 'both') {
        $gfTcp = '1024-65535'
        if ($cfg.ContainsKey('GAME_FILTER_TCP') -and $cfg.GAME_FILTER_TCP) { $gfTcp = $cfg.GAME_FILTER_TCP }
    }
    if ($gf -eq 'udp' -or $gf -eq 'both') {
        $gfUdp = '1024-65535'
        if ($cfg.ContainsKey('GAME_FILTER_UDP') -and $cfg.GAME_FILTER_UDP) { $gfUdp = $cfg.GAME_FILTER_UDP }
    }
    $raw = $raw.Replace('%GameFilterTCP%', $gfTcp).Replace('%GameFilterUDP%', $gfUdp)

    return (Split-WinwsTokens $raw)
}

# ---------- ipset ----------
function Set-IpsetActive {
    param([bool]$On)
    $active = Join-Path $ListsDir 'ipset-all.txt'
    $srcName = 'ipset-empty.txt'
    if ($On) { $srcName = 'ipset-full.txt' }
    $src = Join-Path $ListsDir $srcName
    if (-not (Test-Path $src)) {
        if (-not (Test-Path $active)) { '' | Set-Content $active -Encoding ASCII }
        return
    }
    Copy-Item $src $active -Force
}

# ---------- process ----------
function Get-ZapretProcess {
    return @(Get-Process -Name 'winws' -ErrorAction SilentlyContinue)
}

function Stop-Zapret {
    $procs = Get-ZapretProcess
    if ($procs.Count -gt 0) {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
    }
    # safety net (also kills copies started elsewhere)
    Start-Process -FilePath 'taskkill.exe' -ArgumentList '/f /im winws.exe' -WindowStyle Hidden -ErrorAction SilentlyContinue -Wait
    return $procs.Count
}

function Start-Zapret {
    # returns @{ Ok = $bool ; Error = string ; Proc = process }
    param([int]$Num, [int]$WaitSec = 3)
    $args_ = ConvertTo-WinwsArgs -Num $Num
    if (-not $args_) {
        return @{ Ok = $false; Error = "стратегия $Num не найдена или пуста"; Proc = $null }
    }
    $null = Stop-Zapret
    $errLog = Join-Path $LogsDir 'winws-lasterr.log'
    if (Test-Path $errLog) { Remove-Item $errLog -Force -ErrorAction SilentlyContinue }
    $p = Start-Process -FilePath $WinwsExe -ArgumentList ($args_ -join ' ') `
        -WorkingDirectory $BinDir -WindowStyle Hidden -PassThru `
        -RedirectStandardError $errLog
    Start-Sleep -Seconds $WaitSec
    $alive = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
    if (-not $alive) {
        $err = ''
        if (Test-Path $errLog) { $err = (Get-Content $errLog | Out-String).Trim() }
        return @{ Ok = $false; Error = $err; Proc = $null }
    }
    return @{ Ok = $true; Error = ''; Proc = $p }
}

# ---------- connectivity checks ----------
$CheckTargets = [ordered]@{
    youtube = 'https://www.youtube.com'
    ytimg   = 'https://i.ytimg.com'
    gvideo  = 'https://redirector.googlevideo.com'
    discord = 'https://discord.com'
    media   = 'https://media.discordapp.net'
    gateway = 'https://gateway.discord.gg'
    cdn     = 'https://cdn.discordapp.com'
}

function Invoke-CurlCheck {
    # scriptblock-friendly single check (runs in runspace)
    param([string]$Url, [int]$Timeout)
    $code = '000'
    $ms = -1
    $exit = -1
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = & curl.exe -4 -s -o NUL -I -m $Timeout --connect-timeout $Timeout `
        -w '%{http_code}' $Url 2>$null
    $sw.Stop()
    $exit = $LASTEXITCODE
    $ms = [int]$sw.ElapsedMilliseconds
    if ($out -match '\d{3}') { $code = $Matches[0] }
    $ok = ($exit -eq 0) -or ($code -ne '000')
    return @{ Name = ''; Url = $Url; Code = $code; Ok = $ok; Ms = $ms; Exit = $exit }
}

function Test-Targets {
    # parallel HTTPS checks; returns @{ Results; YouTube; Discord; All; Score }
    param([int]$Timeout = 5)
    $pool = [runspacefactory]::CreateRunspacePool(1, 8)
    $pool.Open()
    $jobs = @()
    foreach ($k in $CheckTargets.Keys) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        $null = $ps.AddScript({
            param($Url, $Timeout)
            $code = '000'; $ms = -1; $exit = -1
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $out = & curl.exe -4 -s -o NUL -I -m $Timeout --connect-timeout $Timeout -w '%{http_code}' $Url 2>$null
            $sw.Stop()
            $exit = $LASTEXITCODE
            $ms = [int]$sw.ElapsedMilliseconds
            if ($out -match '\d{3}') { $code = $Matches[0] }
            $ok = ($exit -eq 0) -or ($code -ne '000')
            return @{ Code = $code; Ok = [bool]$ok; Ms = $ms; Exit = $exit }
        }).AddArgument($CheckTargets[$k]).AddArgument($Timeout)
        $jobs += @{ Key = $k; Ps = $ps; Handle = $ps.BeginInvoke() }
    }
    $results = @{}
    foreach ($j in $jobs) {
        $res = $j.Ps.EndInvoke($j.Handle)
        $j.Ps.Dispose()
        $results[$j.Key] = $res[0]
    }
    $pool.Close()

    $yt = $results['youtube'].Ok -and ($results['ytimg'].Ok -or $results['gvideo'].Ok)
    # discord is "working" when main + gateway/cdn respond; media counts too (images in chat)
    $dc = $results['discord'].Ok -and ($results['gateway'].Ok -or $results['cdn'].Ok -or $results['media'].Ok)
    $score = 0
    foreach ($k in $results.Keys) { if ($results[$k].Ok) { $score++ } }
    return @{
        Results   = $results
        YouTube   = [bool]$yt
        Discord   = [bool]$dc
        Media     = [bool]$results['media'].Ok
        All       = [bool]($yt -and $dc)
        Score     = $score
    }
}

function Get-CheckVerdictLine {
    param($T)
    $parts = @()
    foreach ($k in $T.Results.Keys) {
        $r = $T.Results[$k]
        $mark = if ($r.Ok) { 'OK' } else { '--' }
        $parts += ('{0}:{1}({2}ms)' -f $k, $mark, $r.Ms)
    }
    return ($parts -join ' ')
}

function Clear-DnsCache {
    try { Clear-DnsClientCache -ErrorAction SilentlyContinue } catch { }
}

# ---------- toasts ----------
function Show-Toast {
    param([string]$Title, [string]$Text)
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $t = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $txt = $t.GetElementsByTagName('text')
        [void]$txt.Item(0).AppendChild($t.CreateTextNode($Title))
        [void]$txt.Item(1).AppendChild($t.CreateTextNode($Text))
        $n = [Windows.UI.Notifications.ToastNotification]::new($t)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show($n)
    } catch { }
}

# ---------- real YouTube stream flow check ----------
function Test-YouTubeStream {
    # innertube player -> googlevideo range request; proves actual video bytes flow, not just the site
    $res = @{ Ok = $false; Code = '000'; Bytes = 0; Ms = -1; Note = '' }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $body = '{"context":{"client":{"clientName":"ANDROID","clientVersion":"19.09.37","androidSdkVersion":30,"hl":"ru"}},"videoId":"dQw4w9WgXcQ","contentCheckOk":true,"racyCheckOk":true}'
        $resp = Invoke-RestMethod -Uri 'https://www.youtube.com/youtubei/v1/player?key=AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 10
        $fmt = $null
        if ($resp.streamingData -and $resp.streamingData.formats) { $fmt = @($resp.streamingData.formats)[0] }
        if (-not $fmt -and $resp.streamingData -and $resp.streamingData.adaptiveFormats) {
            $fmt = @($resp.streamingData.adaptiveFormats | Where-Object { $_.url } | Select-Object -First 1)
        }
        if (-not $fmt -or -not $fmt.url) { $res.Note = 'player: no stream url'; return $res }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $out = & curl.exe -4 -s -o NUL -m 15 --connect-timeout 8 -r 0-100000 $fmt.url -w '%{http_code} %{size_download}' 2>$null
        $sw.Stop()
        $res.Ms = [int]$sw.ElapsedMilliseconds
        $parts = (($out | Out-String).Trim() -split '\s+')
        if ($parts.Count -ge 2) {
            $res.Code = $parts[0]
            [void][int]::TryParse($parts[1], [ref]$res.Bytes)
        }
        $res.Ok = (($res.Code -eq '200') -or ($res.Code -eq '206')) -and ($res.Bytes -gt 50000)
        if (-not $res.Ok) { $res.Note = ('googlevideo HTTP ' + $res.Code) }
    } catch { $res.Note = $_.Exception.Message }
    return $res
}

# ---------- strategy history ----------
function Write-Stats {
    param([string]$Event, [string]$Strategy = '')
    $csv = Join-Path $LogsDir 'strategy-history.csv'
    try {
        if (-not (Test-Path $csv)) { 'time,event,strategy,detail' | Set-Content $csv -Encoding ASCII }
        Add-Content -Path $csv -Value ('{0},{1},{2},{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Event, $Strategy, '') -Encoding UTF8
    } catch { }
}

# ---------- finding the guardian without false matches ----------
function Get-GuardianProcesses {
    # Strict match: only real guardians (-File ...\tools\autostart.ps1). A loose "*autostart.ps1*"
    # also matches install-autostart.ps1 itself and monitoring commands - with fatal results.
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '-File\s+"?[^"]*\\tools\\autostart\.ps1"?\s*$' })
    } catch { return @() }
}

# ---------- tunnels: VPN, ExitLag ----------

# ---------- graceful guardian stop (a force-killed guardian leaves a dead tray icon behind) ----------
function Stop-GuardianGraceful {
    param([int]$TimeoutSec = 12)
    $procs = @(Get-GuardianProcesses)
    if ($procs.Count -eq 0) { return 0 }
    $flag = Join-Path $LogsDir 'exit-requested'
    try { New-Item -ItemType File -Path $flag -Force | Out-Null } catch { }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-GuardianProcesses).Count -eq 0) {
            Remove-Item $flag -Force -ErrorAction SilentlyContinue
            return $procs.Count
        }
        Start-Sleep -Milliseconds 300
    }
    foreach ($p2 in (Get-GuardianProcesses)) { Stop-Process -Id $p2.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item $flag -Force -ErrorAction SilentlyContinue
    return $procs.Count
}
function Get-TunnelState {
    # Active = the blocked sites themselves travel through a non-physical adapter (full-tunnel VPN).
    # ExitLag only tunnels game servers, so with it alone Active stays $false.
    if ($script:TunnelCache -and ((New-TimeSpan $script:TunnelCacheAt (Get-Date)).TotalSeconds -lt 120)) { return $script:TunnelCache }
    $r = @{ Active = $false; Kind = ''; Adapter = ''; ExitLag = $false; UpVirtual = @() }
    try { $r.ExitLag = (@(Get-Process -Name 'ExitLag' -ErrorAction SilentlyContinue)).Count -gt 0 } catch { }
    try {
        $ads = @(Get-NetAdapter -ErrorAction SilentlyContinue)
        $r.UpVirtual = @($ads | Where-Object { $_.Status -eq 'Up' -and -not $_.HardwareInterface -and $_.Name -notmatch 'Loopback|vEthernet|Bluetooth|WAN Miniport|Local Area Connection' } | ForEach-Object { $_.Name })
        $ip = $null
        try { $ip = [string]((Resolve-DnsName 'www.youtube.com' -Type A -ErrorAction Stop | Where-Object { $_.IPAddress -match '^\d+\.' } | Select-Object -First 1).IPAddress) } catch { }
        if ($ip) {
            $route = @(Find-NetRoute -RemoteIPAddress $ip -ErrorAction Stop) | Where-Object { $_.DestinationPrefix } | Select-Object -First 1
            $ifa = $ads | Where-Object { $_.ifIndex -eq $route.InterfaceIndex } | Select-Object -First 1
            if ($ifa -and -not $ifa.HardwareInterface) {
                $r.Active = $true
                $r.Adapter = $ifa.Name
                $r.Kind = 'vpn'
                if (($ifa.Name + ' ' + $ifa.InterfaceDescription) -match 'exitlag') { $r.Kind = 'exitlag' }
            }
        }
    } catch { }
    $script:TunnelCache = $r
    $script:TunnelCacheAt = Get-Date
    return $r
}

function Get-TunnelText {
    param($T)
    if (-not $T) { $T = Get-TunnelState }
    if ($T.Active) {
        if ($T.Kind -eq 'exitlag') { return ('ExitLag ведёт и эти сайты через туннель (' + $T.Adapter + ') - сторож не меняет стратегии') }
        return ('VPN-туннель ' + $T.Adapter + ' - сайты идут через него, сторож не меняет стратегии')
    }
    if ($T.ExitLag -and @($T.UpVirtual).Count -gt 0) { return ('ExitLag запущен, туннель: ' + (@($T.UpVirtual) -join ', ') + ' - совместим, сайты идут напрямую') }
    if ($T.ExitLag) { return 'нет, ExitLag запущен - совместим, всё идёт напрямую' }
    if (@($T.UpVirtual).Count -gt 0) { return ('есть адаптеры (' + (@($T.UpVirtual) -join ', ') + '), но сайты идут напрямую') }
    return 'нет - всё идёт напрямую'
}

function Get-HealthText {
    param($T)
    if (-not $T) { return 'ещё не проверял' }
    if ($T.YouTube -and $T.Discord -and $T.Media) { return 'всё работает (YouTube, Discord, картинки)' }
    return ('YouTube: ' + $(if ($T.YouTube) { 'да' } else { 'нет' }) + ' · Discord: ' + $(if ($T.Discord) { 'да' } else { 'нет' }) + ' · картинки: ' + $(if ($T.Media) { 'да' } else { 'нет' }))
}

function Test-BasicInternet {
    # a neutral, never-blocked reference host: tells "the site is blocked" from "the link is down"
    try {
        $out = & curl.exe -4 -s -o NUL -m 4 --connect-timeout 3 -w '%{http_code}' 'https://ya.ru/' 2>$null
        return ((($out | Out-String).Trim()) -match '^[23]\d\d$')
    } catch { return $false }
}
