# run.ps1 - start zapret with the saved (or given) strategy, then verify access
param(
    [int]$Strategy = 0,
    [switch]$NoCheck,
    [switch]$NoHint
)
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Admin
$ErrorActionPreference = 'Continue'

$cfg = Read-Config
$num = $Strategy
if ($num -le 0) {
    $num = 1
    if ($cfg.ContainsKey('STRATEGY')) { $num = [int]$cfg.STRATEGY }
}
$strats = Get-Strategies
if ($num -lt ($strats | Select-Object -First 1).Num -or $num -gt ($strats | Select-Object -Last 1).Num) { $num = ($strats | Select-Object -First 1).Num }

$ipset = $true
if ($cfg.ContainsKey('IPSET')) { $ipset = ($cfg.IPSET -eq '1') }
Set-IpsetActive -On $ipset

Write-Host ''
Write-Host '=== Zapret Pro: запуск ===' -ForegroundColor Cyan
Write-Host ('Стратегия: {0:D2} ({1})' -f $num, (Get-StrategyName -Num $num))

$r = Start-Zapret -Num $num -WaitSec 3
if (-not $r.Ok) {
    Write-Host ('[!] Стратегия {0:D2} не стартовала: {1}' -f $num, $r.Error) -ForegroundColor Yellow
    $started = $false
    foreach ($s in $strats) {
        if ($s.Num -eq $num) { continue }
        $r = Start-Zapret -Num $s.Num -WaitSec 2
        if ($r.Ok) {
            $num = $s.Num
            $started = $true
            Write-Host ('    переключился на {0:D2} ({1})' -f $s.Num, $s.Name) -ForegroundColor Yellow
            break
        }
    }
    if (-not $started) {
        Write-Host '[x] Ни одна стратегия не стартовала. Подробности: logs\winws-lasterr.log' -ForegroundColor Red
        exit 1
    }
}
Write-Host ('[+] winws работает (PID {0})' -f $r.Proc.Id) -ForegroundColor Green
Write-Log ("start strategy={0} pid={1}" -f $num, $r.Proc.Id)

if (-not $NoCheck) {
    Write-Host 'Проверка доступа (несколько секунд)...' -ForegroundColor DarkGray
    Clear-DnsCache
    Start-Sleep -Seconds 2
    $timeout = 5
    if ($cfg.ContainsKey('CHECK_TIMEOUT')) { try { $timeout = [int]$cfg.CHECK_TIMEOUT } catch { } }
    $t = Test-Targets -Timeout $timeout
    foreach ($k in $t.Results.Keys) {
        $res = $t.Results[$k]
        $mark = if ($res.Ok) { 'OK  ' } else { 'FAIL' }
        $col = if ($res.Ok) { 'Green' } else { 'Red' }
        Write-Host ('  {0,-8} {1} {2} {3}ms (HTTP {4})' -f $k, $mark, $CheckTargets[$k].PadRight(38), $res.Ms, $res.Code) -ForegroundColor $col
    }
    Write-Host ''
    if ($t.YouTube) { Write-Host '[+] YouTube: доступен' -ForegroundColor Green } else { Write-Host '[x] YouTube: НЕДОСТУПЕН' -ForegroundColor Red }
    if ($t.Discord) { Write-Host ('[+] Discord: доступен' ) -ForegroundColor Green } else { Write-Host '[x] Discord: НЕДОСТУПЕН' -ForegroundColor Red }

    if (-not $t.All) {
        $auto = $true
        if ($cfg.ContainsKey('AUTOTUNE_ON_FAIL')) { $auto = ($cfg.AUTOTUNE_ON_FAIL -eq '1') }
        if ($auto) {
            Write-Host ''
            Write-Host 'Автоперебор стратегий запущен (TUNE)...' -ForegroundColor Yellow
            & (Join-Path $PSScriptRoot 'tune.ps1')
            exit $LASTEXITCODE
        } elseif (-not $NoHint) {
            Write-Host 'Запустите TUNE.bat для автоматического подбора рабочей стратегии.' -ForegroundColor Yellow
            Write-Host 'Если не поможет - проверьте DNS: DNS-SET.bat (помощь в README.md).' -ForegroundColor Yellow
        }
        exit 1
    }
    Write-Host ''
    Write-Host 'Всё работает. Окно можно закрыть - обход продолжит работать в фоне.' -ForegroundColor Green
}
exit 0
