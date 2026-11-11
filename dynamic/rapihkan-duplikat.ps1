<#
.SYNOPSIS
    Rapihkan router Traefik: pindahkan "duplicat_*" tepat di bawah router aslinya.

.DESCRIPTION
    Scan semua .yml / .yaml rekursif dari -Root. Untuk setiap file:
      1. Deteksi blok router Traefik (baris "<indent><nama>:" yang punya anak "rule:").
      2. Blok dengan nama berawalan "duplicat_" / "duplicat-N_" = duplikat.
         Pindahkan tepat di bawah router aslinya (nama tanpa prefix duplicat).
      3. -Comment / -Hide     : jadikan blok duplikat sebagai komentar (# ).
         -UnComment / -UnHide : hapus komentar (# ) dari blok duplikat.
      4. Urutan deterministik (by FullName). Rule/service/entryPoints/middlewares
         tidak diubah. Nama router tidak diubah (aman setelah rapihkan-router.ps1).

.PARAMETER Root
    Folder akar scan (default: lokasi script).

.PARAMETER Comment
    Alias: -Hide. Komentari semua blok duplikat yang belum dikomentari.

.PARAMETER UnComment
    Alias: -UnHide. Hapus komentar (# ) dari blok duplikat yang sedang dikomentari.

.PARAMETER WhatIf
    Dry-run (tidak menulis).

.PARAMETER Backup
    Simpan <file>.bak sebelum menulis.

.EXAMPLE
    .\rapihkan-duplikat.ps1 -Root .\dynamic -WhatIf

.EXAMPLE
    .\rapihkan-duplikat.ps1 -Comment -Backup

.EXAMPLE
    .\rapihkan-duplikat.ps1 -UnComment -WhatIf

.EXAMPLE
    .\rapihkan-duplikat.ps1 -Hide

.EXAMPLE
    .\rapihkan-duplikat.ps1 -UnHide -Backup
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Root = $PSScriptRoot,

    [Alias('Hide')]
    [switch]$Comment,

    [Alias('UnHide')]
    [switch]$UnComment,

    [switch]$WhatIf,
    [switch]$Backup
)

if ($Comment -and $UnComment) {
    throw "Tidak bisa memakai -Comment dan -UnComment bersamaan."
}

if (-not $Root) { $Root = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $Root)) {
    throw "Folder tidak ditemukan: $Root"
}
$Root = (Resolve-Path -LiteralPath $Root).Path

# Commented blocks hanya dideteksi kalau kita mau uncomment
$detectCommented = $UnComment.IsPresent

$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.yml', '*.yaml' | Sort-Object FullName)
if ($files.Count -eq 0) {
    Write-Warning "Tidak ada file .yml/.yaml di bawah: $Root"
    return
}

Write-Host "Scan folder : $Root"                                                -ForegroundColor Cyan
Write-Host "File        : $($files.Count)"                                       -ForegroundColor Cyan
Write-Host ("Mode        : " + $(if ($WhatIf) { 'WHATIF' } else { 'APPLY' }))    -ForegroundColor Cyan
if ($Comment)   { Write-Host "Comment     : ON"                                 -ForegroundColor Cyan }
if ($UnComment) { Write-Host "UnComment   : ON"                                 -ForegroundColor Cyan }
Write-Host ''

# ---------------- Helper ----------------
function Get-OriginalName {
    param([string]$Name)
    if ($Name -match '^duplicat(?:-\d+)?_(.+)$') { return $Matches[1] }
    return $null
}

function Test-IsDuplicateName {
    param([string]$Name)
    return ($Name -match '^duplicat(?:-\d+)?_')
}

# ---------------- Proses per file ----------------
$totalFiles       = 0
$totalMoved       = 0
$totalCommented   = 0
$totalUncommented = 0

foreach ($file in $files) {
    # Baca + deteksi BOM / EOL
    $bytes  = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text   = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }

    $eol   = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [string[]]($text -split "`r?`n")
    $n     = $lines.Count
    if ($n -eq 0) { continue }

    # ---- 1) Deteksi blok ----
    $blocks = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $n; $i++) {
        $line = $lines[$i]

        # Header router aktif:  "<indent><nama>:"
        if ($line -match '^([ \t]+)([A-Za-z0-9_\-]+):[ \t]*$') {
            $ind  = $Matches[1].Length
            $name = $Matches[2]

            $j = $i + 1
            while ($j -lt $n) {
                $l = $lines[$j]
                if ($l.Trim() -eq '') { break }
                if ($l -match '^([ \t]*)' -and $Matches[1].Length -le $ind) { break }
                $j++
            }

            $hasRule = $false
            for ($k = $i + 1; $k -lt $j; $k++) {
                if ($lines[$k] -match '^[ \t]+rule:') { $hasRule = $true; break }
            }
            if (-not $hasRule) { continue }

            $blocks.Add([PSCustomObject]@{
                Name        = $name
                Start       = $i
                End         = $j - 1
                Indent      = $ind
                IsDuplicate = (Test-IsDuplicateName -Name $name)
                IsCommented = $false
            })
            continue
        }

        # Header router TERKOMENTAR:  "<indent># <nama>:"
        # Hanya dideteksi saat -UnComment (supaya tidak mengganggu -Comment / no-flag)
        if ($detectCommented -and $line -match '^([ \t]*)# ([A-Za-z0-9_\-]+):[ \t]*$') {
            $base = $Matches[1].Length
            $name = $Matches[2]
            if (-not (Test-IsDuplicateName -Name $name)) { continue }

            # Anak-anak block: semua baris dengan # di posisi $base
            $prefixPattern = "^[ \t]{$base}#"
            $j = $i + 1
            while ($j -lt $n) {
                $l = $lines[$j]
                if ($l.Trim() -eq '') { break }
                if ($l -notmatch $prefixPattern) { break }
                $j++
            }

            $hasRule = $false
            $rulePattern = "^[ \t]{$base}# [ \t]+rule:"
            for ($k = $i + 1; $k -lt $j; $k++) {
                if ($lines[$k] -match $rulePattern) { $hasRule = $true; break }
            }
            if (-not $hasRule) { continue }

            $blocks.Add([PSCustomObject]@{
                Name        = $name
                Start       = $i
                End         = $j - 1
                Indent      = $base
                IsDuplicate = $true
                IsCommented = $true
            })
        }
    }

    if ($blocks.Count -eq 0) { continue }

    # ---- 2) Map nama & kelompokkan duplikat per original ----
    $blockByName = @{}
    foreach ($b in $blocks) {
        if (-not $blockByName.ContainsKey($b.Name)) { $blockByName[$b.Name] = $b }
    }

    $dupsByOriginal = @{}
    foreach ($b in $blocks) {
        if (-not $b.IsDuplicate) { continue }
        $orig = Get-OriginalName -Name $b.Name
        if (-not $orig) { continue }
        if (-not $blockByName.ContainsKey($orig)) { continue }   # orphan -> diabaikan reorder
        if (-not $dupsByOriginal.ContainsKey($orig)) {
            $dupsByOriginal[$orig] = [System.Collections.Generic.List[object]]::new()
        }
        $dupsByOriginal[$orig].Add($b)
    }

    # ---- 2b) Cek apakah ada aksi yang perlu dilakukan ----
    $hasDups = ($dupsByOriginal.Count -gt 0)
    if (-not $hasDups) {
        # File tidak punya duplicat yang punya original. Cek orphan / aksi flag.
        $orphanDups        = @($blocks | Where-Object { $_.IsDuplicate })
        $orphanUncommented = @($orphanDups | Where-Object { -not $_.IsCommented })
        $orphanCommented   = @($orphanDups | Where-Object { $_.IsCommented })

        $needComment   = $Comment   -and ($orphanUncommented.Count -gt 0)
        $needUnComment = $UnComment -and ($orphanCommented.Count   -gt 0)

        if (-not $needComment -and -not $needUnComment) { continue }
    }

    # ---- 3) Segmentasi baris (block router vs konten lain) ----
    $segments = [System.Collections.Generic.List[object]]::new()
    $i = 0
    while ($i -lt $n) {
        $block = $blocks | Where-Object { $_.Start -eq $i } | Select-Object -First 1
        if ($block) {
            # Include trailing blank lines
            $k = $block.End + 1
            while ($k -lt $n -and $lines[$k].Trim() -eq '') { $k++ }
            $segEnd = $k - 1
            $segments.Add([PSCustomObject]@{
                Type = 'router'; Block = $block; Start = $block.Start; End = $segEnd
            })
            $i = $segEnd + 1
        }
        else {
            $nextStart = $n
            foreach ($b in $blocks) { if ($b.Start -gt $i) { $nextStart = $b.Start; break } }
            $segments.Add([PSCustomObject]@{
                Type = 'other'; Block = $null; Start = $i; End = $nextStart - 1
            })
            $i = $nextStart
        }
    }

    $segByBlockStart = @{}
    foreach ($seg in $segments) {
        if ($seg.Type -eq 'router') { $segByBlockStart[$seg.Block.Start] = $seg }
    }

    # ---- 4) Reorder: original diikuti duplikat-duplikatnya ----
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($seg in $segments) {
        if ($seg.Type -eq 'other') { $ordered.Add($seg); continue }

        $b = $seg.Block
        if ($b.IsDuplicate) {
            $orig = Get-OriginalName -Name $b.Name
            if ($orig -and $blockByName.ContainsKey($orig)) {
                continue   # akan ditambahkan setelah original
            }
        }

        $ordered.Add($seg)
        if ($dupsByOriginal.ContainsKey($b.Name)) {
            $dups = @($dupsByOriginal[$b.Name] | Sort-Object Start)
            foreach ($d in $dups) {
                $dupSeg = $segByBlockStart[$d.Start]
                if ($dupSeg) { $ordered.Add($dupSeg) }
            }
        }
    }

    # ---- 5) Hitung berapa duplikat yang perlu dipindah ----
    $movedCount = 0
    foreach ($origName in $dupsByOriginal.Keys) {
        $origBlock = $blockByName[$origName]
        foreach ($d in $dupsByOriginal[$origName]) {
            if ($d.Start -lt $origBlock.Start) { $movedCount++ }
        }
    }

    # ---- 6) Bangun output + apply Comment / UnComment ----
    $outLines       = [System.Collections.Generic.List[string]]::new()
    $commentedCount = 0
    $uncomCount     = 0

    foreach ($seg in $ordered) {
        if ($seg.Type -eq 'other') {
            for ($k = $seg.Start; $k -le $seg.End; $k++) { $outLines.Add($lines[$k]) }
            continue
        }

        $b           = $seg.Block
        $doComment   = $Comment   -and $b.IsDuplicate -and (-not $b.IsCommented)
        $doUnComment = $UnComment -and $b.IsDuplicate -and $b.IsCommented

        for ($k = $b.Start; $k -le $seg.End; $k++) {
            $line = $lines[$k]

            # Header + anak-anak block (bukan blank trailing)
            if ($k -le $b.End) {
                if ($line.Trim() -eq '') {
                    $outLines.Add($line)
                    continue
                }

                if ($doComment) {
                    if ($line.Length -ge $b.Indent) {
                        $outLines.Add($line.Substring(0, $b.Indent) + '# ' + $line.Substring($b.Indent))
                    } else {
                        $outLines.Add('# ' + $line)
                    }
                    $commentedCount++
                    continue
                }

                if ($doUnComment) {
                    if ($line.Length -ge $b.Indent + 2 -and $line.Substring($b.Indent, 2) -eq '# ') {
                        $outLines.Add($line.Substring(0, $b.Indent) + $line.Substring($b.Indent + 2))
                        $uncomCount++
                    } else {
                        # baris yang tidak sesuai pola -> biarkan
                        $outLines.Add($line)
                    }
                    continue
                }
            }

            $outLines.Add($line)
        }
    }

    # ---- 7) Bandingkan & tulis ----
    $newText = ($outLines -join $eol)
    if ($newText -eq $text) {
        Write-Host "[$($file.FullName)] [SKIP] tidak ada perubahan" -ForegroundColor DarkGray
        continue
    }

    Write-Host "[$($file.FullName)]" -ForegroundColor Cyan
    if ($WhatIf) {
        Write-Host ("  [WHATIF] moved={0}, commented={1}, uncommented={2}" -f $movedCount, $commentedCount, $uncomCount) -ForegroundColor DarkYellow
    }
    else {
        if ($Backup) {
            Copy-Item -LiteralPath $file.FullName -Destination "$($file.FullName).bak" -Force
            Write-Host "  [BAK] $($file.FullName).bak" -ForegroundColor DarkCyan
        }
        $enc = [System.Text.UTF8Encoding]::new([bool]$hasBom)
        [System.IO.File]::WriteAllText($file.FullName, $newText, $enc)
        Write-Host ("  [OK] moved={0}, commented={1}, uncommented={2}" -f $movedCount, $commentedCount, $uncomCount) -ForegroundColor Green
    }
    Write-Host ''

    $totalFiles       += 1
    $totalMoved       += $movedCount
    $totalCommented   += $commentedCount
    $totalUncommented += $uncomCount
}

Write-Host ("Selesai. File: {0}, dipindah: {1}, dikomentari: {2}, di-uncomment: {3}" `
            -f $totalFiles, $totalMoved, $totalCommented, $totalUncommented) -ForegroundColor Cyan
