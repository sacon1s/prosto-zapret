# generate-strategies.ps1 - validate + fix + generate custom strategies from the winws capability set.
# Run after every core update. Safe to repeat: identical combos are skipped.
param([string]$HelpFile, [string]$AppRoot)
$ErrorActionPreference = 'Stop'
if (-not $AppRoot) { $AppRoot = Split-Path $PSScriptRoot -Parent }
$stratDir = Join-Path $AppRoot 'strategies'
$helpPath = if ($HelpFile) { $HelpFile } else { Join-Path $PSScriptRoot 'winws-help.txt' }

# ---------- 1. capability set from the bundled winws ----------
if (-not (Test-Path $helpPath)) { throw "winws help not found: $helpPath (run: winws --help > this file)" }
$help = [IO.File]::ReadAllText($helpPath, [Text.Encoding]::UTF8)

$modesLine = ''
if ($help -match '--dpi-desync=\[<mode0>,\]<mode>\[,<mode2>\][^\r\n]*\r?\n([^\r\n]*\r?\n[^\r\n]*)') { $modesLine = $Matches[1] -join ' ' }
$hasMode = {
    param([string]$m)
    if ($m -eq 'multisplit2') { return $false }   # does not exist in this build
    if ($m -eq 'ipfrag') { return $false }        # this build has ipfrag1 / ipfrag2
    if ($modesLine) { return ($modesLine -match ('\b' + [regex]::Escape($m) + '\b')) }
    return $true
}
$hasOpt = {
    param([string]$o)
    return ($help -match [regex]::Escape($o))
}

# ---------- 2. fix invalid names in existing custom strategies ----------
$fixed = 0
foreach ($f in (Get-ChildItem $stratDir -Filter '*.txt')) {
    if ($f.Name -eq 'INDEX.txt') { continue }
    $t = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
    $orig = $t
    $t = $t.Replace('--dpi-desync=multisplit2', '--dpi-desync=multisplit')
    $t = [regex]::Replace($t, '--dpi-desync=ipfrag(?![12])', '--dpi-desync=ipfrag2')
    if ($t -ne $orig) { [IO.File]::WriteAllText($f.FullName, $t, (New-Object Text.UTF8Encoding($false))); $fixed++; Write-Host ('fixed: ' + $f.Name) }
}
Write-Host ('invalid names fixed: ' + $fixed)

# ---------- 3. combo table: overriding general-TCP sections prepended to the proven base ----------
$b01 = Join-Path $stratDir '01.txt'
if (-not (Test-Path $b01)) { throw 'base strategy 01.txt is missing' }
$base01 = (@(Get-Content $b01) | Where-Object { $_ -notmatch '^\s*#' }) -join ' '
$sec = '--filter-tcp=443 --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" '
$secUD = '--filter-udp=443 --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" '
$fakeG = '"%BIN%tls_clienthello_www_google_com.bin"'
$quicG = '"%BIN%quic_initial_www_google_com.bin"'
$quicP = '"%BIN%quic_initial_4pda_to.bin"'
$bases = @('01', '26')

$combos = @()
function Add-C([string]$Name, [string]$Section) { $script:combos += @{ name = $Name; section = $Section } }

# A. hostfakesplit: fake host inserted inside the real ClientHello
Add-C 'hostfakesplit ts'                       ($sec + '--dpi-desync=hostfakesplit --dpi-desync-fooling=ts --dpi-desync-fake-tls=' + $fakeG)
Add-C 'hostfakesplit host=google ts'           ($sec + '--dpi-desync=hostfakesplit --dpi-desync-hostfakesplit-mod=host=www.google.com --dpi-desync-fooling=ts --dpi-desync-fake-tls=' + $fakeG)
Add-C 'hostfakesplit host=google badseq'       ($sec + '--dpi-desync=hostfakesplit --dpi-desync-hostfakesplit-mod=host=www.google.com --dpi-desync-fooling=badseq --dpi-desync-fake-tls=' + $fakeG)
Add-C 'hostfakesplit midhost ts'               ($sec + '--dpi-desync=hostfakesplit --dpi-desync-hostfakesplit-midhost=midsld --dpi-desync-fooling=ts --dpi-desync-fake-tls=' + $fakeG)

