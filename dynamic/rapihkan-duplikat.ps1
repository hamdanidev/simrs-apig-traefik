<#
.SYNOPSIS
    Pindahkan router "duplicat_*" tepat di bawah router aslinya.
    Opsional: jadikan komentar (# ) supaya tidak aktif.

.DESCRIPTION
    Scan semua .yml / .yaml rekursif dari -Root. Untuk setiap file:
      1. Deteksi blok router Traefik (baris "<indent><nama>:" yang punya anak "rule:").
      2. Blok dengan nama berawalan "duplicat_" atau "duplicat-N_" dikenali sebagai
         duplikat, lalu dipindahkan tepat di bawah router aslinya
         (nama tanpa prefix duplicat).
      3. Dengan -Comment / -Hide, semua baris blok duplikat dijadikan komentar
         dengan menyisipkan "# " setelah indentasi dasar router.
      4. Urutan deterministik: file diurutkan by FullName.

    Rule / service / entryPoints / middlewares TIDAK diubah isinya.
    Nama router TIDAK diubah (biar aman dipakai setelah rapihkan-router.ps1).

.PARAMETER Root
    Folder akar scan (default: lokasi script).

.PARAMETER Comment
    Alias: -Hide. Jadikan blok duplikat sebagai komentar.

.PARAMETER WhatIf
    Tampilkan rencana tanpa menulis (dry-run).

.PARAMETER Backup
    Simpan <file>.bak sebelum menulis.

.EXAMPLE
    .\rapihkan-duplikat.ps1 -Root .\dynamic -WhatIf

.EXAMPLE
    .\rapihkan-duplikat.ps1 -Root .\dynamic -Comment -Backup

.EXAMPLE
    # alias -Hide juga bisa
    .\rapihkan-duplikat.ps1 -Hide
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

$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.yml', '*.yaml' | Sort-Object FullName)
if ($files.Count -eq 0) {
    Write-Warning "Tidak ada file .yml/.yaml di bawah: $Root"
    return
}

Write-Host "Scan folder : $Root"             -ForegroundColor Cyan
Write-Host "File        : $($files.Count)"    -ForegroundColor Cyan
Write-Host ("Mode        : " + $(if ($WhatIf) { 'WHATIF' } else { 'APPLY' })) -ForegroundColor Cyan
Write-Host ("Comment     : $($Comment.IsPresent)") -ForegroundColor Cyan
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

# ---------------- Proses setiap file ----------------
$totalFiles      = 0
$totalMoved      = 0
$totalCommented  = 0

foreach ($file in $files) {
    # Baca dengan deteksi BOM & EOL
    $bytes  = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and
               $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }

    $eol   = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [string[]]($text -split "`r?`n")
    $n     = $lines.Count
    if ($n -eq 0) { continue }

    # ---- 1) Deteksi blok router ----
    $blocks = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $n; $i++) {
        # header: "<indent><nama>:" (bukan komentar)
        if ($lines[$i] -notmatch '^([ \t]+)([A-Za-z0-9_\-]+):[ \t]*$') { continue }
        if ($lines[$i] -match '^[ \t]*#') { continue }

        $ind  = $Matches[1].Length
        $name = $Matches[2]

        # cari akhir blok: baris kosong, atau baris indent <= $ind
        $j = $i + 1
        while ($j -lt $n) {
            $l = $lines[$j]
            if ($l.Trim() -eq '') { break }
            if ($l -match '^([ \t]*)') {
                if ($Matches[1].Length -le $ind) { break }
            }
            $j++
        }

        # wajib punya anak "rule:"
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
        })
    }

    if ($blocks.Count -eq 0) { continue }

    # ---- 2) Map nama -> blok (kemunculan pertama) ----
    $blockByName = @{}
    foreach ($b in $blocks) {
        if (-not $blockByName.ContainsKey($b.Name)) { $blockByName[$b.Name] = $b }
    }

    # ---- 3) Kelompokkan duplikat berdasarkan nama aslinya ----
    $dupsByOriginal = @{}
    $anyDuplicate   = $false
    foreach ($b in $blocks) {
        if (-not $b.IsDuplicate) { continue }
        $anyDuplicate = $true
        $orig = Get-OriginalName -Name $b.Name
        if (-not $orig) { continue }
        if (-not $blockByName.ContainsKey($orig)) { continue }
        if (-not $dupsByOriginal.ContainsKey($orig)) {
            $dupsByOriginal[$orig] = [System.Collections.Generic.List[object]]::new()
        }
        $dupsByOriginal[$orig].Add($b)
    }

    $needsReorder = ($dupsByOriginal.Count -gt 0)
    $needsComment = ($Comment -and $anyDuplicate)
    if (-not $needsReorder -and -not $needsComment) { continue }

    # ---- 4) Bangun segmentasi baris: router-block vs other ----
    $segments = [System.Collections.Generic.List[object]]::new()
    $i = 0
    while ($i -lt $n) {
        $block = $blocks | Where-Object { $_.Start -eq $i } | Select-Object -First 1
        if ($block) {
            # include trailing blank lines
            $k = $block.End + 1
            while ($k -lt $n -and $lines[$k].Trim() -eq '') { $k++ }
            $segEnd = $k - 1
            $segments.Add([PSCustomObject]@{
                Type  = 'router'
                Block = $block
                Start = $block.Start
                End   = $segEnd
            })
            $i = $segEnd + 1
        }
        else {
            # other content - sampai block-start berikutnya
            $nextStart = $n
            foreach ($b in $blocks) {
                if ($b.Start -gt $i) { $nextStart = $b.Start; break }
            }
            $segments.Add([PSCustomObject]@{
                Type  = 'other'
                Block = $null
                Start = $i
                End   = $nextStart - 1
            })
            $i = $nextStart
        }
    }

    # index segmen per Start
    $segByBlockStart = @{}
    $origSegIdx      = @{}
    for ($x = 0; $x -lt $segments.Count; $x++) {
        $origSegIdx[$segments[$x].Start] = $x
        if ($segments[$x].Type -eq 'router') {
            $segByBlockStart[$segments[$x].Block.Start] = $segments[$x]
        }
    }

    # ---- 5) Reorder: setiap router non-duplikat diikuti duplikatnya ----
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($seg in $segments) {
        if ($seg.Type -eq 'other') {
            $ordered.Add($seg); continue
        }
        $b = $seg.Block
        if ($b.IsDuplicate) {
            $orig = Get-OriginalName -Name $b.Name
            if ($orig -and $blockByName.ContainsKey($orig)) {
                # akan ditambahkan setelah original -> skip di sini
                continue
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

    # ---- 6) Bangun output ----
    $outLines       = [System.Collections.Generic.List[string]]::new()
    $movedCount     = 0
    $commentedCount = 0

    for ($x = 0; $x -lt $ordered.Count; $x++) {
        $seg = $ordered[$x]

        if ($seg.Type -eq 'other') {
            for ($k = $seg.Start; $k -le $seg.End; $k++) {
                $outLines.Add($lines[$k])
            }
            continue
        }

        $b         = $seg.Block
        $doComment = $Comment -and $b.IsDuplicate
        $base      = $b.Indent

        for ($k = $b.Start; $k -le $seg.End; $k++) {
            $line = $lines[$k]
            if ($doComment -and $k -le $b.End) {
                if ($line.Trim() -eq '') {
                    $outLines.Add('')
                }
                elseif ($line.Length -ge $base) {
                    $outLines.Add($line.Substring(0, $base) + '# ' + $line.Substring($base))
                }
                else {
                    $outLines.Add('# ' + $line)
                }
                $commentedCount++
            }
            else {
                $outLines.Add($line)
            }
        }

        if ($b.IsDuplicate -and $origSegIdx[$seg.Start] -ne $x) {
            $movedCount++
        }
    }

    # ---- 7) Tulis ----
    Write-Host "[$($file.FullName)]" -ForegroundColor Cyan

    if ($WhatIf) {
        Write-Host ("  [WHATIF] akan menulis {0}: {1} duplikat dipindah, {2} baris dikomentari" `
                    -f $file.Name, $movedCount, $commentedCount) -ForegroundColor DarkYellow
    }
    else {
        if ($Backup) {
            Copy-Item -LiteralPath $file.FullName -Destination "$($file.FullName).bak" -Force
            Write-Host "  [BAK] $($file.FullName).bak" -ForegroundColor DarkCyan
        }
        $newText = ($outLines -join $eol)
        $enc     = [System.Text.UTF8Encoding]::new([bool]$hasBom)
        [System.IO.File]::WriteAllText($file.FullName, $newText, $enc)
        Write-Host ("  [OK] {0}: {1} duplikat dipindah, {2} baris dikomentari" `
                    -f $file.Name, $movedCount, $commentedCount) -ForegroundColor Green
    }
    Write-Host ''

    $totalFiles++
    $totalMoved     += $movedCount
    $totalCommented += $commentedCount
}

Write-Host ("Selesai. File: {0}, duplikat dipindah: {1}, baris dikomentari: {2}" `
            -f $totalFiles, $totalMoved, $totalCommented) -ForegroundColor Cyan
