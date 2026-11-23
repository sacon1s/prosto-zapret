# fix-media-hosts.ps1 v2 - pin media.discordapp.net to the working Cloudflare pool (.233)
# via ATOMIC full rewrite of hosts (Add-Content gets silently blocked by host-protection).
# Logs everything to logs\hosts-pin.log. Actions: add (default) | remove | status
param([string]$Action = 'add')
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Admin
$ErrorActionPreference = 'Continue'

$hostsPath = Join-Path $env:windir 'System32\drivers\etc\hosts'
$pinLog = Join-Path $LogsDir 'hosts-pin.log'
$marker = '# zapret-pro discord media pins'
$domains = @('media.discordapp.net', 'images-ext-1.discordapp.net', 'images-ext-2.discordapp.net')
$ips = @('162.159.134.233', '162.159.128.233')

function Log {
    param([string]$m)
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host $m
    Add-Content -Path $pinLog -Value ("[{0}] {1}" -f $ts, $m) -Encoding UTF8
}

Log ('=== fix-media-hosts v2, action=' + $Action + ' ===')

if ($Action -eq 'status') {
    $raw = [IO.File]::ReadAllText($hostsPath)
    foreach ($d in $domains) {
        $hits = @($raw -split "`r?`n" | Where-Object { $_ -match [regex]::Escape($d) })
        Log ('  ' + $d + ': ' + $(if ($hits.Count) { $hits -join ' | ' } else { 'нет записей' }))
    }
    exit 0
}

if ($Action -eq 'remove') {
    try {
        $lines = [IO.File]::ReadAllLines($hostsPath)
        $out = New-Object System.Collections.Generic.List[string]
        $inBlock = $false
        foreach ($l in $lines) {
            if ($l -match '^\s*' + [regex]::Escape($marker)) { $inBlock = $true; continue }
            if ($inBlock) {
                if ($l.Trim() -eq '') { $inBlock = $false }
                continue
            }
            $out.Add($l)
        }
        [IO.File]::WriteAllLines($hostsPath, $out, (New-Object Text.UTF8Encoding($false)))
        Clear-DnsCache
        Log '[+] Блок пинов media удалён.'
    } catch { Log ('[x] Ошибка удаления: ' + $_.Exception.ToString()) }
    exit 0
}

# ---------- add ----------
# probe candidate Cloudflare pools and pick ones that actually answer (portable across ISPs)
$candidates = @('162.159.134.233', '162.159.128.233', '162.159.135.233', '162.159.136.233', '162.159.137.233', '162.159.138.233')
$ips = @()
foreach ($c in $candidates) {
    $r = & curl.exe -4 -s -o NUL -I -m 6 --connect-timeout 5 --resolve ("media.discordapp.net:443:" + $c) -w '%{http_code}' 'https://media.discordapp.net/' 2>$null
    $code = ($r | Out-String).Trim()
    if ($code -match '\d{3}' -and $code -ne '000') { $ips += $c; Log ('[i] пул ' + $c + ' отвечает (HTTP ' + $code + ')') }
    if ($ips.Count -ge 2) { break }
}
if ($ips.Count -eq 0) {
    Log '[~] Рабочий пул не найден пробой - использую известные .233 (может не сработать).'
    $ips = @('162.159.134.233', '162.159.128.233')
}

try {
    $backup = Join-Path $LogsDir ('hosts-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
    Copy-Item $hostsPath $backup -Force
    Log ('[i] Бэкап: ' + $backup)

    $lines = [IO.File]::ReadAllLines($hostsPath)
    Log ('[i] Прочитано строк: ' + $lines.Count)

    # drop our previous block and any stale media pins (wherever they live)
    $clean = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    foreach ($l in $lines) {
        if ($l -match '^\s*' + [regex]::Escape($marker)) { $inBlock = $true; continue }
        if ($inBlock) {
            if ($l.Trim() -eq '') { $inBlock = $false }
            continue
        }
        $skip = $false
        foreach ($d in $domains) { if ($l -match '\s' + [regex]::Escape($d) + '\s*$') { $skip = $true; break } }
        if (-not $skip) { $clean.Add($l) }
    }

    # build final content: clean lines + marker + pins
    $final = New-Object System.Collections.Generic.List[string]
    foreach ($l in $clean) { $final.Add($l) }
    while ($final.Count -gt 0 -and $final[$final.Count - 1].Trim() -eq '') { $final.RemoveAt($final.Count - 1) }
    $final.Add('')
    $final.Add($marker)
    foreach ($d in $domains) {
        foreach ($ip in $ips) { $final.Add($ip + ' ' + $d) }
    }

    # single atomic-style write
    [IO.File]::WriteAllLines($hostsPath, $final, (New-Object Text.UTF8Encoding($false)))
    Log ('[+] Записано атомарно: ' + $final.Count + ' строк (пинов: ' + ($domains.Count * $ips.Count) + ')')
} catch {
    Log ('[x] ОШИБКА ЗАПИСИ: ' + $_.Exception.ToString())
    Log '    Похоже, hosts защищён (Defender "Защита от подмены hosts" или антивирус).'
    Log '    Отключите её временно и повторите.'
    exit 1
}

Clear-DnsCache
Start-Sleep -Milliseconds 800

# verify endpoints
$allOk = $true
foreach ($d in $domains) {
    $r = & curl.exe -4 -s -o NUL -I -m 10 --connect-timeout 8 -w '%{http_code}' ('https://' + $d + '/') 2>$null
    $code = ($r | Out-String).Trim()
    $ok = $code -match '\d{3}' -and $code -ne '000'
    if (-not $ok) { $allOk = $false }
    Log ('    ' + $d + ' -> HTTP ' + $code + $(if ($ok) { ' OK' } else { ' FAIL' }))
}
if ($allOk) {
    Log '[+] ГОТОВО: медиа-домены Discord отвечают.'
    Log '    Полностью перезапустите Discord (иконка в трее -> Quit), затем откройте снова.'
    Write-Log 'media hosts pin v2 applied OK'
} else {
    Log '[x] Пины записаны, но домены не отвечают - возможно, пул IP изменился.'
    Write-Log 'media hosts pin v2 applied but endpoints fail'
}
exit 0