# B. fakedsplit altorder variants
foreach ($a in 1, 2, 3) {
    Add-C ('fakedsplit altorder' + $a + ' ts') ($sec + '--dpi-desync=fakedsplit --dpi-desync-fakedsplit-mod=altorder=' + $a + ' --dpi-desync-fooling=ts --dpi-desync-fake-tls=' + $fakeG)
}

# C. fake TLS mods: randomized + replaced SNI inside the fake
Add-C 'fake,split2 tls-mod rndsni+sni'         ($sec + '--dpi-desync=fake,split2 --dpi-desync-fake-tls-mod=rndsni,sni=www.google.com --dpi-desync-fooling=ts --dpi-desync-fake-tls=' + $fakeG)
Add-C 'fake,multisplit tls-mod rndsni+sni'     ($sec + '--dpi-desync=fake,multisplit --dpi-desync-fake-tls-mod=rndsni,sni=www.google.com --dpi-desync-fooling=ts --dpi-desync-fake-tls=' + $fakeG)
Add-C 'fake,disorder2 tls-mod padencap'        ($sec + '--dpi-desync=fake,disorder2 --dpi-desync-fake-tls-mod=padencap --dpi-desync-fooling=ts --dpi-desync-fake-tls=' + $fakeG)
Add-C 'fake,split2 tls-mod dupsid'             ($sec + '--dpi-desync=fake,split2 --dpi-desync-fake-tls-mod=dupsid --dpi-desync-fooling=ts --dpi-desync-fake-tls=' + $fakeG)
Add-C 'fake tls-mod rndsni+sni'                ($sec + '--dpi-desync=fake --dpi-desync-fake-tls-mod=rndsni,sni=www.google.com --dpi-desync-fooling=ts --dpi-desync-fake-tls=' + $fakeG)

# D. marker splits: cut at the domain boundary itself
Add-C 'fake,split2 split=sld ts'               ($sec + '--dpi-desync=fake,split2 --dpi-desync-split-pos=sld --dpi-desync-fooling=ts --dpi-desync-fake-tls=' + $fakeG)
Add-C 'multisplit split=midsld ts'             ($sec + '--dpi-desync=multisplit --dpi-desync-split-pos=midsld --dpi-desync-fooling=ts')
Add-C 'fake,disorder2 split=endsld ts'         ($sec + '--dpi-desync=fake,disorder2 --dpi-desync-split-pos=endsld --dpi-desync-fooling=ts --dpi-desync-fake-tls=' + $fakeG)
Add-C 'multisplit split=method+sld'            ($sec + '--dpi-desync=multisplit --dpi-desync-split-pos=method,sld --dpi-desync-fooling=ts')

# E. wssize: tiny advertised TCP window defeats reassembly-based filters
Add-C 'wssize on multisplit'                   ($sec + '--dpi-desync=multisplit --dpi-desync-fooling=ts --wssize=1:6')
Add-C 'wssize on fake,split2'                  ($sec + '--dpi-desync=fake,split2 --dpi-desync-fooling=ts --wssize=1:6 --dpi-desync-fake-tls=' + $fakeG)
Add-C 'wssize alone'                           ($sec + '--wssize=1:6')

# F. QUIC (UDP 443) with alternative fake bins and udplen padding
Add-C 'quic fake 4pda'                         ($secUD + '--dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic=' + $quicP)
Add-C 'quic udplen +16'                        ($secUD + '--dpi-desync=udplen --dpi-desync-udplen-increment=16 --dpi-desync-udplen-pattern=' + $quicG)
Add-C 'quic udplen +32 fake 4pda'              ($secUD + '--dpi-desync=udplen --dpi-desync-udplen-increment=32 --dpi-desync-udplen-pattern=' + $quicG + ' --dpi-desync-fake-quic=' + $quicP)

