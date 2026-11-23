# fix-discord-media.ps1 - find a strategy that unblocks Discord media (media.discordapp.net = chat images)
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Admin
$ErrorActionPreference = 'Continue'

$logPath = Join-Path $LogsDir 'media-fix.log'
function Say {
    param([string]$m, [string]$c = 'White')
    Write-Host $m -ForegroundColor $c
    Add-Content -Path $logPath -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8
}

Say '=== Фикс картинок Discord (media.discordapp.net) ===' 'Cyan'
$cfg = Read-Config
$timeout = 4
$ipset = $true
if ($cfg.ContainsKey('IPSET')) { $ipset = ($cfg.IPSET -eq '1') }
Set-IpsetActive -On $ipset

# baseline with current instance
$base = Test-Targets -Timeout $timeout
Say ('Текущее состояние: media=' + $base.Media + ' discord=' + $base.Discord + ' youtube=' + $base.YouTube) 'DarkGray'
if ($base.Media) {
    Say '[i] media.discordapp.net уже открывается. Возможно, картинки не грузились из-за кеша Discord.' 'Green'
    Say '    Перезапустите Discord (Ctrl+R в окне клиента).' 'Yellow'
    exit 0
}

$null = Stop-Zapret
$fixed = 0
$bestNum = 0
$bestScore = -1
foreach ($s in (Get-Strategies)) {
    $r = Start-Zapret -Num $s.Num -WaitSec 2
    if (-not $r.Ok) { Say ('{0:D2} {1}: ошибка старта' -f $s.Num, $s.Name) 'DarkYellow'; continue }
    Clear-DnsCache
    $t = Test-Targets -Timeout $timeout
    $col = 'DarkGray'
    if ($t.Media -and $t.Discord) { $col = 'Green' } elseif ($t.Media) { $col = 'Yellow' }
    Say ('{0:D2} {1,-22} media={2} discord={3} youtube={4} (счёт {5}/7)' -f $s.Num, $s.Name, $t.Media, $t.Discord, $t.YouTube, $t.Score) $col
    # best = media first, then total score
    if ($t.Media -and ($fixed -eq 0)) { $fixed = $s.Num }
    if ($fixed -eq 0) {
        if (($t.YouTube -and ($bestNum -eq 0)) -or ($t.Score -gt $bestScore)) {
            $bestScore = $t.Score
            $bestNum = $s.Num
        }
    }
    if ($t.Media -and $t.Discord -and $t.YouTube) { $fixed = $s.Num; break }
}

if ($fixed -gt 0) {
    # ensure the chosen one is running
    $alive = Get-ZapretProcess
    if (-not $alive.Count) { Start-Zapret -Num $fixed -WaitSec 2 | Out-Null }
    Set-ConfigKey -Key 'STRATEGY' -Value ([string]$fixed)
    Set-ConfigKey -Key 'TUNED_AT' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm')
    Say ('[+] Картинки фиксятся стратегией {0:D2} ({1}). Сохранена в config.ini.' -f $fixed, (Get-StrategyName -Num $fixed)) 'Green'
    Say '    Перезапустите Discord (Ctrl+R), картинки и превью должны грузиться.' 'Green'
    Write-Log ("media-fix: strategy {0} works for media.discordapp.net" -f $fixed)
} else {
    if ($bestNum -gt 0) {
        # no media fix, but keep the best overall strategy running and saved
        $r = Start-Zapret -Num $bestNum -WaitSec 2
        if ($r.Ok) {
            Set-ConfigKey -Key 'STRATEGY' -Value ([string]$bestNum)
            Set-ConfigKey -Key 'TUNED_AT' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm')
            Say ('[~] Картинки пока не открылись, но лучшая стратегия {0:D2} ({1}) сохранена и запущена.' -f $bestNum, (Get-StrategyName -Num $bestNum)) 'Yellow'
            Say '    Перезапустите Discord (Ctrl+R) - возможно, в клиенте картинки уже работают (у curl другой TLS-отпечаток).' 'Yellow'
        }
    } else {
        $null = Stop-Zapret
    }
    Say '[x] Ни одна стратегия не открыла media.discordapp.net (по данным curl).' 'Red'
    Say '    1) Проверьте Discord клиентом (Ctrl+R) - клиент часто работает, даже когда curl нет.' 'Yellow'
    Say '    2) Проверьте DNS: DIAGNOSTICS.bat, при подмене - DNS-SET.bat и повторите.' 'Yellow'
    Say '    3) Обновите ядро: UPDATE.bat (провайдер мог внедрить новый метод).' 'Yellow'
    Write-Log 'media-fix: no strategy fixed media (curl)'
}
exit 0
