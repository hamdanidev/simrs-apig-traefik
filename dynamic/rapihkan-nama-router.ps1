<#
.SYNOPSIS
    Rapihkan nama router Traefik + tangani tabrakan nama secara otomatis.

.DESCRIPTION
    Scan semua .yml rekursif dari $Root. Untuk setiap router:
      1. Hitung nama dasar dari <version>_<segmen-path>..._<METHOD>.
      2. Kelompokkan berdasarkan nama dasar.
      3. Untuk grup yang berisi >1 item (baik rule identik maupun rule berbeda
         yang menghasilkan nama sama), beri prefix:
            item ke-1 -> nama bersih
            item ke-2 -> "duplicat_<ver>_<nama>"
            item ke-3 -> "duplicat-2_<ver>_<nama>"
            item ke-4 -> "duplicat-3_<ver>_<nama>"
         Urutan ditentukan oleh (nama file, nomor baris) -> deterministik.

    Method TIDAK diubah besar/kecilnya.
    Rule, service, entryPoints, middlewares tidak disentuh.

    CATATAN PERBAIKAN:
      - Slice array segmen dipaksa tetap array dengan @(...), supaya path
        dengan 1 segmen setelah versi (mis. /v1.0/get-jadwal/) tidak berubah
        jadi string dan menghasilkan nama salah seperti "v1_g_GET".
      - Perbandingan nama lama vs baru memakai -ieq (abaikan huruf besar/kecil),
        sehingga "V1_xxx" tidak dianggap perlu diganti menjadi "v1_xxx".
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Root = $PSScriptRoot,

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
Write-Host ("Mode        : " + $(if ($WhatIf) { 'WHATIF' } else { 'APPLY' })) -ForegroundColor Cyan
Write-Host ''

# ---------- Helper: nama dasar ----------
# Membentuk nama router dari path dan method.
# Contoh: /v1.0/get-jadwal-pegawai-lengkap/ + GET -> v1_get-jadwal-pegawai-lengkap_GET
function Convert-ToRouterName {
    param([string]$Path, [string]$Method)

    # Pecah path jadi segmen, buang segmen kosong. @() menjamin hasilnya array.
    $segments = @($Path -split '/' | Where-Object { $_ -ne '' })
    if ($segments.Count -eq 0) { return $null }

    # Jika segmen pertama berupa versi (mis. v1.0), simpan sebagai "v1" lalu buang dari daftar
    $versionPart = 'v1'
    if ($segments[0] -match '^v(\d+)\.\d+$') {
        $versionPart = "v$($Matches[1])"

        # PERBAIKAN: assign DI DALAM blok if/else (bukan assign hasil "if"),
        # karena hasil "if" otomatis di-unroll: array 1 elemen berubah jadi string.
        if ($segments.Count -gt 1) {
            $segments = @($segments[1..($segments.Count - 1)])
        }
        else {
            $segments = @()
        }
    }

    # Buang segmen parameter (diawali ':') dan segmen terakhir yang berupa angka saja
    $kept = @()
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $seg = $segments[$i]
        if ($seg -match '^:') { continue }
        if (($i -eq $segments.Count - 1) -and ($seg -match '^\d+$')) { continue }
        $kept += $seg
    }
    if ($kept.Count -eq 0) { return $null }

    return "$versionPart`_$($kept -join '_')_$Method"
}

# ---------- Baca semua file ----------
# Menyimpan isi tiap file (baris, jenis line-ending, BOM) dan mendaftar semua router yang ditemukan.
$fileContents = @{}
$items        = [System.Collections.Generic.List[object]]::new()

