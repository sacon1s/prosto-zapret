# tune.ps1 - automatically find a working strategy by trying them one by one
# -Fast: ~2-3s per strategy instead of ~7s (less precise checks)
# -From / -To: test only strategies in this number range
param([int]$From = 0, [int]$To = 0, [switch]$Fast)
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Admin
$ErrorActionPreference = 'Continue'

$cfg = Read-Config
$timeout = 4
if ($Fast) { $timeout = 2 }
if (-not $Fast -and $cfg.ContainsKey('CHECK_TIMEOUT')) { try { $timeout = [Math]::Min(4, [int]$cfg.CHECK_TIMEOUT) } catch { } }
$waitSec = 2
if ($Fast) { $waitSec = 1 }
$ipset = $true
if ($cfg.ContainsKey('IPSET')) { $ipset = ($cfg.IPSET -eq '1') }
Set-IpsetActive -On $ipset

$strats = Get-Strategies
$reportFile = Join-Path $LogsDir 'tune-report.txt'

Write-Host ''
Write-Host '=== Zapret Pro: автоподбор стратегии ===' -ForegroundColor Cyan
Write-Host ('Стратегий в библиотеке: {0}. Это может занять 1-3 минуты.' -f $strats.Count) -ForegroundColor DarkGray

# baseline: what works WITHOUT zapret
Write-Host ''
Write-Host 'Шаг 1. Проверка без обхода (базовая линия)...' -ForegroundColor DarkGray
$null = Stop-Zapret
Clear-DnsCache
$base = Test-Targets -Timeout $timeout
$baseNote = 'уже работает без zapret'
if ($base.All) {
    Write-Host '[i] Внимание: цели откликаются и без zapret.' -ForegroundColor Yellow
    Write-Host '    Возможно, блокировки нет, работает другой обход, или проверка ложно-положительная.' -ForegroundColor Yellow
    $baseNote = 'откликается без zapret'
} else {
    Write-Host ('    Базовая линия: YouTube={0} Discord={1} (счёт {2}/6)' -f $base.YouTube, $base.Discord, $base.Score) -ForegroundColor DarkGray
}

# try strategies
Write-Host ''
Write-Host 'Шаг 2. Перебор стратегий...' -ForegroundColor DarkGray
$bestNum = 0
$bestScore = $base.Score
$bestVerdict = ''
$tried = 0
$report = @("tune $(Get-Date -Format 'yyyy-MM-dd HH:mm')  baseline=$($base.Score)/6")

foreach ($s in $strats) {
    if ($From -gt 0 -and $s.Num -lt $From) { continue }
    if ($To -gt 0 -and $s.Num -gt $To) { continue }
    $tried++
    $r = Start-Zapret -Num $s.Num -WaitSec $waitSec
    if (-not $r.Ok) {
        $line = ('{0:D2} {1} -> ОШИБКА СТАРТА' -f $s.Num, $s.Name)
        Write-Host ('  {0}' -f $line) -ForegroundColor DarkYellow
        $report += $line + ' err: ' + $r.Error
        continue
    }
    Clear-DnsCache
    $t = Test-Targets -Timeout $timeout
    $tag = ''
    if ($t.All) { $tag = 'YOUTUBE+DISCORD' } elseif ($t.YouTube) { $tag = 'YouTube' } elseif ($t.Discord) { $tag = 'Discord' } else { $tag = '-' }
    $line = ('{0:D2} {1,-22} счёт {2}/6  {3}' -f $s.Num, $s.Name, $t.Score, $tag)
    $col = 'DarkGray'
    if ($t.All) { $col = 'Green' } elseif ($t.Score -gt 0) { $col = 'Yellow' }
    Write-Host ('  {0}' -f $line) -ForegroundColor $col
    $report += $line
    if ($t.Score -gt $bestScore) {
        $bestScore = $t.Score
        $bestNum = $s.Num
        $bestVerdict = $tag
    }
    if ($t.All) { break }
}

# finish
Set-ConfigKey -Key 'STRATEGY' -Value ([string]$bestNum)
Set-ConfigKey -Key 'TUNED_AT' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm')
if ($bestNum -gt 0) {
    # make sure the best one is the one running right now
    $alive = Get-ZapretProcess
    $curName = Get-StrategyName -Num $bestNum
    if (-not $alive.Count) {
        $r = Start-Zapret -Num $bestNum -WaitSec 2
        if (-not $r.Ok) { Write-Host ('[!] Лучшая стратегия {0:D2} не стартовала повторно.' -f $bestNum) -ForegroundColor Yellow }
    }
    Write-Host ''
    Write-Host ('[+] Выбрана стратегия {0:D2} ({1}). Сохранена в config.ini.' -f $bestNum, $curName) -ForegroundColor Green
    if ($base.All) { Write-Host ('[i] {0} - сеть не требовала обхода; стратегия сохранена как запасная.' -f $baseNote) -ForegroundColor Yellow }
    Write-Log ("tune done best={0} ({1}) score={2}/6" -f $bestNum, $curName, $bestScore)
    Write-Host ''
    Write-Host 'Проверьте Discord и YouTube. Если что-то не так - запустите TUNE ещё раз или посмотрите README.md (раздел DNS).' -ForegroundColor DarkGray
} else {
    $null = Stop-Zapret
    Write-Host ''
    Write-Host '[x] Ни одна стратегия не улучшила доступ.' -ForegroundColor Red
    Write-Host '    Самые частые причины:' -ForegroundColor Yellow
    Write-Host '    1) DNS подменяется провайдером -> запустите extra\DNS-SET.bat и повторите TUNE;' -ForegroundColor Yellow
    Write-Host '    2) VPN/прокси/антивирус вмешивается -> см. extra\DIAGNOSTICS.bat;' -ForegroundColor Yellow
    Write-Host '    3) Ваш провайдер использует новый метод блокировки -> обновите ядро: extra\UPDATE.bat.' -ForegroundColor Yellow
    Write-Log 'tune done: no working strategy'
}
$report | Set-Content $reportFile -Encoding UTF8
Write-Host ('Отчёт: {0}' -f $reportFile) -ForegroundColor DarkGray
exit 0
