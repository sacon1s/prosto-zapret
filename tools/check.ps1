# check.ps1 - full access check (no admin needed). Exit codes: 0=all OK, 1=partial, 2=none
. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Continue'

$cfg = Read-Config
$timeout = 6
if ($cfg.ContainsKey('CHECK_TIMEOUT')) { try { $timeout = [int]$cfg.CHECK_TIMEOUT } catch { } }

Write-Host ''
Write-Host '=== Zapret Pro: проверка доступа ===' -ForegroundColor Cyan

# zapret status
$procs = Get-ZapretProcess
if ($procs.Count -gt 0) {
    $p = $procs[0]
    $uptime = (Get-Date) - $p.StartTime
    Write-Host ('zapret: работает (PID {0}, {1:hh\:mm\:ss})' -f $p.Id, $uptime) -ForegroundColor Green
} else {
    Write-Host 'zapret: НЕ запущен' -ForegroundColor Red
}
$strat = 1
if ($cfg.ContainsKey('STRATEGY')) { $strat = [int]$cfg.STRATEGY }
Write-Host ('Стратегия в config.ini: {0:D2} ({1})' -f $strat, (Get-StrategyName -Num $strat))
$ipsetOn = $true
if ($cfg.ContainsKey('IPSET')) { $ipsetOn = ($cfg.IPSET -eq '1') }
$ipsetSize = (Get-Item (Join-Path $ListsDir 'ipset-all.txt') -ErrorAction SilentlyContinue).Length
Write-Host ('Режим ipset (доп. сервисы): {0} (список {1} КБ)' -f $(if ($ipsetOn) { 'ВКЛ' } else { 'выкл' }), [int]($ipsetSize / 1KB))

# connectivity
Write-Host ''
Write-Host 'Проверка соединений...' -ForegroundColor DarkGray
$t = Test-Targets -Timeout $timeout
foreach ($k in $t.Results.Keys) {
    $res = $t.Results[$k]
    $col = 'Green'
    $mark = 'OK  '
    if (-not $res.Ok) { $col = 'Red'; $mark = 'FAIL' }
    Write-Host ('  {0,-8} {1} {2} {3}ms (HTTP {4})' -f $k, $mark, $CheckTargets[$k].PadRight(38), $res.Ms, $res.Code) -ForegroundColor $col
}
Write-Host ''
if ($t.YouTube) { Write-Host '[+] YouTube: доступен' -ForegroundColor Green } else { Write-Host '[x] YouTube: недоступен' -ForegroundColor Red }
if ($t.Discord) { Write-Host '[+] Discord: доступен (web + gateway)' -ForegroundColor Green } else { Write-Host '[x] Discord: недоступен' -ForegroundColor Red }

# real video stream bytes
$stream = Test-YouTubeStream
if ($stream.Ok) { Write-Host ('[+] Видеопоток YouTube: работает ({0} КБ получено)' -f [math]::Round($stream.Bytes / 1KB)) -ForegroundColor Green }
else { Write-Host ('[~] Видеопоток YouTube: не подтвердился ({0})' -f $(if ($stream.Note) { $stream.Note } else { 'HTTP ' + $stream.Code })) -ForegroundColor Yellow }

# DNS hint
Write-Host ''
$dnsOk = $true
try {
    $ips = @(Resolve-DnsName -Name 'www.youtube.com' -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress)
    if ($ips.Count -eq 0) { $dnsOk = $false }
    Write-Host ('DNS: www.youtube.com -> {0}' -f ($ips -join ', ')) -ForegroundColor DarkGray
} catch {
    $dnsOk = $false
    Write-Host 'DNS: не удалось разрешить www.youtube.com - вероятна DNS-подмена (см. extra\DNS-SET.bat)' -ForegroundColor Yellow
}

Write-Host ''
if ($t.All) { Write-Host 'ИТОГ: всё работает.' -ForegroundColor Green; exit 0 }
elseif ($t.YouTube -or $t.Discord) { Write-Host 'ИТОГ: работает частично. Запустите "5 - ПОДБОР НАСТРОЕК.bat".' -ForegroundColor Yellow; exit 1 }
else { Write-Host 'ИТОГ: доступ нет. Порядок действий: 1) "1 - ВКЛЮЧИТЬ ЗАПРЕТ.bat"  2) "5 - ПОДБОР НАСТРОЕК.bat"  3) extra\DNS-SET.bat  4) extra\UPDATE.bat  5) extra\DIAGNOSTICS.bat' -ForegroundColor Red; exit 2 }
