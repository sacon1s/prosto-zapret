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
    $cfg = @{}
    if (Test-Path $ConfigFile) {
        foreach ($line in Get-Content $ConfigFile) {
            $t = $line.Trim()
            if ($t -eq '' -or $t.StartsWith('#') -or -not $t.Contains('=')) { continue }
            $k, $v = $t.Split('=', 2)
            $cfg[$k.Trim().ToUpper()] = $v.Trim()
        }
    }
    return $cfg
}

function Set-ConfigKey {
    param([string]$Key, [string]$Value)
    $Key = $Key.ToUpper()
    $lines = @()
    if (Test-Path $ConfigFile) { $lines = @(Get-Content $ConfigFile) }
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*' + [regex]::Escape($Key) + '\s*=') {
            $lines[$i] = "$Key=$Value"
            $found = $true
            break
        }
    }
    if (-not $found) { $lines += "$Key=$Value" }
    $lines | Set-Content $ConfigFile -Encoding ASCII
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
