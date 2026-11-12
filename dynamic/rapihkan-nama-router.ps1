<#
.SYNOPSIS
    Rapihkan nama router Traefik + tangani tabrakan nama secara otomatis.

.DESCRIPTION
    Scan semua .yml rekursif dari $Root. Untuk setiap router di dalam "routers:":
      1. Ambil path dari rule: PathPrefix(`...`) ATAU Path(`...`) (path pertama).
      2. Ambil method dari Method(`...`) (method pertama selain OPTIONS).
         Jika rule tidak punya Method, dipakai label -NoMethodLabel (default ANY).
      3. Nama dasar = <version>_<segmen-path>..._<METHOD>
            /v1.0/pasien-casemix/stats_claim + GET -> v1_pasien-casemix_stats_claim_GET
      4. Kelompokkan berdasarkan nama dasar. Untuk grup >1 item:
            item ke-1 -> nama bersih
            item ke-2 -> "duplicat_<ver>_<nama>"
            item ke-3 -> "duplicat-2_<ver>_<nama>"
            item ke-4 -> "duplicat-3_<ver>_<nama>"
         Urutan: (path file, nomor baris) -> deterministik.

    PERBAIKAN dibanding versi sebelumnya (penyebab router "terlewat"):
      - Rule dengan Path(`...`) (bukan hanya PathPrefix) sekarang dikenali.
      - Nama router yang mengandung titik / ber-kutip / ada komentar di ujung
        (mis. stok-gudang.konsinyasi_1:) sekarang dikenali.
      - Baris "rule:" tidak harus tepat di bawah nama router; boleh di mana saja
        di dalam blok router, boleh ber-kutip tunggal/ganda, boleh multi-baris (>- / |).
      - Hanya blok di dalam "routers:" yang diproses (tidak salah baca section lain).
      - Rule tanpa Method tidak dilewati lagi (dapat label -NoMethodLabel).
      - Router yang tetap tidak bisa diproses DILAPORKAN di akhir beserta alasannya.
      - Backup .bak tidak menimpa backup lama (backup tertua dipertahankan).

    Method TIDAK diubah besar/kecilnya.
    Rule, service, entryPoints, middlewares tidak disentuh (hanya baris nama router).

.EXAMPLE
    .\Rename-Routers.ps1 -WhatIf
    .\Rename-Routers.ps1 -Backup
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Root = $PSScriptRoot,

    # Versi yang dipakai jika path tidak diawali v1.0 / v2.0 dst.
    [string]$DefaultVersion = 'v1',

    # Pengganti METHOD jika rule tidak punya Method(`...`)
    [string]$NoMethodLabel = 'ANY',

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

# =====================================================================
# Helper
# =====================================================================

# Path relatif terhadap $Root (untuk tampilan).
function Get-RelativePath {
    param([string]$Path)
    if ($Path.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($Root.Length).TrimStart('\', '/')
    }
    return $Path
}

# Jumlah spasi di awal baris.
function Get-IndentLength {
    param([string]$Line)
    return ($Line.Length - $Line.TrimStart().Length)
}

# Ambil path pertama dari rule: PathPrefix(`...`) atau Path(`...`)
function Get-RulePath {
    param([string]$RuleText)
    $m = [regex]::Match($RuleText, '\b(?:PathPrefix|Path)\(\s*`([^`]+)`')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# Ambil method pertama selain OPTIONS (jika hanya OPTIONS, pakai OPTIONS). $null jika tidak ada.
function Get-RuleMethod {
    param([string]$RuleText)
    $methods = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($RuleText, '\bMethod\(([^)]*)\)')) {
        foreach ($v in [regex]::Matches($m.Groups[1].Value, '`([A-Za-z]+)`')) {
            $methods.Add($v.Groups[1].Value)
        }
    }
    if ($methods.Count -eq 0) { return $null }
    foreach ($x in $methods) { if ($x -ine 'OPTIONS') { return $x } }
    return $methods[0]
}

# Membentuk nama router dari path dan method.
# Contoh: /v1.0/get-jadwal-pegawai-lengkap/ + GET -> v1_get-jadwal-pegawai-lengkap_GET
function Convert-ToRouterName {
    param([string]$Path, [string]$Method)

    # @() menjamin hasilnya array walau hanya 1 segmen
    $segments = @($Path -split '/' | Where-Object { $_ -ne '' })
    if ($segments.Count -eq 0) { return $null }

    $versionPart = $DefaultVersion
    if ($segments[0] -match '^v(\d+)\.\d+$') {
        $versionPart = "v$($Matches[1])"
        # assign di dalam blok if/else agar array 1 elemen tidak berubah jadi string
        if ($segments.Count -gt 1) { $segments = @($segments[1..($segments.Count - 1)]) }
        else { $segments = @() }
    }

    # Buang segmen parameter (diawali ':') dan segmen terakhir yang hanya angka
    $kept = @()
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $seg = $segments[$i]
        if ($seg -match '^:') { continue }
        if (($i -eq $segments.Count - 1) -and ($seg -match '^\d+$')) { continue }
        $kept += $seg
    }
    if ($kept.Count -eq 0) { return $null }

    $name = "${versionPart}_$($kept -join '_')_$Method"
    # Karakter di luar huruf/angka/_/-/. diganti '-'
    return ($name -replace '[^A-Za-z0-9._\-]', '-')
}