foreach ($file in $files) {
    $bytes  = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text   = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }

    $eol   = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [string[]]($text -split "`r?`n")

    $fileContents[$file.FullName] = @{ Lines = $lines; Eol = $eol; HasBom = $hasBom }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        # Cari baris nama router, contoh: "    nama_router:"
        if ($lines[$i] -notmatch '^(\s+)([A-Za-z0-9_\-]+):\s*$') { continue }
        $indent  = $Matches[1]
        $oldName = $Matches[2]

        # Cari baris tidak kosong berikutnya (harus berisi rule)
        $ruleIdx = -1
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            if ($lines[$j].Trim() -ne '') { $ruleIdx = $j; break }
        }
        if ($ruleIdx -lt 0) { continue }
        if ($lines[$ruleIdx] -notmatch 'rule:\s*"(.*)"\s*$') { continue }
        $ruleContent = $Matches[1]

        # Ambil path dan method dari rule
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
            BaseName    = $null
            NewName     = $null
        })
    }
}

# ---------- Pass 1: hitung base name ----------
foreach ($item in $items) {
    $item.BaseName = Convert-ToRouterName -Path $item.Path -Method $item.Method
}

# ---------- Pass 2: group by base name & beri prefix duplikat ----------
$groups = $items | Where-Object { $_.BaseName } | Group-Object -Property BaseName

foreach ($grp in $groups) {
    # Urutan deterministik: file lalu line
    $ordered = @($grp.Group | Sort-Object FilePath, LineIndex)
    for ($k = 0; $k -lt $ordered.Count; $k++) {
        $it = $ordered[$k]
        if ($k -eq 0) {
            # Item pertama memakai nama bersih
            $it.NewName = $it.BaseName
        }
        else {
            # Pisahkan version dari base name
            $ver = 'v1'; $rest = $it.BaseName
            if ($it.BaseName -match '^(v\d+)_(.+)$') { $ver = $Matches[1]; $rest = $Matches[2] }
            elseif ($it.Path -match '^/v(\d+)\.\d+') { $ver = "v$($Matches[1])" }

            if ($k -eq 1) {
                $it.NewName = "duplicat_${ver}_$rest"
            }
            else {
                $it.NewName = "duplicat-$k`_${ver}_$rest"
            }
        }
    }
}

# ---------- Tampilkan & tulis ----------
$byFile     = @{}
$totalFiles = 0
$totalRen   = 0

foreach ($item in $items) {
    if (-not $item.NewName) { continue }

    # PERBAIKAN: -ieq = abaikan beda huruf besar/kecil (V1_xxx dianggap sama dengan v1_xxx)
    if ($item.NewName -ieq $item.OldName) { continue }

    if (-not $byFile.ContainsKey($item.FilePath)) {
        $byFile[$item.FilePath] = [System.Collections.Generic.List[object]]::new()
    }
    $byFile[$item.FilePath].Add($item)
}

foreach ($fp in $byFile.Keys) {
    $fc   = $fileContents[$fp]
    $work = [string[]]::new($fc.Lines.Count)
    [Array]::Copy($fc.Lines, $work, $fc.Lines.Count)

    Write-Host "[$fp]" -ForegroundColor Cyan
    foreach ($chg in $byFile[$fp]) {
        Write-Host ("  {0,-50} -> {1}" -f $chg.OldName, $chg.NewName) -ForegroundColor Yellow
        $work[$chg.LineIndex] = "$($chg.Indent)$($chg.NewName):"
    }

    $fileName = [System.IO.Path]::GetFileName($fp)
    $count    = $byFile[$fp].Count

    if ($WhatIf) {
        Write-Host "  [WHATIF] tidak menulis $fileName ($count)" -ForegroundColor DarkYellow
    }
    else {
        if ($Backup) {
            Copy-Item -LiteralPath $fp -Destination "$fp.bak" -Force
            Write-Host "  [BAK] $fp.bak" -ForegroundColor DarkCyan
        }
        $newText = ($work -join $fc.Eol)
        $enc     = [System.Text.UTF8Encoding]::new([bool]$fc.HasBom)
        [System.IO.File]::WriteAllText($fp, $newText, $enc)
        Write-Host "  [OK] $fileName ($count)" -ForegroundColor Green
    }
    Write-Host ''
    $totalFiles++
    $totalRen += $count
}

Write-Host ("Selesai. File: {0}, router: {1}" -f $totalFiles, $totalRen) -ForegroundColor Cyan
