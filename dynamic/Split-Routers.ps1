<#
.SYNOPSIS
    Pecah file router Traefik (.yml) menjadi beberapa file, satu file per grup path.

.DESCRIPTION
    Scan semua .yml rekursif dari $Root. Untuk setiap file:
      1. Baca semua router (http > routers), termasuk router yang di-comment (#),
         dan service (http > services).
      2. Ambil path dari PathPrefix(`...`) / Path(`...`) lalu tentukan "kunci grup":
            /v1.0/berkas-digital/create                    -> berkas-digital
            /v1.0/berkas-digital/get-by-id/                -> berkas-digital
            /v1.0/erm/meso/obat-meso/create                -> erm
            /v1.0/get-jadwal-pegawai-lengkap-hfis/         -> get-jadwal-pegawai-lengkap-hfis
         Aturannya:
            - buang segmen versi (v1.0)
            - ambil segmen PERTAMA setelah versi sebagai nama file
            - ingin lebih rinci? pakai -GroupDepth 2 -> erm_meso, erm_rekonsiliasi-obat, dst.
      3. Tulis satu file per grup di folder yang sama: <kunci-grup>.yml
         Isi file: router grup itu (aktif + yang di-comment) + definisi service yang dipakai.
      4. Router dari file berbeda di folder yang sama yang kuncinya sama DIGABUNG ke satu file.
         Router yang namanya & isinya identik tidak ditulis dobel (aman dijalankan ulang).

    Isi router TIDAK diubah sama sekali (disalin apa adanya, termasuk tanda #).

    Tidak ada data yang hilang:
      - Section lain selain routers/services (mis. middlewares), router yang tidak punya
        PathPrefix/Path, dan service yang tidak dipakai router di file itu akan TETAP
        ada di file aslinya (file asli ditulis ulang berisi sisanya, tidak dihapus).
      - File asli baru dihapus jika semua isinya sudah pindah (dan memakai -DeleteOriginal).

    Di akhir proses ditampilkan laporan: file/folder yang dihapus, dan file yang tidak
    dihapus beserta alasannya.

.EXAMPLE
    .\Split-Routers.ps1 -WhatIf
    .\Split-Routers.ps1 -Backup -DeleteOriginal
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Root = $PSScriptRoot,

    # Jumlah segmen path (setelah versi) yang dipakai untuk nama file.
    # Default 1 -> hanya segmen pertama (berkas-digital). Pakai 2 untuk erm_meso, dst.
    [int]$GroupDepth = 1,

    # Kata aksi di ujung path yang tidak ikut dipakai untuk nama file
    [string[]]$ActionWords = @('create', 'update', 'delete', 'get-list', 'get-by-id'),

    [switch]$WhatIf,          # hanya tampilkan rencana & laporan, tidak menulis/menghapus apa pun
    [switch]$Backup,          # buat <file>.bak (sekali, tidak menimpa .bak lama) sebelum diubah/dihapus
    [switch]$DeleteOriginal   # hapus file asli setelah semua isinya berhasil dipindah
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
# Helper: baris YAML
# =====================================================================

# Pola baris "nama:" (kunci YAML). Mendukung nama ber-kutip, spasi sebelum ':',
# dan komentar di akhir baris (mis. "router_x:   # catatan").
$KeyPattern = '^\s*["'']?([^\s#:''"\-][^:#''"]*?)["'']?\s*:\s*(?:#.*)?$'

# Catatan baris yang tidak dikenali tapi masih bisa diselamatkan (dilaporkan ke layar)
$script:ParseWarnings = [System.Collections.Generic.List[string]]::new()
# Detail kegagalan baca terakhir (nomor baris + isi baris)
$script:ChildError = ''
# Jumlah baris komentar biasa (bukan router) yang tidak ikut dipindahkan
$script:DroppedComments = 0

# Memendekkan isi baris untuk pesan error.
function Get-Snippet {
    param([string]$Line)
    $t = $Line.Trim()
    if ($t.Length -gt 90) { $t = $t.Substring(0, 90) + '...' }
    return $t
}

# Menghitung jumlah spasi di awal sebuah baris (indentasi).
function Get-IndentLength {
    param([string]$Line)
    return ($Line.Length - $Line.TrimStart().Length)
}

# True jika baris adalah komentar (diawali #).
function Test-CommentLine {
    param([string]$Line)
    return $Line.TrimStart().StartsWith('#')
}

# True jika baris kosong, komentar, atau penanda dokumen (---).
function Test-SkipLine {
    param([string]$Line)
    $t = $Line.Trim()
    return ($t -eq '' -or $t.StartsWith('#') -or $t -eq '---')
}

# Membuka komentar satu baris: buang '#' pertama dan satu spasi setelahnya.
# Indentasi sebelum '#' dipertahankan.
function Get-UncommentedLine {
    param([string]$Line)
    return ($Line -replace '^(\s*)#\s?', '$1')
}

# Mencari akhir sebuah blok YAML: baris berikutnya yang indentasinya <= baris awal.
# Ekor blok yang dibuang: baris kosong dan komentar yang sejajar/lebih kiri dari awal blok
# (komentar seperti itu milik blok berikutnya). Hasil: indeks akhir (eksklusif).
function Get-BlockEnd {
    param([string[]]$Lines, [int]$Start, [int]$Limit)

    $indent = Get-IndentLength $Lines[$Start]
    $end = $Start + 1
    while ($end -lt $Limit) {
        if (-not (Test-SkipLine $Lines[$end]) -and (Get-IndentLength $Lines[$end]) -le $indent) { break }
        $end++
    }
    while ($end -gt ($Start + 1)) {
        $l = $Lines[$end - 1]
        if ($l.Trim() -eq '' -or ((Test-CommentLine $l) -and (Get-IndentLength $l) -le $indent)) { $end-- }
        else { break }
    }
    return $end
}

# True jika baris ke-$Index adalah awal sebuah blok yang di-comment, contoh:
#     # nama_router:
#     #   rule: "..."
# (baris pertama = nama, baris berikutnya = komentar dengan indentasi lebih dalam)
function Test-CommentedBlockStart {
    param([string[]]$Lines, [int]$Index, [int]$End)

    if (-not (Test-CommentLine $Lines[$Index])) { return $false }
    $u = Get-UncommentedLine $Lines[$Index]
    if ($u -notmatch $KeyPattern) { return $false }

    $n = $Index + 1
    if ($n -ge $End) { return $false }
    if ($Lines[$n].Trim() -eq '') { return $false }
    if (-not (Test-CommentLine $Lines[$n])) { return $false }
    $un = Get-UncommentedLine $Lines[$n]
    return ((Get-IndentLength $un) -gt (Get-IndentLength $u))
}

# Memecah isi sebuah section (mis. routers) menjadi daftar blok anak.
# Tiap blok: Name, Lines (asli), ParseLines (versi tanpa #), Commented.
# Mengembalikan $null jika strukturnya tidak dikenali.
function Get-ChildBlocks {
    param([string[]]$Lines, [int]$Start, [int]$End, [bool]$AllowCommented = $false)

    $blocks   = [System.Collections.Generic.List[object]]::new()
    $j = $Start
    while ($j -lt $End) {
        $line = $Lines[$j]

        # --- Baris komentar: bisa jadi router yang di-comment ---
        if (Test-CommentLine $line) {
            if ($AllowCommented -and (Test-CommentedBlockStart -Lines $Lines -Index $j -End $End)) {
                $startIndent = Get-IndentLength (Get-UncommentedLine $line)
                $k = $j + 1
                while ($k -lt $End) {
                    $kl = $Lines[$k]
                    if ($kl.Trim() -eq '' -or -not (Test-CommentLine $kl)) { break }
                    if ((Get-IndentLength (Get-UncommentedLine $kl)) -le $startIndent) { break }
                    $k++
                }
                $raw  = [string[]]@($Lines[$j..($k - 1)])
                $unc  = [string[]]@($raw | ForEach-Object { Get-UncommentedLine $_ })
                $name = (Get-UncommentedLine $line).Trim().TrimEnd(':')
                if ((Get-UncommentedLine $line) -match $KeyPattern) { $name = $Matches[1].Trim() }
                $blocks.Add([PSCustomObject]@{
                    Name = $name; Lines = $raw; ParseLines = $unc; Commented = $true
                })
                $j = $k
                continue
            }
            if ($AllowCommented) { $script:DroppedComments++ }
            $j++
            continue
        }
        if (Test-SkipLine $line) { $j++; continue }

        # --- Baris yang bukan "nama:" ---
        if ($line -notmatch $KeyPattern) {
            $script:ChildError = "baris $($j + 1): $(Get-Snippet $line)"
            if ($blocks.Count -eq 0) { return $null }

            # Selamatkan: baris ini (beserta anak-anaknya) ikut blok sebelumnya agar tidak hilang
            $strayEnd = Get-BlockEnd -Lines $Lines -Start $j -Limit $End
            $last = $blocks[$blocks.Count - 1]
            $extra = [string[]]@($Lines[$j..($strayEnd - 1)])
            $last.Lines      = [string[]]@($last.Lines + $extra)
            $last.ParseLines = [string[]]@($last.ParseLines + $extra)
            $script:ParseWarnings.Add("baris $($j + 1) tidak dikenali, ikut router '$($last.Name)': $(Get-Snippet $line)")
            $j = $strayEnd
            continue
        }

        # --- Blok biasa ---
        $name     = $Matches[1].Trim()
        $blockEnd = Get-BlockEnd -Lines $Lines -Start $j -Limit $End
        $raw      = [string[]]@($Lines[$j..($blockEnd - 1)])
        $blocks.Add([PSCustomObject]@{
            Name = $name; Lines = $raw; ParseLines = $raw; Commented = $false
        })
        $j = $blockEnd
    }
    # Tanda koma mencegah list "dibongkar" saat dikembalikan
    return , $blocks
}

# Membaca satu file Traefik dynamic config.
# Hasil: hashtable berisi Ok, Reason, SectionIndent, Routers, Services, Extras.
function Read-RouterFile {
    param([string[]]$Lines)

    $script:ParseWarnings = [System.Collections.Generic.List[string]]::new()
    $script:ChildError    = ''
    $script:DroppedComments = 0

    $result = @{
        Warnings      = $script:ParseWarnings
        DroppedComments = 0
        Ok            = $false
        Reason        = ''
        SectionIndent = '  '
        Routers       = [System.Collections.Generic.List[object]]::new()
        Services      = [ordered]@{}
        Extras        = [System.Collections.Generic.List[object]]::new()   # section lain (mis. middlewares)
    }

    # 1. Cari 'http:' dan pastikan tidak ada key root lain (supaya tidak ada data hilang)
    $httpIdx = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if (Test-SkipLine $Lines[$i]) { continue }
        if ($Lines[$i] -match '^http:\s*$') { $httpIdx = $i; continue }
        if ((Get-IndentLength $Lines[$i]) -eq 0) {
            $result.Reason = "ada key root selain 'http:' ($($Lines[$i].Trim()))"
            return $result
        }
    }
    if ($httpIdx -lt 0) {
        $result.Reason = "tidak ada 'http:'"
        return $result
    }
    $httpEnd = Get-BlockEnd -Lines $Lines -Start $httpIdx -Limit $Lines.Count

    # 2. Baca section di dalam http:
    $i      = $httpIdx + 1
    $secLen = -1
    while ($i -lt $httpEnd) {
        if (Test-SkipLine $Lines[$i]) { $i++; continue }

        $len = Get-IndentLength $Lines[$i]
        if ($secLen -lt 0) { $secLen = $len; $result.SectionIndent = ' ' * $len }
        if ($len -ne $secLen -or $Lines[$i] -notmatch $KeyPattern) {
            $result.Reason = "struktur YAML tidak dikenali di baris $($i + 1): $(Get-Snippet $Lines[$i])"
            return $result
        }

        $sectionName = $Matches[1]
        $sectionEnd  = Get-BlockEnd -Lines $Lines -Start $i -Limit $httpEnd

        if ($sectionName -eq 'routers') {
            $blocks = Get-ChildBlocks -Lines $Lines -Start ($i + 1) -End $sectionEnd -AllowCommented $true
            if ($null -eq $blocks) {
                $result.Reason = "isi 'routers' tidak bisa dibaca ($script:ChildError)"
                return $result
            }
            foreach ($b in $blocks) {
                # Router wajib punya 'rule:'. Blok komentar tanpa rule = komentar biasa, diabaikan.
                # Teks seluruh blok dipakai untuk mencari PathPrefix (rule boleh ber-kutip apa pun
                # atau ditulis beberapa baris).
                $blockText = $b.ParseLines -join "`n"
                $hasRule   = $blockText -match '(?m)^\s*rule:'
                if ($b.Commented -and -not $hasRule) { continue }
                $rule = $null
                if ($hasRule) { $rule = $blockText }

                $service = $null
                foreach ($l in $b.ParseLines) {
                    if ($l -match '^\s*service:\s*["'']?([^"''\s#]+)["'']?\s*(?:#.*)?$') { $service = $Matches[1]; break }
                }

                $result.Routers.Add([PSCustomObject]@{
                    Name      = $b.Name
                    Lines     = $b.Lines
                    Rule      = $rule
                    Service   = $service
                    Commented = $b.Commented
                })
            }
        }
        elseif ($sectionName -eq 'services') {
            $blocks = Get-ChildBlocks -Lines $Lines -Start ($i + 1) -End $sectionEnd
            if ($null -eq $blocks) {
                $result.Reason = "isi 'services' tidak bisa dibaca ($script:ChildError)"
                return $result
            }
            foreach ($b in $blocks) { $result.Services[$b.Name] = $b.Lines }
        }
        else {
            # Section lain (middlewares, dst) disimpan utuh agar tidak hilang
            $result.Extras.Add([string[]]@($Lines[$i..($sectionEnd - 1)]))
        }

        $i = $sectionEnd
    }

    $result.DroppedComments = $script:DroppedComments
    $result.Ok = $true
    return $result
}

# Menentukan kunci grup (nama file tanpa .yml) dari path sebuah router.
function Get-GroupKey {
    param([string]$Path, [int]$Depth, [string[]]$ActionWords)

    $segments = @($Path -split '/' | Where-Object { $_ -ne '' })

    # Buang segmen versi (v1.0). Assign di dalam blok agar array 1 elemen tidak jadi string.
    if ($segments.Count -gt 0 -and $segments[0] -match '^v\d+\.\d+$') {
        if ($segments.Count -gt 1) { $segments = @($segments[1..($segments.Count - 1)]) }
        else { $segments = @() }
    }

    # Buang segmen parameter (:id)
    $segments = @($segments | Where-Object { $_ -notmatch '^:' })

    # Buang segmen terakhir jika hanya angka
    if ($segments.Count -gt 0 -and $segments[$segments.Count - 1] -match '^\d+$') {
        $segments = @($segments | Select-Object -SkipLast 1)
    }

    # Buang kata aksi di ujung (create, update, ...), tapi jangan sampai segmen habis
    if ($segments.Count -gt 1 -and $ActionWords -contains $segments[$segments.Count - 1]) {
        $segments = @($segments | Select-Object -SkipLast 1)
    }

    if ($segments.Count -eq 0) { return $null }

    # Ambil maksimal $Depth segmen pertama
    $take = [Math]::Min($Depth, $segments.Count)
    $key  = ($segments[0..($take - 1)] -join '_')

    # Pastikan aman dipakai sebagai nama file
    return ($key -replace '[^A-Za-z0-9._\-]', '-')
}

# Path relatif terhadap $Root (untuk tampilan).
function Get-RelativePath {
    param([string]$Path)
    if ($Path.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($Root.Length).TrimStart('\', '/')
    }
    return $Path
}

# Backup file ke <file>.bak (tidak menimpa .bak yang sudah ada = backup tertua dipertahankan).
function Backup-File {
    param([string]$Path)
    $bak = "$Path.bak"
    if (-not (Test-Path -LiteralPath $bak)) {
        Copy-Item -LiteralPath $Path -Destination $bak
        Write-Host "    [BAK] $(Get-RelativePath $bak)" -ForegroundColor DarkCyan
    }
}

# =====================================================================
# Helper: perencanaan hasil (target)
# =====================================================================
$targets     = @{}   # path (huruf kecil) -> objek target
$targetOrder = [System.Collections.Generic.List[string]]::new()

# Mengambil target untuk sebuah path file; dibuat jika belum ada.
function Get-OrCreateTarget {
    param([string]$Path, $Source)

    $lk = $Path.ToLowerInvariant()
    if (-not $targets.ContainsKey($lk)) {
        $targets[$lk] = [PSCustomObject]@{
            Path        = $Path
            Name        = [System.IO.Path]::GetFileName($Path)
            Routers     = [System.Collections.Generic.List[object]]::new()
            RouterText  = @{}
            Services    = [System.Collections.Generic.List[object]]::new()
            ServiceText = @{}
            Extras      = [System.Collections.Generic.List[object]]::new()
            Eol         = $Source.Eol
            HasBom      = $Source.HasBom
            Indent      = $Source.Info.SectionIndent
            SkipWrite   = $false
            Failed      = $false
        }
        $targetOrder.Add($lk)
    }
    return $targets[$lk]
}

# Menambah router ke target. Router identik (nama + isi) tidak ditulis dobel.
# Jika nama sama tapi isi beda, router tidak ditambah dan dicatat sebagai masalah.
function Add-RouterToTarget {
    param($Target, $Router, $State)

    $rk   = "$($Router.Name)|$($Router.Commented)"
    $text = ($Router.Lines -join "`n").TrimEnd()

    if ($Target.RouterText.ContainsKey($rk)) {
        if ($Target.RouterText[$rk] -cne $text) {
            $State.Problems.Add("router '$($Router.Name)' namanya sama tapi isinya beda dengan yang sudah ada di $($Target.Name)")
        }
        return
    }
    $Target.RouterText[$rk] = $text
    $Target.Routers.Add([PSCustomObject]@{
        Name      = $Router.Name
        Lines     = $Router.Lines
        Commented = $Router.Commented
        Service   = $Router.Service
        Src       = $State.P
    })
}

# =====================================================================
# Pass 1: baca & parse semua file, kumpulkan semua definisi service
# =====================================================================
$parsed      = [System.Collections.Generic.List[object]]::new()
$allServices = @{}
$byPath      = @{}

foreach ($file in $files) {
    $bytes  = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text   = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }

    $eol   = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [string[]]($text -split "`r?`n")
    if ($lines.Count -gt 2000) { Write-Host "  membaca $(Get-RelativePath $file.FullName) ($($lines.Count) baris)..." -ForegroundColor DarkGray }
    $info  = Read-RouterFile -Lines $lines

    if ($info.Ok -and $info.DroppedComments -gt 0) {
        Write-Warning "[$(Get-RelativePath $file.FullName)] $($info.DroppedComments) baris komentar biasa (bukan router) di antara router tidak ikut dipindahkan."
    }

    # Baris aneh yang berhasil diselamatkan (maks. 5 per file agar layar tidak penuh)
    foreach ($w in @($info.Warnings | Select-Object -First 5)) {
        Write-Warning "[$(Get-RelativePath $file.FullName)] $w"
    }

    $p = [PSCustomObject]@{
        Path      = $file.FullName
        PathLower = $file.FullName.ToLowerInvariant()
        Dir       = $file.DirectoryName
        Eol       = $eol
        HasBom    = $hasBom
        Text      = $text
        Info      = $info
    }
    $parsed.Add($p)
    $byPath[$p.PathLower] = $p

    # Simpan definisi service (dipakai bila router merujuk service di file lain)
    if ($info.Ok) {
        foreach ($k in $info.Services.Keys) {
            if (-not $allServices.ContainsKey($k)) { $allServices[$k] = $info.Services[$k] }
        }
    }
}

# =====================================================================
# Pass 2: rencana pemecahan
# =====================================================================
$keptReport = [System.Collections.Generic.List[object]]::new()   # file yang tidak dihapus + alasan
$states     = [System.Collections.Generic.List[object]]::new()
$blocked    = @{}                                                 # file yang tidak boleh ditimpa

# File yang tidak bisa diproses tidak boleh ditimpa oleh file hasil
foreach ($p in $parsed) {
    if (-not $p.Info.Ok) {
        $blocked[$p.PathLower] = $true
        $keptReport.Add([PSCustomObject]@{ Path = $p.Path; Reason = "dilewati: $($p.Info.Reason)" })
    }
    elseif ($p.Info.Routers.Count -eq 0) {
        $blocked[$p.PathLower] = $true
        $keptReport.Add([PSCustomObject]@{ Path = $p.Path; Reason = 'dilewati: tidak ada router untuk dipecah' })
    }
}

foreach ($p in $parsed) {
    if ($blocked.ContainsKey($p.PathLower)) { continue }

    $state = [PSCustomObject]@{
        P        = $p
        Targets  = [System.Collections.Generic.HashSet[string]]::new()
        Problems = [System.Collections.Generic.List[string]]::new()
        Notes    = [System.Collections.Generic.List[string]]::new()
    }
    $states.Add($state)

    $remainder = [System.Collections.Generic.List[object]]::new()   # router yang tetap di file asli

    foreach ($r in $p.Info.Routers) {
        # Tentukan kunci grup dari PathPrefix / Path
        $key = $null
        if ($r.Rule -and $r.Rule -match '(?:PathPrefix|Path)\(`([^`]+)`\)') {
            $path = $Matches[1]
            $key  = Get-GroupKey -Path $path -Depth $GroupDepth -ActionWords $ActionWords
        }
        if (-not $key) { $remainder.Add($r); continue }

        $targetPath = Join-Path $p.Dir "$key.yml"
        if ($blocked.ContainsKey($targetPath.ToLowerInvariant())) {
            $remainder.Add($r)
            $state.Problems.Add("router '$($r.Name)' tidak dipindah karena $key.yml sudah ada dan tidak bisa diproses")
            continue
        }

        $t = Get-OrCreateTarget -Path $targetPath -Source $p
        Add-RouterToTarget -Target $t -Router $r -State $state
        [void]$state.Targets.Add($t.Path.ToLowerInvariant())
    }

    # Sisa (router tanpa PathPrefix + section lain) tetap di file asli
    if ($remainder.Count -gt 0 -or $p.Info.Extras.Count -gt 0) {
        $t = Get-OrCreateTarget -Path $p.Path -Source $p
        foreach ($r in $remainder) { Add-RouterToTarget -Target $t -Router $r -State $state }
        foreach ($ex in $p.Info.Extras) { $t.Extras.Add($ex) }

        if ($remainder.Count -gt 0) {
            $names = @($remainder | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ', '
            $state.Notes.Add("router tanpa PathPrefix/tidak bisa dikelompokkan tetap di file ini: $names")
        }
        if ($p.Info.Extras.Count -gt 0) {
            $state.Notes.Add('section lain (mis. middlewares) tetap di file ini')
        }
        [void]$state.Targets.Add($p.PathLower)
    }
}

# =====================================================================
# Pass 3: tentukan service yang ikut ke tiap file hasil
# =====================================================================
$copiedDefs = @{}   # "<nama>|<isi>" -> sudah disalin ke suatu file hasil

# 3a. Service yang dipakai router (yang aktif; kalau tidak ada yang aktif, pakai yang di-comment)
foreach ($lk in $targetOrder) {
    $t = $targets[$lk]

    $refRouters = @($t.Routers | Where-Object { -not $_.Commented })
    if ($refRouters.Count -eq 0) { $refRouters = @($t.Routers) }

    foreach ($r in $refRouters) {
        if (-not $r.Service) { continue }
        $name = $r.Service
        if ($t.ServiceText.ContainsKey($name)) { continue }

        # Utamakan definisi dari file asal router, baru cari di file lain
        $svcLines = $null
        if ($r.Src.Info.Services.Contains($name)) { $svcLines = $r.Src.Info.Services[$name] }
        elseif ($allServices.ContainsKey($name))  { $svcLines = $allServices[$name] }

        if ($null -eq $svcLines) {
            Write-Warning "Service '$name' (router '$($r.Name)') tidak ditemukan di file .yml mana pun."
            continue
        }

        $svcText = ($svcLines -join "`n").TrimEnd()
        $t.Services.Add([PSCustomObject]@{ Name = $name; Lines = $svcLines })
        $t.ServiceText[$name] = $svcText
        $copiedDefs["$name|$svcText"] = $true
    }
}

# 3b. Service yang tidak terpakai router mana pun tetap dipertahankan di file aslinya
foreach ($s in $states) {
    foreach ($name in $s.P.Info.Services.Keys) {
        $svcLines = $s.P.Info.Services[$name]
        $svcText  = ($svcLines -join "`n").TrimEnd()
        if ($copiedDefs.ContainsKey("$name|$svcText")) { continue }

        $t = Get-OrCreateTarget -Path $s.P.Path -Source $s.P
        if ($t.ServiceText.ContainsKey($name)) {
            # Nama sama tapi definisi beda -> jangan menimpa file ini
            $s.Problems.Add("service '$name' punya definisi berbeda dengan yang sudah ada di $($t.Name)")
            $t.SkipWrite = $true
            continue
        }
        $t.Services.Add([PSCustomObject]@{ Name = $name; Lines = $svcLines })
        $t.ServiceText[$name] = $svcText
        $copiedDefs["$name|$svcText"] = $true
        [void]$s.Targets.Add($s.P.PathLower)
        $s.Notes.Add("service '$name' tidak dipakai router di file ini, tetap dipertahankan")
    }
}

# =====================================================================
# Pass 4: susun isi & tulis file hasil
# =====================================================================
$cntNew = 0; $cntChanged = 0; $cntSame = 0; $cntFailed = 0

foreach ($lk in $targetOrder) {
    $t        = $targets[$lk]
    $existing = $byPath[$lk]
    $si       = $t.Indent

    # --- Susun isi file ---
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add('http:')
    if ($t.Routers.Count -gt 0) {
        $out.Add("${si}routers:")
        foreach ($r in $t.Routers) {
            $out.Add('')
            $out.AddRange([string[]]$r.Lines)
        }
    }
    if ($t.Services.Count -gt 0) {
        if ($t.Routers.Count -gt 0) { $out.Add('') }
        $out.Add("${si}services:")
        foreach ($svc in $t.Services) { $out.AddRange([string[]]$svc.Lines) }
    }
    foreach ($ex in $t.Extras) {
        $out.Add('')
        $out.AddRange([string[]]$ex)
    }
    $newText = ($out -join $t.Eol) + $t.Eol

    # --- File sudah persis sama: tidak perlu ditulis ---
    if ($null -ne $existing -and $existing.Text -ceq $newText) { $cntSame++; continue }

    $rel   = Get-RelativePath $t.Path
    $label = if ($null -ne $existing) { 'UBAH' } else { 'BARU' }
    Write-Host ("  [{0}] {1}  ({2} router)" -f $label, $rel, $t.Routers.Count) -ForegroundColor Yellow

    if ($t.SkipWrite) {
        Write-Warning "    Tidak ditulis: ada service berbeda definisi di $($t.Name)."
        $t.Failed = $true
        $cntFailed++
        continue
    }

    if ($WhatIf) {
        Write-Host '    [WHATIF] tidak menulis' -ForegroundColor DarkYellow
    }
    else {
        try {
            if ($Backup -and $null -ne $existing) { Backup-File -Path $t.Path }
            $enc = [System.Text.UTF8Encoding]::new([bool]$t.HasBom)
            [System.IO.File]::WriteAllText($t.Path, $newText, $enc)
        }
        catch {
            Write-Warning "    Gagal menulis $($t.Name): $($_.Exception.Message)"
            $t.Failed = $true
            $cntFailed++
            continue
        }
    }
    if ($null -ne $existing) { $cntChanged++ } else { $cntNew++ }
}

# =====================================================================
# Pass 5: hapus file asli yang isinya sudah pindah semua
# =====================================================================
$deleted     = [System.Collections.Generic.List[object]]::new()
$cntSelfOk   = 0

foreach ($s in $states) {
    $p = $s.P

    # Apakah ada file hasil milik file ini yang gagal ditulis?
    $targetFailed = $false
    foreach ($tl in $s.Targets) {
        if ($targets[$tl].Failed) { $targetFailed = $true }
    }

    # File asli dipakai sebagai salah satu file hasil -> tidak dihapus
    if ($targets.ContainsKey($p.PathLower)) {
        $why = @($s.Notes) + @($s.Problems)
        if ($why.Count -gt 0) {
            $keptReport.Add([PSCustomObject]@{ Path = $p.Path; Reason = 'dipertahankan: ' + ($why -join '; ') })
        }
        else {
            $cntSelfOk++
        }
        continue
    }

    if ($s.Problems.Count -gt 0) {
        $keptReport.Add([PSCustomObject]@{ Path = $p.Path; Reason = 'tidak dihapus: ' + ($s.Problems -join '; ') })
        continue
    }
    if ($targetFailed) {
        $keptReport.Add([PSCustomObject]@{ Path = $p.Path; Reason = 'tidak dihapus: ada file hasil yang gagal/tidak ditulis' })
        continue
    }
    if (-not $DeleteOriginal) {
        $keptReport.Add([PSCustomObject]@{ Path = $p.Path; Reason = 'belum dihapus (jalankan dengan -DeleteOriginal)' })
        continue
    }

    $names = @($s.Targets | ForEach-Object { $targets[$_].Name })

    if (-not $WhatIf) {
        try {
            if ($Backup) { Backup-File -Path $p.Path }
            Remove-Item -LiteralPath $p.Path -Force
        }
        catch {
            $keptReport.Add([PSCustomObject]@{ Path = $p.Path; Reason = "gagal dihapus: $($_.Exception.Message)" })
            continue
        }
    }
    $deleted.Add([PSCustomObject]@{ Path = $p.Path; Dir = $p.Dir; Targets = $names })
}

# --- Hapus folder yang jadi kosong (hanya mode APPLY) ---
$removedFolders = [System.Collections.Generic.List[string]]::new()
if (-not $WhatIf) {
    $dirs = @($deleted | ForEach-Object { $_.Dir } | Select-Object -Unique)
    foreach ($dir in $dirs) {
        $d = $dir
        while ($d -and ($d -ine $Root) -and $d.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $d)) {
            $remaining = @(Get-ChildItem -LiteralPath $d -Force)
            if ($remaining.Count -gt 0) { break }
            Remove-Item -LiteralPath $d -Force
            $removedFolders.Add($d)
            $d = Split-Path -Parent $d
        }
    }
}

# =====================================================================
# Laporan akhir
# =====================================================================
Write-Host ''
Write-Host '==================== LAPORAN ====================' -ForegroundColor Cyan
Write-Host ("Mode                     : " + $(if ($WhatIf) { 'WHATIF (tidak ada perubahan nyata)' } else { 'APPLY' }))
Write-Host ("File .yml dipindai       : {0}" -f $files.Count)
Write-Host ("File hasil baru          : {0}" -f $cntNew)
Write-Host ("File hasil diubah        : {0}" -f $cntChanged)
Write-Host ("File hasil sudah sesuai  : {0} (tidak ditulis ulang)" -f $cntSame)
Write-Host ("File asli dihapus        : {0}" -f $deleted.Count)
Write-Host ("Folder dihapus           : {0}" -f $removedFolders.Count)
Write-Host ("File tidak dihapus/lewat : {0}" -f $keptReport.Count)
if ($cntFailed -gt 0) { Write-Host ("Gagal ditulis            : {0}" -f $cntFailed) -ForegroundColor Red }
Write-Host ''

# --- Daftar file/folder yang dihapus ---
$delTitle = if ($WhatIf) { 'FILE ASLI YANG AKAN DIHAPUS (simulasi)' } else { 'FILE ASLI YANG DIHAPUS' }
Write-Host "--- $delTitle ($($deleted.Count)) ---" -ForegroundColor Magenta
if ($deleted.Count -eq 0) {
    Write-Host '  (tidak ada)' -ForegroundColor DarkGray
}
else {
    $byDir = $deleted | Group-Object -Property { Split-Path -Parent (Get-RelativePath $_.Path) } | Sort-Object Name
    foreach ($g in $byDir) {
        $folderLabel = if ([string]::IsNullOrEmpty($g.Name)) { '.' } else { $g.Name }
        Write-Host "[$folderLabel]" -ForegroundColor Magenta
        foreach ($d in ($g.Group | Sort-Object Path)) {
            $show = @($d.Targets | Select-Object -First 4) -join ', '
            if ($d.Targets.Count -gt 4) { $show += ', ...' }
            Write-Host ("   - {0}  ->  {1} file ({2})" -f [System.IO.Path]::GetFileName($d.Path), $d.Targets.Count, $show)
        }
    }
}
Write-Host ''

Write-Host "--- FOLDER YANG DIHAPUS ($($removedFolders.Count)) ---" -ForegroundColor Magenta
if ($removedFolders.Count -eq 0) {
    Write-Host '  (tidak ada)' -ForegroundColor DarkGray
}
else {
    foreach ($f in $removedFolders) { Write-Host "   - $(Get-RelativePath $f)" }
}
Write-Host ''

# --- Daftar file yang tidak dihapus + alasannya ---
Write-Host "--- FILE YANG TIDAK DIHAPUS / DILEWATI ($($keptReport.Count)) ---" -ForegroundColor Yellow
if ($keptReport.Count -eq 0) {
    Write-Host '  (tidak ada)' -ForegroundColor DarkGray
}
else {
    foreach ($k in ($keptReport | Sort-Object Path)) {
        Write-Host ("   - {0}" -f (Get-RelativePath $k.Path)) -ForegroundColor Yellow
        Write-Host ("       {0}" -f $k.Reason) -ForegroundColor DarkYellow
    }
}
Write-Host ''