# Pola baris nama router: indent, kutip (opsional), nama, komentar (opsional).
# Mendukung titik di nama (stok-gudang.konsinyasi_1), nama ber-kutip, dan komentar di ujung.
$NamePattern = '^(\s*)(["'']?)([^\s#:''"][^:#''"]*?)\2\s*:\s*(#.*)?$'

# =====================================================================
# Baca semua file & daftar router
# =====================================================================
$fileContents = @{}
$items        = [System.Collections.Generic.List[object]]::new()
$skipped      = [System.Collections.Generic.List[object]]::new()

foreach ($file in $files) {
    $bytes  = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text   = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }

    $eol   = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [string[]]($text -split "`r?`n")

    $fileContents[$file.FullName] = @{ Lines = $lines; Eol = $eol; HasBom = $hasBom }

    $inRouters     = $false
    $routersIndent = -1
    $childIndent   = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $t    = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#') -or $t -eq '---') { continue }
        $ind = Get-IndentLength $line

        # Keluar dari section routers jika indentasi kembali ke level routers: atau lebih kiri
        if ($inRouters) {
            if ($ind -le $routersIndent) { $inRouters = $false }
            elseif ($childIndent -lt 0)  { $childIndent = $ind }
        }

        if (-not $inRouters) {
            if ($line -match '^\s*routers:\s*(?:#.*)?$') {
                $inRouters     = $true
                $routersIndent = $ind
                $childIndent   = -1
            }
            continue
        }

        # Hanya baris pada level nama router yang diproses
        if ($ind -ne $childIndent) { continue }

        if ($line -notmatch $NamePattern) {
            $skipped.Add([PSCustomObject]@{ File = $file.FullName; Line = $i + 1; Name = $t; Reason = 'baris nama router tidak dikenali' })
            continue
        }
        $indent  = $Matches[1]
        $oldName = $Matches[3].Trim()
        $comment = $Matches[4]

        # Cari akhir blok router ini
        $end = $i + 1
        while ($end -lt $lines.Count) {
            $l  = $lines[$end]
            $lt = $l.Trim()
            if ($lt -ne '' -and -not $lt.StartsWith('#')) {
                if ((Get-IndentLength $l) -le $childIndent) { break }
            }
            $end++
        }

        # Cari "rule:" di dalam blok (boleh multi-baris)
        $ruleText = $null
        for ($j = $i + 1; $j -lt $end; $j++) {
            if ($lines[$j] -match '^(\s*)rule:\s*(.*)$') {
                $rIndent = $Matches[1].Length
                $sb = [System.Text.StringBuilder]::new()
                [void]$sb.Append($Matches[2])
                for ($m = $j + 1; $m -lt $end; $m++) {
                    $ml = $lines[$m]
                    $mt = $ml.Trim()
                    if ($mt -eq '' -or $mt.StartsWith('#')) { continue }
                    if ((Get-IndentLength $ml) -le $rIndent) { break }
                    [void]$sb.Append(' ').Append($mt)
                }
                $ruleText = $sb.ToString()
                break
            }
        }

        if ($null -eq $ruleText -or $ruleText.Trim() -eq '') {
            $skipped.Add([PSCustomObject]@{ File = $file.FullName; Line = $i + 1; Name = $oldName; Reason = "tidak ada 'rule:'" })
            continue
        }

        $path = Get-RulePath -RuleText $ruleText
        if (-not $path) {
            $skipped.Add([PSCustomObject]@{ File = $file.FullName; Line = $i + 1; Name = $oldName; Reason = 'rule tanpa Path/PathPrefix' })
            continue
        }

        $method = Get-RuleMethod -RuleText $ruleText
        if (-not $method) { $method = $NoMethodLabel }

        $items.Add([PSCustomObject]@{
            FilePath  = $file.FullName
            FileName  = $file.Name
            LineIndex = $i
            Indent    = $indent
            OldName   = $oldName
            Comment   = $comment
            Path      = $path
            Method    = $method
            BaseName  = $null
            NewName   = $null
        })
    }
}

