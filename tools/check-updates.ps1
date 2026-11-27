# check-updates.ps1 - check GitHub releases for a newer version; offer Y/N self-update.
# -InfoOnly: just print a line if update exists (used by 4 - СТАТУС.bat)
param([switch]$InfoOnly)
. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Continue'

function Get-VersionObj {
    param([string]$v)
    $v = ($v -replace '^v', '').Trim()
    if ($v -match '^(\d+)\.(\d+)\.(\d+)([a-z]?)$') {
        return @{ a = [int]$Matches[1]; b = [int]$Matches[2]; c = [int]$Matches[3]; d = $Matches[4] }
    }
    return $null
}

function Test-Newer {
    param($n, $o)
    if (-not $n) { return $false }
    if (-not $o) { return $true }
    if ($n.a -ne $o.a) { return $n.a -gt $o.a }
    if ($n.b -ne $o.b) { return $n.b -gt $o.b }
    if ($n.c -ne $o.c) { return $n.c -gt $o.c }
    if ($n.d -eq $o.d) { return $false }
    if ($o.d -eq '') { return $false }
    if ($n.d -eq '') { return $true }
    return $n.d -gt $o.d
}

$cfg = Read-Config
$localVer = '0.0'
if ($cfg.ContainsKey('PRODUCT_VERSION')) { $localVer = $cfg.PRODUCT_VERSION }

# latest release tag + asset (anonymous API)
$api = 'https://api.github.com/repos/sacon1s/prosto-zapret/releases/latest'
$raw = (& curl.exe -4 -s -m 10 --connect-timeout 5 -H 'User-Agent: prosto-zapret' $api 2>$null | Out-String).Trim()
$tag = ''
$assetUrl = ''
try {
    $j = $raw | ConvertFrom-Json
    $tag = $j.tag_name
    $asset = @($j.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1)
    if ($asset) { $assetUrl = $asset[0].browser_download_url }
} catch { }

if (-not $tag) { if (-not $InfoOnly) { Write-Host '[i] Проверка апдейтов: GitHub недоступен, пропускаю.' -ForegroundColor DarkGray }; exit 0 }

$nLocal = Get-VersionObj $localVer
$nRemote = Get-VersionObj $tag
$skip = ''
if ($cfg.ContainsKey('SKIPPED_VERSION')) { $skip = $cfg.SKIPPED_VERSION }

$isNewer = Test-Newer (Get-VersionObj $tag) (Get-VersionObj $localVer)
$isSkipped = ($tag -eq $skip)

if (-not $isNewer -or $isSkipped) {
    if ($InfoOnly) { } else { Write-Host ('[i] Версия ' + $localVer + ' актуальна (latest: ' + $tag + ').') -ForegroundColor DarkGray }
    exit 0
}

if ($InfoOnly) {
    Write-Host ('[~] Доступен апдейт ' + $tag + ' (у вас ' + $localVer + '). Скачается при запуске "1 - ВКЛЮЧИТЬ ЗАПРЕТ.bat" или вручную: tools\check-updates.ps1') -ForegroundColor Yellow
    exit 0
}

Write-Host ''
Write-Host ('[*] Доступен новый апдейт: ' + $tag + ' (у вас ' + $localVer + ')') -ForegroundColor Cyan
Write-Host 'Скачать сейчас? Нажмите Y (да) или N (позже) - есть 20 секунд...' -ForegroundColor Cyan
$answer = 'timeout'
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 20) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -in @('Y', 'D')) { $answer = 'y'; break }
            if ($k.Key -eq 'N') { $answer = 'n'; break }
        }
        Start-Sleep -Milliseconds 120
    }
} catch { $answer = 'timeout' }

if ($answer -ne 'y') {
    if ($answer -eq 'n') { Set-ConfigKey -Key 'SKIPPED_VERSION' -Value $tag }  # explicit N - stop nagging until next version
    Write-Host '[i] Хорошо, продолжаю без обновления.' -ForegroundColor DarkGray
    exit 0
}

if (-not $assetUrl) { Write-Host '[x] У релиза нет zip-архива - скачайте вручную с Releases.' -ForegroundColor Red; exit 1 }

Assert-Admin
Write-Host 'Скачиваю...' -ForegroundColor DarkGray
$tmpDir = Join-Path $LogsDir ('selfupdate-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory $tmpDir | Out-Null
$zip = Join-Path $tmpDir 'update.zip'
$null = & curl.exe -4 -sL --max-time 300 -o $zip $assetUrl
if (-not (Test-Path $zip) -or (Get-Item $zip).Length -lt 100000) {
    Write-Host '[x] Скачивание не удалось.' -ForegroundColor Red
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
$ex = Join-Path $tmpDir 'ex'
Expand-Archive -Path $zip -DestinationPath $ex -Force
$srcRoot = @((Get-ChildItem $ex -Directory) | Select-Object -First 1).FullName
if (-not $srcRoot) { Write-Host '[x] Архив повреждён.' -ForegroundColor Red; exit 1 }

# was zapret running -> restart after update
$wasRunning = (Get-ZapretProcess).Count -gt 0
$null = Stop-Zapret

# copy everything except user data
foreach ($item in (Get-ChildItem $srcRoot)) {
    $name = $item.Name
    if ($name -in @('config.ini', '.setup-done', 'logs')) { continue }
    if ($name -eq 'lists') {
        foreach ($l in (Get-ChildItem $item -File)) {
            if ($l.Name -like '*-user.txt' -or $l.Name -eq 'ipset-all.txt') { continue }
            Copy-Item $l.FullName (Join-Path $ListsDir $l.Name) -Force
        }
        foreach ($d in (Get-ChildItem $item -Directory -ErrorAction SilentlyContinue)) {
            Copy-Item $d.FullName (Join-Path $ListsDir $d.Name) -Recurse -Force
        }
        continue
    }
    if ($item.PSIsContainer) {
        Copy-Item $item.FullName (Join-Path $RootDir $name) -Recurse -Force
    } else {
        Copy-Item $item.FullName (Join-Path $RootDir $name) -Force
    }
}
Set-ConfigKey -Key 'PRODUCT_VERSION' -Value $tag.TrimStart('v')
Set-ConfigKey -Key 'SKIPPED_VERSION' -Value ''
Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

if ($wasRunning) {
    $strat = 1
    if ($cfg.ContainsKey('STRATEGY')) { try { $strat = [int]$cfg.STRATEGY } catch { } }
    $r = Start-Zapret -Num $strat -WaitSec 3
    if ($r.Ok) { Write-Host ('[+] zapret снова запущен (стратегия {0:D2}).' -f $strat) -ForegroundColor Green }
}
Write-Host ('[+] Обновлено до ' + $tag + '. config.ini и ваши списки не тронуты.') -ForegroundColor Green
Write-Log ('self-update to ' + $tag)
exit 0
