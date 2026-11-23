# update.ps1 - update core (winws/WinDivert/fakes), lists and strategy library
# from the upstream Flowseal/zapret-discord-youtube repo. Keeps config.ini and user lists.
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Admin
$ErrorActionPreference = 'Stop'

$tmpDir = Join-Path $LogsDir ('update-tmp-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $tmpDir | Out-Null
$zip = Join-Path $tmpDir 'repo.zip'

$repoUrl = 'https://github.com/Flowseal/zapret-discord-youtube/archive/refs/heads/main.zip'
$oldVer = 'unknown'
if ($cfg0 = Read-Config) { if ($cfg0.ContainsKey('CORE_VERSION')) { $oldVer = $cfg0.CORE_VERSION } }

Write-Host ''
Write-Host '=== Zapret Pro: обновление ядра и списков ===' -ForegroundColor Cyan
Write-Host ('Текущая версия ядра: {0}' -f $oldVer)
Write-Host 'Скачиваю последнюю версию с GitHub...' -ForegroundColor DarkGray

$null = Stop-Zapret
$dl = & curl.exe -4 -sL --max-time 180 -o $zip $repoUrl
$dlExit = $LASTEXITCODE
if ($dlExit -ne 0 -or -not (Test-Path $zip) -or ((Get-Item $zip).Length -lt 100000)) {
    Write-Host ('[x] Не удалось скачать ({0}). Проверьте интернет и повторите extra\UPDATE.bat.' -f $dlExit) -ForegroundColor Red
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Host ('Скачано: {0:N1} КБ' -f ((Get-Item $zip).Length / 1KB))

$ex = Join-Path $tmpDir 'extracted'
Expand-Archive -Path $zip -DestinationPath $ex -Force
$src = Get-ChildItem $ex -Directory | Select-Object -First 1
if (-not $src) {
    Write-Host '[x] В архиве не найдена папка с исходниками.' -ForegroundColor Red
    exit 1
}
$srcPath = $src.FullName

# version
$newVer = 'unknown'
$vfile = Join-Path $srcPath '.service\version.txt'
if (Test-Path $vfile) { $newVer = (Get-Content $vfile -TotalCount 1).Trim() }
Write-Host ('Новая версия ядра:   {0}' -f $newVer)

# 1) bin
Copy-Item (Join-Path $srcPath 'bin\*') $BinDir -Force
Write-Host '[+] bin обновлён (winws, WinDivert, фейки).' -ForegroundColor Green

# 2) lists: everything except managed/user files
$skip = @('ipset-all.txt', 'list-general-user.txt', 'list-exclude-user.txt', 'ipset-exclude-user.txt')
Get-ChildItem (Join-Path $srcPath 'lists') -File | Where-Object { $skip -notcontains $_.Name } | ForEach-Object {
    Copy-Item $_.FullName $ListsDir -Force
}
# rename upstream backup names to our full/empty scheme
foreach ($n in @('ipset-all.txt.backup')) {
    $f = Join-Path $ListsDir $n
    if (Test-Path $f) { Move-Item $f (Join-Path $ListsDir 'ipset-upstream-full.txt') -Force }
}
$svcIpset = Join-Path $srcPath '.service\ipset-service.txt'
if (Test-Path $svcIpset) { Copy-Item $svcIpset (Join-Path $ListsDir 'ipset-full.txt') -Force }
# refresh empty ipset (contains the dummy record)
('203.0.113.113/32') | Set-Content (Join-Path $ListsDir 'ipset-empty.txt') -Encoding ASCII
Write-Host '[+] списки обновлены (ваши *-user.txt не тронуты).' -ForegroundColor Green

# 3) strategies
& (Join-Path $PSScriptRoot 'extract-strategies.ps1') -Source $srcPath | Out-Null
Write-Host '[+] библиотека стратегий пересобрана из свежих пресетов.' -ForegroundColor Green

# 4) config version stamp + keep STRATEGY if valid, else reset to 1
Set-ConfigKey -Key 'CORE_VERSION' -Value $newVer
Set-ConfigKey -Key 'UPDATED_AT' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm')
$cfg = Read-Config
$strat = 1
if ($cfg.ContainsKey('STRATEGY')) { try { $strat = [int]$cfg.STRATEGY } catch { } }
if (-not (Test-Path (Join-Path $StrategiesDir ('{0:D2}.txt' -f $strat)))) { $strat = 1; Set-ConfigKey -Key 'STRATEGY' -Value '1' }

# 5) start again if it was useful
Start-Zapret -Num $strat -WaitSec 2 | Out-Null
$alive = Get-ZapretProcess
if ($alive.Count -gt 0) { Write-Host ('[+] zapret снова запущен (стратегия {0:D2}).' -f $strat) -ForegroundColor Green }

Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Log ('updated core {0} -> {1}' -f $oldVer, $newVer)
Write-Host ''
Write-Host 'Готово. Если доступ пропал - запустите "5 - ПОДБОР НАСТРОЕК.bat" (стратегии обновились).' -ForegroundColor Yellow
exit 0