# =====================================================================
# Pass 1: hitung base name
# =====================================================================
foreach ($item in $items) {
    $item.BaseName = Convert-ToRouterName -Path $item.Path -Method $item.Method
    if (-not $item.BaseName) {
        $skipped.Add([PSCustomObject]@{ File = $item.FilePath; Line = $item.LineIndex + 1; Name = $item.OldName; Reason = "path '$($item.Path)' tidak menghasilkan nama" })
    }
}

# =====================================================================
# Pass 2: group by base name & beri prefix duplikat
# =====================================================================
$groups = $items | Where-Object { $_.BaseName } | Group-Object -Property BaseName

foreach ($grp in $groups) {
    $ordered = @($grp.Group | Sort-Object FilePath, LineIndex)
    for ($k = 0; $k -lt $ordered.Count; $k++) {
        $it = $ordered[$k]
        if ($k -eq 0) {
            $it.NewName = $it.BaseName
        }
        else {
            $ver = $DefaultVersion; $rest = $it.BaseName
            if ($it.BaseName -match '^(v\d+)_(.+)$') { $ver = $Matches[1]; $rest = $Matches[2] }

            if ($k -eq 1) { $it.NewName = "duplicat_${ver}_$rest" }
            else          { $it.NewName = "duplicat-${k}_${ver}_$rest" }
        }
    }
}

# Peringatan: nama baru bentrok dengan router yang tidak ikut diproses
$untouched = @{}
foreach ($s in $skipped) { $untouched[$s.Name.ToLowerInvariant()] = $s }
foreach ($it in $items) {
    if ($it.NewName -and $untouched.ContainsKey($it.NewName.ToLowerInvariant())) {
        Write-Warning "Nama baru '$($it.NewName)' sama dengan router lain yang tidak diproses (lihat laporan)."
    }
}

# =====================================================================
# Tampilkan & tulis
# =====================================================================
$byFile     = @{}
$totalFiles = 0
$totalRen   = 0
$totalSame  = 0

foreach ($item in $items) {
    if (-not $item.NewName) { continue }

    # -ieq: V1_xxx dianggap sama dengan v1_xxx
    if ($item.NewName -ieq $item.OldName) { $totalSame++; continue }

    if (-not $byFile.ContainsKey($item.FilePath)) {
        $byFile[$item.FilePath] = [System.Collections.Generic.List[object]]::new()
    }
    $byFile[$item.FilePath].Add($item)
}

foreach ($fp in ($byFile.Keys | Sort-Object)) {
    $fc   = $fileContents[$fp]
    $work = [string[]]::new($fc.Lines.Count)
    [Array]::Copy($fc.Lines, $work, $fc.Lines.Count)

    Write-Host "[$(Get-RelativePath $fp)]" -ForegroundColor Cyan
    foreach ($chg in $byFile[$fp]) {
        Write-Host ("  {0,-50} -> {1}" -f $chg.OldName, $chg.NewName) -ForegroundColor Yellow
        $suffix = if ($chg.Comment) { "  $($chg.Comment)" } else { '' }
        $work[$chg.LineIndex] = "$($chg.Indent)$($chg.NewName):$suffix"
    }

    $fileName = [System.IO.Path]::GetFileName($fp)
    $count    = $byFile[$fp].Count

    if ($WhatIf) {
        Write-Host "  [WHATIF] tidak menulis $fileName ($count)" -ForegroundColor DarkYellow
    }
    else {
        if ($Backup -and -not (Test-Path -LiteralPath "$fp.bak")) {
            Copy-Item -LiteralPath $fp -Destination "$fp.bak"
            Write-Host "  [BAK] $(Get-RelativePath "$fp.bak")" -ForegroundColor DarkCyan
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

# =====================================================================
# Laporan
# =====================================================================
Write-Host '==================== LAPORAN ====================' -ForegroundColor Cyan
Write-Host ("Router terbaca            : {0}" -f $items.Count)
Write-Host ("Sudah sesuai (dilewati)   : {0}" -f $totalSame)
Write-Host ("Diganti namanya           : {0} di {1} file" -f $totalRen, $totalFiles)
Write-Host ("Tidak bisa diproses       : {0}" -f $skipped.Count)
Write-Host ''

if ($skipped.Count -gt 0) {
    Write-Host '--- ROUTER YANG TIDAK DIPROSES (cek manual) ---' -ForegroundColor Yellow
    foreach ($s in ($skipped | Sort-Object File, Line)) {
        Write-Host ("   - {0}:{1}  {2}" -f (Get-RelativePath $s.File), $s.Line, $s.Name) -ForegroundColor Yellow
        Write-Host ("       {0}" -f $s.Reason) -ForegroundColor DarkYellow
    }
    Write-Host ''
}

Write-Host ("Selesai. File: {0}, router: {1}" -f $totalFiles, $totalRen) -ForegroundColor Cyan
