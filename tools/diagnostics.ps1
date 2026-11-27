# diagnostics.ps1 - environment diagnostics and conflict detection (no admin needed for most)
. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Continue'

$issues = @()
function Mark {
    param([string]$Status, [string]$Text, [string]$Color)
    Write-Host ('  [{0}] {1}' -f $Status, $Text) -ForegroundColor $Color
    if ($Color -eq 'Red') { $script:issues += $Text }
}

Write-Host ''
Write-Host '=== Zapret Pro: диагностика ===' -ForegroundColor Cyan

# 1. admin / zapret / task
Mark $(if (Test-Admin) { 'OK' } else { '~~' }) $(if (Test-Admin) { 'права администратора: есть' } else { 'права администратора: НЕТ (запускайте через .bat)' }) $(if (Test-Admin) { 'Green' } else { 'Yellow' })
$procs = Get-ZapretProcess
Mark 'OK' ('zapret (winws): ' + $(if ($procs.Count) { 'работает (PID ' + $procs[0].Id + ')' } else { 'не запущен' })) $(if ($procs.Count) { 'Green' } else { 'Yellow' })
$task = Get-ScheduledTask -TaskName 'ZapretPro' -ErrorAction SilentlyContinue
Mark 'OK' ('автозапуск+сторож: ' + $(if ($task) { 'установлен (' + $task.State + ')' } else { 'не установлен ("3 - АВТОЗАПУСК.bat")' })) $(if ($task) { 'Green' } else { 'DarkGray' })

# 2. binaries present
foreach ($f in @('winws.exe', 'WinDivert.dll', 'WinDivert64.sys')) {
    $p = Join-Path $BinDir $f
    Mark 'OK' ("bin\" + $f + ": " + $(if (Test-Path $p) { 'есть' } else { 'ОТСУТСТВУЕТ' })) $(if (Test-Path $p) { 'Green' } else { 'Red' })
}

# 3. BFE service (required by WinDivert)
$bfe = Get-Service -Name 'BFE' -ErrorAction SilentlyContinue
Mark 'OK' ('служба BFE (Base Filtering Engine): ' + $(if ($bfe -and $bfe.Status -eq 'Running') { 'работает' } else { 'НЕ работает - WinDivert не сможет перехватывать трафик' })) $(if ($bfe -and $bfe.Status -eq 'Running') { 'Green' } else { 'Red' })

# 4. conflicting software
$conflictNames = 'adguard|killer|smartbyte|cfosspeed|nastask|trafficpolicy|netfilter|proxifier|netch|v2ray|xray|sing-box|clash|goodbye'
$conf = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $conflictNames })
Mark 'OK' ('конфликтующий софт: ' + $(if ($conf.Count) { ($conf | Select-Object -ExpandProperty ProcessName -Unique) -join ', ' } else { 'не найден' })) $(if ($conf.Count) { 'Yellow' } else { 'Green' })

# 4b. foreign winws manager services (ZapretGUI etc.) - they fight our watchdog
$mgrSvcs = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue |
    Where-Object {
        $ip = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ImagePath
        $ip -and ($ip -match 'ZapretGUI')
    })
$mgrRunning = $false
foreach ($m in $mgrSvcs) {
    $svc = Get-Service -Name $m.PSChildName -ErrorAction SilentlyContinue
    if ($svc -and $svc.StartType -ne 'Disabled') { $mgrRunning = $true }
}
Mark $(if ($mgrRunning) { '!!' } else { 'OK' }) ('чужой менеджер winws (ZapretGUI): ' + $(if ($mgrRunning) { 'АКТИВЕН - будет убивать наш winws! Запустите extra\TAKE-CONTROL.bat' } else { 'не активен' })) $(if ($mgrRunning) { 'Red' } else { 'Green' })
if ($mgrRunning) { $issues += 'служба ZapretGUI активна и конкурирует за winws - запустите extra\TAKE-CONTROL.bat (или оставьте ZapretGUI и не запускайте наш)' }

# 5. VPN adapters
$tun = Get-TunnelState
Mark $(if ($tun.Active) { '~~' } else { 'OK' }) ('VPN / туннели: ' + (Get-TunnelText -T $tun)) $(if ($tun.Active) { 'Yellow' } else { 'Green' })

# 6. system/user proxy
$proxy = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue)
$pxOn = $proxy.ProxyEnable -eq 1
Mark 'OK' ('прокси в системе: ' + $(if ($pxOn) { 'ВКЛЮЧЁН (' + $proxy.ProxyServer + ')' } else { 'нет' })) $(if ($pxOn) { 'Yellow' } else { 'Green' })
if ($pxOn) { $issues += 'включён системный прокси - zapret должен работать и с ним, но проверьте' }

