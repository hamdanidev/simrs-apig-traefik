<#
.SYNOPSIS
    Rapihkan urutan router Traefik: pindahkan blok "duplicat_" tepat di bawah router aslinya.
    Opsional: comment out blok duplikat.

.DESCRIPTION
    Scan semua .yml rekursif dari -Root. Untuk setiap file:
      - Deteksi blok router (name line yang diikuti rule: "PathPrefix(...)").
      - Kelompokkan blok berdasarkan nama dasar (strip prefix "duplicat_" / "duplicat-N_").
      - Susun ulang: original dulu, lalu semua duplikatnya (order asli).
      - Jika -Comment: setiap baris blok duplikat diberi prefix "# " (idempoten).

.PARAMETER Root
    Folder akar. Default: folder tempat script berada.

.PARAMETER Comment
    Comment out blok duplikat. Alias: -Hide

.PARAMETER WhatIf
    Dry-run (tidak menulis file).

.PARAMETER Backup
    Buat backup .bak sebelum menimpa.

.EXAMPLE
    .\rapihkan-router.ps1 -Root .\dynamic -Comment -Backup

.EXAMPLE
    .\rapihkan-router.ps1 .\dynamic -WhatIf
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Root = $PSScriptRoot,

    [Alias('Hide')]
    [switch]$Comment,

    [switch]$WhatIf,
    [switch]$Backup
)

if (-not $Root) { $Root = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $Root)) {
    throw "Folder tidak ditemukan: $Root"
}
$Root = (Resolve-Path -LiteralPath $Root).Path

$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.yml' | Sort-Object FullName)
if ($files.Count -eq 0) {
    Write-Warning "Tidak ada file .yml di bawah: $Root"
    return
}

Write-Host "Scan folder : $Root" -ForegroundColor Cyan
Write-Host "File .yml   : $($files.Count)" -ForegroundColor Cyan
Write-Host ("Mode        : " + $(if ($WhatIf) { 'WHATIF' } else { 'APPLY' }) + $(if ($Comment) { ' + COMMENT' } else { '' })) -ForegroundColor Cyan
Write-Host ''

# ---------- Helpers ----------
function Get-BaseName {
    param([string]$Name)
    if ($Name -match '^duplicat(?:-\d+)?_(.+)$') { return $Matches[1] }
    return $Name
}

function Test-IsDuplicate {
    param([string]$Name)
    return ($Name -match '^duplicat(?:-\d+)?_')
}

function Find-RouterBlocks {
    param([string[]]$Lines)

    $blocks = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch '^(\s+)([A-Za-z0-9_.\-]+):\s*$') { continue }
        $indent = $Matches[1]
        $name   = $Matches[2]

        $ruleIdx = -1
        for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
            if ($Lines[$j].Trim() -ne '') { $ruleIdx = $j; break }
        }
        if ($ruleIdx -lt 0) { continue }
        if ($Lines[$ruleIdx] -notmatch 'rule:\s*"(.*)"\s*$') { continue }
        $ruleContent = $Matches[1]

        if ($ruleContent -notmatch 'PathPrefix\(`([^`]+)`\)') { continue }
        $path = $Matches[1]
        if ($ruleContent -notmatch 'Method\(`(\w+)`\)') { continue }
        $method = $Matches[1]

        $endIdx = $Lines.Count - 1
        for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
            if ($Lines[$j].Trim() -eq '') { continue }

            if ($Lines[$j] -match "^$indent[A-Za-z0-9_.\-]+:\s*$") {
                $nextRuleIdx = -1
                for ($k = $j + 1; $k -lt $Lines.Count; $k++) {
                    if ($Lines[$k].Trim() -ne '') { $nextRuleIdx = $k; break }
                }
                if ($nextRuleIdx -ge 0 -and $Lines[$nextRuleIdx] -match '^\s*rule:\s*"') {
                    $endIdx = $j - 1
                    break
                }
            }

            if ($Lines[$j] -match '^(\s*)\S' -and $Matches[1].Length -lt $indent.Length) {
                $endIdx = $j - 1
                break
            }
        }

        $realEnd = $endIdx
        while ($realEnd -gt $i -and $Lines[$realEnd].Trim() -eq '') { $realEnd-- }

        $blocks.Add([PSCustomObject]@{
            StartLine = $i
            EndLine   = $realEnd
            Indent    = $indent
            Name      = $name
            BaseName  = (Get-BaseName $name)
            IsDup     = (Test-IsDuplicate $name)
        })
    }

    return $blocks
}

