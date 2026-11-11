<#
.SYNOPSIS
    Rapihkan nama router Traefik + beri prefix duplikat untuk rule yang sama.

.DESCRIPTION
    Scan semua file .yml di bawah $Root (default: folder skrip ini berada),
    rekursif termasuk subfolder.

    Untuk setiap router:
      1. Nama dasar dibangun dari <version>_<segmen-path>..._<METHOD>.
      2. Jika rule (isi `rule: "..."`) muncul lebih dari sekali di seluruh file:
           - kemunculan ke-1  -> tanpa prefix
           - kemunculan ke-2  -> "duplicat_v<X>_"  + nama dasar
           - kemunculan ke-3+ -> "duplicat-<N>_v<X>_" + nama dasar  (N = kemunculan - 1)
         <X> adalah versi yang terdeteksi dari path (v1, v2, dst).

    Method TIDAK diubah besar/kecilnya (mengikuti isi rule).
    Rule, service, entryPoints, middlewares TIDAK diubah.
    Hanya nama router yang di-rewrite.

.PARAMETER Root
    Folder akar pencarian .yml. Default: $PSScriptRoot.

.PARAMETER WhatIf
    Preview tanpa menulis file.

.PARAMETER Backup
    Buat backup .bak sebelum menulis.

.EXAMPLE
    PS> .\rerapihkan-router.ps1 -WhatIf
    PS> .\rerapihkan-router.ps1 -Backup
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Root = $PSScriptRoot,

    [switch]$WhatIf,
    [switch]$Backup
)

# ---------- Validasi ----------
if (-not $Root) { $Root = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $Root)) {
    throw "Folder tidak ditemukan: $Root"
}
$Root = (Resolve-Path -LiteralPath $Root).Path

$files = @(
    Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.yml' |
    Sort-Object FullName
)
if ($files.Count -eq 0) {
    Write-Warning "Tidak ada file .yml di bawah: $Root"
    return
}

Write-Host "Scan folder : $Root" -ForegroundColor Cyan
Write-Host "File .yml   : $($files.Count)" -ForegroundColor Cyan
Write-Host ("Mode        : " + $(if ($WhatIf) { 'WHATIF (preview)' } else { 'APPLY (menulis file)' })) -ForegroundColor Cyan
Write-Host ''

# ---------- Helper: nama dasar router ----------
function Convert-ToRouterName {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Method
    )

    $segments = @($Path -split '/' | Where-Object { $_ -ne '' })
    if ($segments.Count -eq 0) { return $null }

    # Version: /v1.0/ -> v1, /v2.0/ -> v2
    $versionPart = $null
    if ($segments[0] -match '^v(\d+)\.\d+$') {
        $versionPart = "v$($Matches[1])"
        $segments = if ($segments.Count -gt 1) { $segments[1..($segments.Count - 1)] } else { @() }
    }

    # Buang segmen :param & trailing numeric
    $kept = @()
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $seg               = $segments[$i]
        $isParam           = $seg -match '^:'
        $isTrailingNumeric = ($i -eq $segments.Count - 1) -and ($seg -match '^\d+$')
        if ($isParam -or $isTrailingNumeric) { continue }
        $kept += $seg
    }
    if ($kept.Count -eq 0) { return $null }

    # Method TIDAK diubah (sesuai isi rule)
    $methodSuffix = $Method

    $parts = @()
    if ($versionPart) { $parts += $versionPart }
    $parts += $kept
    $parts += $methodSuffix
    return ($parts -join '_')
}

# ---------- Helper: prefix duplikat ----------
function Add-DuplicatPrefix {
    param(
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Occurrence
    )

    # Pisahkan version prefix dari BaseName (v1_xxx_POST -> v1 + xxx_POST)
    $versionPart = $null
    $rest        = $BaseName
    if ($BaseName -match '^(v\d+)_(.+)$') {
        $versionPart = $Matches[1]
        $rest        = $Matches[2]
    }
    elseif ($Path -match '^/v(\d+)\.\d+') {
        $versionPart = "v$($Matches[1])"
    }
    else {
        $versionPart = 'v1'
    }

    if ($Occurrence -eq 2) {
        return "duplicat_${versionPart}_$rest"
    }
    $n = $Occurrence - 1
    return "duplicat-${n}_${versionPart}_$rest"
}

# ---------- Baca semua file & kumpulkan router ----------
$fileContents = @{}   # path -> @{ Lines; Eol; HasBom }
$items        = [System.Collections.Generic.List[object]]::new()