# G. mode0 combos: send a real SYN-with-data before the main desync
Add-C 'syndata->multisplit ts'                 ($sec + '--dpi-desync=syndata,multisplit --dpi-desync-fooling=ts')
Add-C 'syndata->fake,split2 ts'                ($sec + '--dpi-desync=syndata,fake,split2 --dpi-desync-fooling=ts --dpi-desync-fake-tls=' + $fakeG)

# H. badseq with custom increments
Add-C 'fake,split2 badseq inc-100000'          ($sec + '--dpi-desync=fake,split2 --dpi-desync-fooling=badseq --dpi-desync-badseq-increment=-100000 --dpi-desync-repeats=6 --dpi-desync-fake-tls=' + $fakeG)
Add-C 'multisplit badack inc-2 ts'             ($sec + '--dpi-desync=multisplit --dpi-desync-fooling=ts,badack --dpi-desync-badack-increment=-2 --dpi-desync-repeats=6')

# I. skip-nosni=0: act on ClientHello without SNI too (MTProto and others)
Add-C 'multisplit nosni=0 ts'                  ($sec + '--dpi-desync=multisplit --dpi-desync-skip-nosni=0 --dpi-desync-fooling=ts --dpi-desync-repeats=6')

# keep only combos whose modes/flags this build supports
$valid = @()
foreach ($c in $combos) {
    $ok = $true
    $mvals = [regex]::Matches($c.section, '--dpi-desync=([a-z0-9,]+)')
    foreach ($mm in $mvals) {
        foreach ($tok in ($mm.Groups[1].Value -split ',')) {
            if (-not (& $hasMode $tok)) { $ok = $false }
        }
    }
    foreach ($opt in @('--wssize=1:6', '--dpi-desync-udplen-increment=16', '--dpi-desync-fake-tls-mod=', '--dpi-desync-fakedsplit-mod=', '--dpi-desync-hostfakesplit-midhost=', '--dpi-desync-badack-increment=', '--dpi-desync-skip-nosni=0')) {
        if ($c.section.Contains($opt) -and -not (& $hasOpt ($opt -replace '=.*$', ''))) { $ok = $false }
    }
    if ($ok) { $valid += $c }
}
Write-Host ('valid combos: ' + $valid.Count + ' of ' + $combos.Count)

# ---------- 4. write to free numbers from 120, deduped ----------
$existing = @{}
foreach ($f in (Get-ChildItem $stratDir -Filter '*.txt')) {
    if ($f.Name -eq 'INDEX.txt') { continue }
    $lines = @(Get-Content $f.FullName | Where-Object { $_ -notmatch '^\s*#' })
    if ($lines.Count -gt 1) { $existing[[string]::Join(' ', $lines[1..($lines.Count - 1)])] = $true }
}
$num = 120
$written = 0
foreach ($c in $valid) {
    $argsLine = ($c.section + ' ' + $base01)
    if (-not $argsLine) { continue }
    if ($existing.ContainsKey($argsLine)) { continue }
    $existing[$argsLine] = $true
    while ((Test-Path (Join-Path $stratDir ('{0:D2}.txt' -f $num))) -or (Test-Path (Join-Path $stratDir ('{0}.txt' -f $num)))) { $num++ }
    $content = @('# custom: ' + $c.name, $argsLine, '')
    [IO.File]::WriteAllText((Join-Path $stratDir ('{0}.txt' -f $num)), ($content -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding($false)))
    $num++
    $written++
}
$total = @(Get-ChildItem $stratDir -Filter '*.txt' | Where-Object { $_.Name -ne 'INDEX.txt' }).Count
Write-Host ('written: ' + $written + ', total strategies: ' + $total)
