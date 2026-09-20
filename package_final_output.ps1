#Requires -Version 5.1
<#
.SYNOPSIS
    Assemble and package the final BizHawk distribution.

.DESCRIPTION
    1. Copy the built ROM (bin + cue) into final_output\Roms
    2. Run copy_runtime_files.bat to copy the plugin runtime files into the
       BizHawk folder (..\summon_night_bizhawk\BizHawk\ExternalTools)
    3. Copy those ExternalTools files into final_output\ExternalTools,
       skipping translation_comment.json and the logs\ folder
    4. Write final_output\zipignore.txt listing everything excluded from the archive
    5. Pack final_output with 7z, skipping the paths in zipignore.txt plus the
       archive itself

    The resulting .7z archive is placed in final_output.
#>
[CmdletBinding()]
param(
    [string]$ArchiveName = 'SummonNight_Chinese_BizHawk.7z',
    [string]$SevenZipPath
)

$ErrorActionPreference = 'Stop'

function Resolve-SevenZip {
    param([string]$Explicit)
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) { throw "7z not found: $Explicit" }
        return $Explicit
    }
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
        "$env:LOCALAPPDATA\Programs\7-Zip\7z.exe"
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    throw '7z.exe not found. Install 7-Zip or pass -SevenZipPath.'
}

$root         = $PSScriptRoot
$finalOutput  = Join-Path $root 'final_output'
$romSourceDir = Join-Path $root 'romhack\output'
$bizhawkTools = Join-Path $root '..\summon_night_bizhawk\BizHawk\ExternalTools'
$finalRoms    = Join-Path $finalOutput 'Roms'
$finalTools   = Join-Path $finalOutput 'ExternalTools'

if (-not (Test-Path -LiteralPath $finalOutput)) {
    throw "final_output not found: $finalOutput"
}

# ---------------------------------------------------------------------------
# 1. Copy the built ROM
# ---------------------------------------------------------------------------
Write-Host '==> Copying ROM to final_output\Roms ...'
New-Item -ItemType Directory -Force -Path $finalRoms | Out-Null
foreach ($f in 'Summon_Night_Chinese.bin', 'Summon_Night_Chinese.cue') {
    $src = Join-Path $romSourceDir $f
    if (-not (Test-Path -LiteralPath $src)) { throw "ROM file not found: $src" }
    Copy-Item -LiteralPath $src -Destination $finalRoms -Force
}

# ---------------------------------------------------------------------------
# 2. Copy runtime files into the BizHawk folder
# ---------------------------------------------------------------------------
Write-Host '==> Running copy_runtime_files.bat ...'
& (Join-Path $root 'copy_runtime_files.bat')
if ($LASTEXITCODE -ne 0) { throw "copy_runtime_files.bat failed (exit $LASTEXITCODE)" }

# ---------------------------------------------------------------------------
# 3. Copy ExternalTools -> final_output\ExternalTools (with exclusions)
# ---------------------------------------------------------------------------
Write-Host '==> Copying ExternalTools into final_output ...'
$toolsSkip = @('translation_comment.json', 'logs')
New-Item -ItemType Directory -Force -Path $finalTools | Out-Null
Get-ChildItem -LiteralPath $bizhawkTools -Force |
    Where-Object { $toolsSkip -notcontains $_.Name } |
    ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $finalTools -Recurse -Force
    }

# ---------------------------------------------------------------------------
# 4. Write zipignore.txt (also used as the 7z exclude list)
# ---------------------------------------------------------------------------
$ignoreDirs = @(
    'logs',                          # top-level runtime logs
    'PSX',                           # top-level PSX saves/config
    'ExternalTools/logs'             # plugin logs
)
$ignoreFiles = @(
    'ExternalTools/translation_comment.json',
    'zipignore.txt',
    $ArchiveName
)

$zipIgnorePath = Join-Path $finalOutput 'zipignore.txt'
$ignoreLines = [System.Collections.Generic.List[string]]::new()
$ignoreLines.Add("# Paths excluded from $ArchiveName (relative to final_output)")
$ignoreLines.Add('# Directories (matched as prefixes):')
foreach ($d in $ignoreDirs) { $ignoreLines.Add("$d/") }
$ignoreLines.Add('# Files:')
foreach ($f in $ignoreFiles) { $ignoreLines.Add($f) }
[System.IO.File]::WriteAllLines($zipIgnorePath, $ignoreLines, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "==> Wrote $zipIgnorePath"

# ---------------------------------------------------------------------------
# 5. Build the .7z archive with 7z
# ---------------------------------------------------------------------------
$sevenZip    = Resolve-SevenZip $SevenZipPath
$archivePath = Join-Path $finalOutput $ArchiveName
$legacyZip   = Join-Path $finalOutput ([System.IO.Path]::GetFileNameWithoutExtension($ArchiveName) + '.zip')
foreach ($stale in @($archivePath, $legacyZip)) {
    if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
}

Write-Host "==> Packing $ArchiveName with 7z ..."
Push-Location $finalOutput
try {
    & $sevenZip a -t7z -mx=9 "-x@$zipIgnorePath" $ArchiveName '.'
    if ($LASTEXITCODE -ne 0) { throw "7z failed (exit $LASTEXITCODE)" }
}
finally {
    Pop-Location
}

$size = (Get-Item -LiteralPath $archivePath).Length
Write-Host "==> Done: $archivePath"
Write-Host ('==> Archive size: {0:N0} bytes ({1:N2} MB)' -f $size, ($size / 1MB))
