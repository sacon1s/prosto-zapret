# dns.ps1 - manage DNS: status | set (Cloudflare + DoH) | reset (DHCP)
# Some ISPs poison DNS; zapret can't fix that - poisoned names must resolve correctly first.
param([string]$Action = 'status')
. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Continue'

function Get-ActiveAdapters {
    return @(Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback|TAP|WireGuard|OpenVPN|Tailscale|ZeroTier|virtual|Virtual' })
}

if ($Action -eq 'set') {
    Assert-Admin
    Write-Host 'Ставлю Cloudflare DNS (1.1.1.1 / 1.0.0.1) + шифрование DoH...' -ForegroundColor DarkGray
    $adapters = Get-ActiveAdapters
    foreach ($a in $adapters) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses '1.1.1.1', '1.0.0.1' -ErrorAction Stop
            Write-Host ('[+] {0}: DNS = 1.1.1.1, 1.0.0.1' -f $a.Name) -ForegroundColor Green
        } catch { Write-Host ('[!] {0}: {1}' -f $a.Name, $_.Exception.Message) -ForegroundColor Yellow }
    }
    foreach ($s in @('1.1.1.1', '1.0.0.1')) {
        $r = & netsh dns add encryption server=$s dohtemplate=https://cloudflare-dns.com/dns-query autoupgrade=yes udpfallback=no 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Host ("[+] DoH-шаблон для {0} добавлен." -f $s) -ForegroundColor Green }
        else { Write-Host ("[~] DoH для {0}: {1}" -f $s, ($r | Out-String).Trim()) -ForegroundColor DarkGray }
    }
    # enable system-wide automatic DoH (used by Win10 11 for known resolvers)
    try {
        $reg = 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters'
        if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }
        Set-ItemProperty -Path $reg -Name 'EnableAutoDoh' -Value 2 -Type DWord
        Write-Host '[+] Авто-DoH включён в реестре (полностью заработает после перезагрузки).' -ForegroundColor Green
    } catch { Write-Host ('[~] Реестр: {0}' -f $_.Exception.Message) -ForegroundColor DarkGray }
    Clear-DnsCache
    Write-Host '[+] Кеш DNS очищен.' -ForegroundColor Green
    Write-Host 'Теперь запустите "5 - ПОДБОР НАСТРОЕК.bat" заново - стратегии проверятся с исправным DNS.' -ForegroundColor Yellow
    exit 0
}

if ($Action -eq 'reset') {
    Assert-Admin
    Write-Host 'Возвращаю DNS на автоматический (DHCP)...' -ForegroundColor DarkGray
    foreach ($a in (Get-ActiveAdapters)) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop
            Write-Host ('[+] {0}: DNS сброшен на DHCP.' -f $a.Name) -ForegroundColor Green
        } catch { Write-Host ('[!] {0}: {1}' -f $a.Name, $_.Exception.Message) -ForegroundColor Yellow }
    }
    Clear-DnsCache
    exit 0
}

# status
Write-Host ''
Write-Host '=== DNS-статус ===' -ForegroundColor Cyan
foreach ($a in (Get-ActiveAdapters)) {
    $dns = Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty ServerAddresses
    Write-Host ('  {0} ({1}):' -f $a.Name, $a.InterfaceDescription) -ForegroundColor DarkGray
    if ($dns) { Write-Host ('    DNS: {0}' -f ($dns -join ', ')) } else { Write-Host '    DNS: DHCP (авто)' }
}
$autoDoh = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name 'EnableAutoDoh' -ErrorAction SilentlyContinue).EnableAutoDoh
Write-Host ('  Авто-DoH в реестре: {0}' -f $(if ($autoDoh -eq 2) { 'включён' } else { 'выключен (по умолчанию)' }))
Write-Host ''
Write-Host 'Подсказка: если домены резолвятся в странные IP (см. extra\DIAGNOSTICS.bat) - запустите extra\DNS-SET.bat.'
exit 0