function Add-CommentPrefix {
    param([string[]]$BlockLines)
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $BlockLines) {
        if ($line.Trim() -eq '') {
            $result.Add($line)
        } elseif ($line -match '^(\s*)(.*)$') {
            $indent  = $Matches[1]
            $content = $Matches[2]
            if ($content.StartsWith('#')) {
                # sudah pernah di-comment -> idempoten
                $result.Add($line)
            } else {
                $result.Add("$indent# $content")
            }
        } else {
            $result.Add("# $line")
        }
    }
    return $result.ToArray()
}

# ---------- Proses per file ----------
$totalFiles    = 0
$totalCommented = 0
$totalSkipped  = 0

foreach ($file in $files) {
    $bytes  = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text   = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    $eol    = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines  = [string[]]($text -split "`r?`n")

    $blocks = @(Find-RouterBlocks -Lines $lines)
    if ($blocks.Count -eq 0) { continue }

    # Group by base name, urut berdasarkan kemunculan pertama
    $groupResults = @(
        $blocks | Group-Object -Property BaseName |
        Sort-Object { ($_.Group | Measure-Object -Property StartLine -Minimum).Minimum }
    )

    $hasWork = $false
    foreach ($grp in $groupResults) {
        if (($grp.Group | Where-Object { $_.IsDup }).Count -gt 0) { $hasWork = $true; break }
    }
    if (-not $hasWork) { continue }

    # Susun urutan baru: original dulu, lalu semua duplikatnya
    $orderedBlocks = [System.Collections.Generic.List[object]]::new()
    foreach ($grp in $groupResults) {
        $sorted = @($grp.Group | Sort-Object @{Expression = { [int]$_.IsDup }}, StartLine)
        foreach ($b in $sorted) { $orderedBlocks.Add($b) }
    }

    # Bangun konten baru
    $newLines = [System.Collections.Generic.List[string]]::new()

    # Prefix (sebelum blok pertama)
    for ($i = 0; $i -lt $blocks[0].StartLine; $i++) {
        $newLines.Add($lines[$i])
    }

    $commentedCount = 0
    $origLastBlock  = $blocks[$blocks.Count - 1]

    for ($idx = 0; $idx -lt $orderedBlocks.Count; $idx++) {
        $block      = $orderedBlocks[$idx]
        $blockLines = @($lines[$block.StartLine..$block.EndLine])

        if ($Comment -and $block.IsDup) {
            $blockLines = Add-CommentPrefix -BlockLines $blockLines
            $commentedCount++
        }

        foreach ($l in $blockLines) { $newLines.Add($l) }

        # 1 baris kosong pemisah antar blok di output
        if ($idx -lt $orderedBlocks.Count - 1) {
            $newLines.Add('')
        }
    }

    # Suffix (konten setelah blok terakhir asli)
    for ($i = $origLastBlock.EndLine + 1; $i -lt $lines.Count; $i++) {
        $newLines.Add($lines[$i])
    }

    $newText = ($newLines -join $eol)
    if ($newText -eq $text) {
        Write-Host ("[SKIP] {0} (tidak ada perubahan)" -f $file.Name) -ForegroundColor DarkGray
        $totalSkipped++
        continue
    }

    Write-Host "[$($file.FullName)]" -ForegroundColor Cyan
    Write-Host ("  blok: {0}, group: {1}, duplikat: {2}, di-comment: {3}" -f `
        $blocks.Count, $groupResults.Count,
        (($blocks | Where-Object { $_.IsDup }).Count), $commentedCount) -ForegroundColor Yellow

    if ($WhatIf) {
        Write-Host ("  [WHATIF] tidak menulis {0}" -f $file.Name) -ForegroundColor DarkYellow
    }
    else {
        if ($Backup) {
            Copy-Item -LiteralPath $file.FullName -Destination "$($file.FullName).bak" -Force
            Write-Host ("  [BAK] {0}.bak" -f $file.FullName) -ForegroundColor DarkCyan
        }
        $enc = [System.Text.UTF8Encoding]::new([bool]$hasBom)
        [System.IO.File]::WriteAllText($file.FullName, $newText, $enc)
        Write-Host ("  [OK] {0}" -f $file.Name) -ForegroundColor Green
    }
    Write-Host ''

    $totalFiles++
    $totalCommented += $commentedCount
}

Write-Host ("Selesai. File diubah: {0}, duplikat di-comment: {1}, skip: {2}" -f `
    $totalFiles, $totalCommented, $totalSkipped) -ForegroundColor Cyan
