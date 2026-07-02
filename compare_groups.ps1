param(
    [string]$TmpFile = "ruby_tools\tmp.txt",
    [string]$ProcessedFile = "ruby_tools\opencode_generated\processed\script03_fid0D.txt"
)

function Get-GroupTextIds([string]$filePath) {
    $groups = @{}
    $currentGroup = $null
    $currentTextIds = @()
    
    Get-Content -LiteralPath $filePath -Encoding UTF8 | ForEach-Object {
        $line = $_
        if ($line -match '^--- Group (\d+) ') {
            if ($currentGroup -ne $null) {
                $sorted = ($currentTextIds | Sort-Object) -join ','
                $groups[$currentGroup] = $sorted
            }
            $currentGroup = $matches[1]
            $currentTextIds = @()
        }
        elseif ($line -match 'TEXT:([0-9A-Fa-f]{4})' -and $currentGroup -ne $null) {
            $id = $matches[1].ToUpper()
            if ($id -notin $currentTextIds) { $currentTextIds += $id }
        }
    }
    if ($currentGroup -ne $null) {
        $sorted = ($currentTextIds | Sort-Object) -join ','
        $groups[$currentGroup] = $sorted
    }
    return $groups
}

$tmpGroups = Get-GroupTextIds $TmpFile
$procGroups = Get-GroupTextIds $ProcessedFile

Write-Output "=== tmp.txt groups: $($tmpGroups.Count) ==="
Write-Output "=== processed/script03_fid0D.txt groups: $($procGroups.Count) ==="
Write-Output ""

# Compare by TEXT ID set (reverse lookup: build signature -> group numbers)
$tmpSigToGroup = @{}
foreach ($g in $tmpGroups.GetEnumerator()) {
    if ($g.Value) {
        $key = $g.Value
        if (-not $tmpSigToGroup.ContainsKey($key)) { $tmpSigToGroup[$key] = @() }
        $tmpSigToGroup[$key] += $g.Name
    }
}

$procSigToGroup = @{}
foreach ($g in $procGroups.GetEnumerator()) {
    if ($g.Value) {
        $key = $g.Value
        if (-not $procSigToGroup.ContainsKey($key)) { $procSigToGroup[$key] = @() }
        $procSigToGroup[$key] += $g.Name
    }
}

# Groups in tmp but not in processed
$onlyTmp = @()
foreach ($sig in $tmpSigToGroup.Keys) {
    if (-not $procSigToGroup.ContainsKey($sig)) { $onlyTmp += $sig }
}

# Groups in processed but not in tmp
$onlyProc = @()
foreach ($sig in $procSigToGroup.Keys) {
    if (-not $tmpSigToGroup.ContainsKey($sig)) { $onlyProc += $sig }
}

if ($onlyTmp) {
    Write-Output "=== Groups ONLY in tmp.txt (not in processed) ==="
    foreach ($sig in $onlyTmp) {
        $groupNums = $tmpSigToGroup[$sig]
        Write-Output "  Group(s) $($groupNums -join ', '): TEXT=[$sig]"
    }
    Write-Output "  Total: $($onlyTmp.Count) unique TEXT-ID-sets"
}

if ($onlyProc) {
    Write-Output ""
    Write-Output "=== Groups ONLY in processed (not in tmp.txt) ==="
    foreach ($sig in $onlyProc) {
        $groupNums = $procSigToGroup[$sig]
        Write-Output "  Group(s) $($groupNums -join ', '): TEXT=[$sig]"
    }
    Write-Output "  Total: $($onlyProc.Count) unique TEXT-ID-sets"
}

if (-not $onlyTmp -and -not $onlyProc) {
    Write-Output "All groups match perfectly between tmp.txt and processed/script03_fid0D.txt"
}
