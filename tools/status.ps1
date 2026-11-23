# status.ps1 - quick status: is zapret running, autostart state, access check. No admin needed.
. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Continue'

$cfg = Read-Config

# 1. zapret process
$procs = Get-ZapretProcess
if ($procs.Count -gt 0) {
    $p = $procs[0]
    $up = (Get-Date) - $p.StartTime
    Write-Host ('[1] ЗАПРЕТ: ВКЛЮЧЁН (PID {0}, работает {1:hh\:mm\:ss})' -f $p.Id, $up) -ForegroundColor Green
} else {
    Write-Host '[1] ЗАПРЕТ: ВЫКЛЮЧЕН (запустите "1 - ВКЛЮЧИТЬ ЗАПРЕТ.bat")' -ForegroundColor Red
}

# 2. strategy + autostart
$strat = 1
if ($cfg.ContainsKey('STRATEGY')) { try { $strat = [int]$cfg.STRATEGY } catch { } }
Write-Host ('[2] Стратегия: {0:D2} ({1})' -f $strat, (Get-StrategyName -Num $strat))
$task = Get-ScheduledTask -TaskName 'ZapretPro' -ErrorAction SilentlyContinue
if ($task) {
    Write-Host '[3] Автозапуск с ПК: ВКЛЮЧЁН (+ сторож)' -ForegroundColor Green
} else {
    Write-Host '[3] Автозапуск с ПК: выключен (файл "3 - АВТОЗАПУСК.bat" включит)' -ForegroundColor DarkGray
}

# 3. discord media pins
$hostsRaw = ''
try { $hostsRaw = [IO.File]::ReadAllText("$env:windir\System32\drivers\etc\hosts") } catch { }
if ($hostsRaw -match 'media\.discordapp\.net') {
    Write-Host '[4] Пины картинок Discord: есть' -ForegroundColor Green
} else {
    Write-Host '[4] Пины картинок Discord: нет (extra\FIX-MEDIA.bat)' -ForegroundColor DarkGray
}

# 4. access check (fast, parallel)
Write-Host ''
Write-Host 'Проверка доступа...' -ForegroundColor DarkGray
$t = Test-Targets -Timeout 4
foreach ($k in $t.Results.Keys) {
    $res = $t.Results[$k]
    $col = 'Green'; $mark = 'OK  '
    if (-not $res.Ok) { $col = 'Red'; $mark = 'FAIL' }
    Write-Host ('  {0,-8} {1} {2}ms (HTTP {3})' -f $k, $mark, $res.Ms, $res.Code) -ForegroundColor $col
}
Write-Host ''
if ($t.YouTube) { Write-Host '[+] YouTube: работает' -ForegroundColor Green } else { Write-Host '[x] YouTube: НЕ работает' -ForegroundColor Red }
if ($t.Discord) { Write-Host '[+] Discord: работает' -ForegroundColor Green } else { Write-Host '[x] Discord: НЕ работает' -ForegroundColor Red }
if ($t.Media) { Write-Host '[+] Картинки Discord: работают' -ForegroundColor Green } else { Write-Host '[x] Картинки Discord: НЕ работают' -ForegroundColor Red }

if ($procs.Count -eq 0) { exit 1 }
if (-not ($t.YouTube -and $t.Discord)) { exit 2 }
exit 0
