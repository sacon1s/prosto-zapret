# Exports winws arguments from Flowseal preset .bat files into numbered strategy files.
# Usage: extract-strategies.ps1 -Source <dir with preset bats> [-Dest <strategies dir>]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$Dest
)
$ErrorActionPreference = 'Stop'
if (-not $Dest) { $Dest = Join-Path (Split-Path $PSScriptRoot) 'strategies' }

$order = @(
    'general.bat',
    'general (EXP).bat',
    'general (ALT11).bat',
    'general (ALT12).bat',
    'general (ALT13).bat',
    'general (ALT10).bat',
    'general (ALT9).bat',
    'general (ALT8).bat',
    'general (ALT7).bat',
    'general (ALT6).bat',
    'general (ALT4).bat',
    'general (ALT3).bat',
    'general (ALT2).bat',
    'general (ALT1).bat',
    'general (ALT).bat',
    'general (FAKE TLS AUTO).bat',
    'general (FAKE TLS AUTO ALT).bat',
    'general (FAKE TLS AUTO ALT2).bat',
    'general (FAKE TLS AUTO ALT3).bat',
    'general (SIMPLE FAKE).bat',
    'general (SIMPLE FAKE ALT).bat',
    'general (SIMPLE FAKE ALT2).bat',
    'general (ALT5).bat'
)

$idx = 0
$indexLines = @()
foreach ($f in $order) {
    $p = Join-Path $Source $f
    if (-not (Test-Path $p)) { continue }
    $idx++
    $lines = Get-Content $p
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -like 'start *winws.exe*') { $start = $i; break }
    }
    if ($start -lt 0) { continue }
    $out = @()
    for ($j = $start; $j -lt $lines.Count; $j++) {
        $L = $lines[$j] -replace '^start\s+"[^"]*"\s+\S+\s+"?%BIN%winws\.exe"?\s*', ''
        if ($L.EndsWith('^')) { $out += $L.Substring(0, $L.Length - 1) } else { $out += $L; break }
    }
    $name = [IO.Path]::GetFileNameWithoutExtension($f)
    $file = Join-Path $Dest ('{0:D2}.txt' -f $idx)
    $header = '# ' + $name
    $argsLine = $out -join ' '
    $content = @($header, $argsLine, '')
    $content | Set-Content $file -Encoding ASCII
    $indexLines += ('{0:D2} = {1}' -f $idx, $name)
    Write-Host ("  {0:D2} <- {1}" -f $idx, $name)
}
$indexLines | Set-Content (Join-Path $Dest 'INDEX.txt') -Encoding ASCII
Write-Host "Extracted: $idx strategies"