# 7. hosts file
$hostsLines = @(Get-Content "$env:windir\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue | Where-Object { $_ -match 'youtube|discord|googlevideo' -and $_ -notmatch '^\s*#' })
# blocking pins (to localhost/lan) are bad; pins to Cloudflare/Google IPs are a known workaround - just informational
$hostsBlocking = @($hostsLines | Where-Object { $_ -match '^(127\.0\.0\.1|0\.0\.0\.0|10\.|192\.168\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.)' })
Mark $(if ($hostsBlocking.Count) { '!!' } else { 'OK' }) ('hosts-файл: ' + $(if ($hostsBlocking.Count) { 'блокирующие записи (' + $hostsBlocking.Count + ') - удалите их' } elseif ($hostsLines.Count) { 'есть закрепления IP для discord/youtube (это рабочий обход, не мешает)' } else { 'чисто' })) $(if ($hostsBlocking.Count) { 'Red' } else { 'Green' })
if ($hostsBlocking.Count) { $issues += 'hosts-файл БЛОКИРУЕТ youtube/discord (записи на 127.0.0.1/0.0.0.0) - удалите эти строки' }

# 8. non-ASCII path
$ascii = $true
foreach ($ch in $RootDir.ToCharArray()) { if ([int]$ch -gt 127) { $ascii = $false; break } }
Mark 'OK' ('путь установки: ' + $(if ($ascii) { 'ок (без кириллицы)' } else { 'содержит кириллицу - WinDivert может не запуститься, перенесите папку' })) $(if ($ascii) { 'Green' } else { 'Red' })

# 9. DNS poison probe
Write-Host ''
Write-Host '  DNS-проверка (сравнение с DoH-ответом Cloudflare)...' -ForegroundColor DarkGray
foreach ($d in @('www.youtube.com', 'discord.com')) {
    $local = ''
    try {
        $local = [string](Resolve-DnsName -Name $d -Type A -ErrorAction Stop | Where-Object { $_.IPAddress -match '^\d+\.' } | Select-Object -First 1 -ExpandProperty IPAddress)
    } catch { }
    $dohSet = @()
    try {
        $j = & curl.exe -4 -s -m 6 -H 'accept: application/dns-json' ('https://cloudflare-dns.com/dns-query?name=' + $d + '&type=A') 2>$null | ConvertFrom-Json
        if ($j.Answer) { $dohSet = @($j.Answer | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.data }) }
    } catch { }
    if ($dohSet.Count -eq 0) {
        Mark '~~' ('{0}: не удалось получить эталон (DoH недоступен)' -f $d) 'DarkGray'
    } elseif (-not $local) {
        Mark '!!' ('{0}: локальный DNS НЕ отвечает -> DNS подменён/заблокирован. Запустите extra\DNS-SET.bat' -f $d) 'Red'
    } elseif ($dohSet -contains $local) {
        Mark 'OK' ('{0}: {1} (в эталонном наборе из {2} IP)' -f $d, $local, $dohSet.Count) 'Green'
    } else {
        # same /8 or /16 prefix is usually just a different edge node, not poisoning
        $dohPrefix = ($dohSet[0] -split '\.')[0..1] -join '.'
        $locPrefix = ($local -split '\.')[0..1] -join '.'
        if ($dohPrefix -eq $locPrefix) {
            Mark '~~' ('{0}: {1} (другой узел той же сети {2}.x - норма)' -f $d, $local, $dohPrefix) 'DarkGray'
        } else {
            Mark '!!' ('{0}: локальный {1} != эталон {2} -> возможна DNS-подмена. Запустите extra\DNS-SET.bat' -f $d, $local, ($dohSet -join ', ')) 'Red'
        }
    }
}

# 10. last winws error
$errLog = Join-Path $LogsDir 'winws-lasterr.log'
if (Test-Path $errLog) {
    $tail = (Get-Content $errLog -Tail 3 | Out-String).Trim()
    if ($tail) {
        Write-Host ''
        Write-Host '  Последние ошибки winws (logs\winws-lasterr.log):' -ForegroundColor DarkGray
        Write-Host $tail -ForegroundColor DarkYellow
    }
}

# summary
Write-Host ''
if ($issues.Count -eq 0) {
    Write-Host 'ИТОГ: критичных проблем не найдено.' -ForegroundColor Green
} else {
    Write-Host ('ИТОГ: найдено проблем: {0}' -f $issues.Count) -ForegroundColor Yellow
    foreach ($i in $issues) { Write-Host ('  - ' + $i) -ForegroundColor Yellow }
}
Write-Host ''
Write-Host 'Дальше по ситуации: "1 - ВКЛЮЧИТЬ ЗАПРЕТ.bat" -> "5 - ПОДБОР НАСТРОЕК.bat" -> extra\DNS-SET.bat -> extra\UPDATE.bat' -ForegroundColor DarkGray
exit 0