foreach ($file in $files) {
    $bytes  = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text   = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }

    $eol   = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [string[]]($text -split "`r?`n")

    $fileContents[$file.FullName] = @{
        Lines  = $lines
        Eol    = $eol
        HasBom = $hasBom
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^(\s+)([A-Za-z0-9_\-]+):\s*$') { continue }
        $indent  = $Matches[1]
        $oldName = $Matches[2]

        $ruleIdx = -1
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            if ($lines[$j].Trim() -ne '') { $ruleIdx = $j; break }
        }
        if ($ruleIdx -lt 0) { continue }
        if ($lines[$ruleIdx] -notmatch 'rule:\s*"(.*)"\s*$') { continue }
        $ruleContent = $Matches[1]

        if ($ruleContent -notmatch 'PathPrefix\(`([^`]+)`\)') { continue }
        $path = $Matches[1]
        if ($ruleContent -notmatch 'Method\(`(\w+)`\)') { continue }
        $method = $Matches[1]

        $items.Add([PSCustomObject]@{
            FilePath    = $file.FullName
            FileName    = $file.Name
            LineIndex   = $i
            Indent      = $indent
            OldName     = $oldName
            RuleContent = $ruleContent
            Path        = $path
            Method      = $method
            NewName     = $null
            Skip        = $false
        })
    }
}

# ---------- Hitung occurrence per rule + tentukan nama baru ----------
$ruleCount     = @{}
$finalNameUses = @{}   # newName -> List[ruleContent]

foreach ($item in $items) {
    $baseName = Convert-ToRouterName -Path $item.Path -Method $item.Method
    if (-not $baseName) {
        $item.NewName = $item.OldName
        $item.Skip    = $true
        continue
    }

    $key = $item.RuleContent
    if ($ruleCount.ContainsKey($key)) { $ruleCount[$key]++ } else { $ruleCount[$key] = 1 }
    $occ = $ruleCount[$key]

    if ($occ -eq 1) {
        $newName = $baseName
    }
    else {
        $newName = Add-DuplicatPrefix -BaseName $baseName -Path $item.Path -Occurrence $occ
    }

    $item.NewName = $newName

    if (-not $finalNameUses.ContainsKey($newName)) {
        $finalNameUses[$newName] = [System.Collections.Generic.List[string]]::new()
    }
    $finalNameUses[$newName].Add($item.RuleContent)
}

# ---------- Deteksi tabrakan nyata (rule berbeda -> nama sama) ----------
$collisions = @{}
foreach ($kv in $finalNameUses.GetEnumerator()) {
    $uniqueRules = @($kv.Value | Select-Object -Unique)
    if ($uniqueRules.Count -gt 1) {
        $collisions[$kv.Key] = $uniqueRules
    }
}

if ($collisions.Count -gt 0) {
    Write-Warning "Terdeteksi tabrakan nama (rule berbeda menghasilkan nama sama):"
    foreach ($kv in $collisions.GetEnumerator()) {
        Write-Warning "  $($kv.Key)  <-  $($kv.Value -join '  |  ')"
    }
    Write-Host ''
}

# ---------- Terapkan perubahan ----------
$changesByFile = @{}
foreach ($item in $items) {
    if ($item.Skip) { continue }
    if ($item.NewName -eq $item.OldName) { continue }

    if ($collisions.ContainsKey($item.NewName)) {
        Write-Warning "Skip '$($item.OldName)' -> '$($item.NewName)' (tabrakan)"
        continue
    }

    if (-not $changesByFile.ContainsKey($item.FilePath)) {
        $changesByFile[$item.FilePath] = [System.Collections.Generic.List[object]]::new()
    }
    $changesByFile[$item.FilePath].Add($item)
}

if ($changesByFile.Count -eq 0) {
    Write-Host "Tidak ada perubahan." -ForegroundColor Green
    return
}

$totalFiles   = 0
$totalRenamed = 0

foreach ($filePath in $changesByFile.Keys) {
    $fc     = $fileContents[$filePath]
    $work   = [string[]]::new($fc.Lines.Count)
    [Array]::Copy($fc.Lines, $work, $fc.Lines.Count)

    Write-Host "[$filePath]" -ForegroundColor Cyan
    foreach ($chg in $changesByFile[$filePath]) {
        Write-Host ("  {0,-45} -> {1}" -f $chg.OldName, $chg.NewName) -ForegroundColor Yellow
        $work[$chg.LineIndex] = "$($chg.Indent)$($chg.NewName):"
    }

    $fileName = [System.IO.Path]::GetFileName($filePath)
    $count    = $changesByFile[$filePath].Count

    if ($WhatIf) {
        Write-Host "  [WHATIF] tidak menulis $fileName ($count router)" -ForegroundColor DarkYellow
    }
    else {
        if ($Backup) {
            $bak = "$filePath.bak"
            Copy-Item -LiteralPath $filePath -Destination $bak -Force
            Write-Host "  [BAK] $bak" -ForegroundColor DarkCyan
        }
        $newText = ($work -join $fc.Eol)
        $enc     = [System.Text.UTF8Encoding]::new([bool]$fc.HasBom)
        [System.IO.File]::WriteAllText($filePath, $newText, $enc)
        Write-Host "  [OK] $fileName ($count router)" -ForegroundColor Green
    }
    Write-Host ''

    $totalFiles++
    $totalRenamed += $count
}

Write-Host ("Selesai. File diubah: {0}, total router di-rename: {1}" -f $totalFiles, $totalRenamed) -ForegroundColor Cyan
