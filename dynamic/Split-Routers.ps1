<#
.SYNOPSIS
    Pecah file router Traefik (.yml) menjadi beberapa file, satu file per grup path.

.DESCRIPTION
    Scan semua .yml rekursif dari $Root. Untuk setiap file:
      1. Baca semua router (section http > routers) dan service (http > services).
      2. Ambil path dari PathPrefix(`...`) lalu tentukan "kunci grup":
            /v1.0/erm/meso/create                          -> erm_meso
            /v1.0/erm/meso/obat-meso/get-by-id/            -> erm_meso
            /v1.0/erm/rekonsiliasi-obat/list-x/create      -> erm_rekonsiliasi-obat
            /v1.0/get-jadwal-pegawai-lengkap-hfis/         -> get-jadwal-pegawai-lengkap-hfis
         Aturannya:
            - buang segmen versi (v1.0)
            - buang segmen parameter (diawali ':') dan segmen terakhir yang angka saja
            - buang segmen terakhir jika berupa kata aksi (create, update, delete, ...)
            - ambil maksimal $GroupDepth segmen pertama, gabung dengan "_"
      3. Tulis satu file per grup di folder yang sama: <kunci-grup>.yml
         Isi file: router milik grup itu + definisi service yang dipakai router tersebut.

    Isi router TIDAK diubah sama sekali (disalin apa adanya).

    Aman:
      - File yang punya section lain selain routers/services (mis. middlewares) dilewati.
      - File yang punya router tanpa PathPrefix dilewati.
      - File tujuan yang sudah ada tidak ditimpa (kecuali -Force).
      - File asli tidak dihapus kecuali pakai -DeleteOriginal.

.EXAMPLE
    .\Split-Routers.ps1 -WhatIf
    .\Split-Routers.ps1 -Backup -DeleteOriginal
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Root = $PSScriptRoot,

    # Jumlah maksimal segmen path yang dipakai untuk nama file (default 2 -> erm_meso)
    [int]$GroupDepth = 2,

    # Kata aksi di ujung path yang tidak ikut dipakai untuk nama file
    [string[]]$ActionWords = @('create', 'update', 'delete', 'get-list', 'get-by-id'),

    [switch]$WhatIf,          # hanya tampilkan rencana, tidak menulis apa pun
    [switch]$Backup,          # buat <file>.bak dari file asli sebelum diubah/dihapus
    [switch]$DeleteOriginal,  # hapus file asli setelah semua grupnya berhasil ditulis
    [switch]$Force            # boleh menimpa file tujuan yang sudah ada
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

# Menghitung jumlah spasi di awal sebuah baris (indentasi).
function Get-IndentLength {
    param([string]$Line)
    return ($Line.Length - $Line.TrimStart().Length)
}

# True jika baris kosong, komentar (#), atau penanda dokumen (---).
function Test-SkipLine {
    param([string]$Line)
    $t = $Line.Trim()
    return ($t -eq '' -or $t.StartsWith('#') -or $t -eq '---')
}

# Mencari akhir sebuah blok YAML: baris berikutnya yang indentasinya <= baris awal.
# Baris kosong/komentar di ekor blok dibuang. Hasil: indeks akhir (eksklusif).
function Get-BlockEnd {
    param([string[]]$Lines, [int]$Start, [int]$Limit)

    $indent = Get-IndentLength $Lines[$Start]
    $end = $Start + 1
    while ($end -lt $Limit) {
        if (-not (Test-SkipLine $Lines[$end]) -and (Get-IndentLength $Lines[$end]) -le $indent) { break }
        $end++
    }
    while ($end -gt ($Start + 1) -and (Test-SkipLine $Lines[$end - 1])) { $end-- }
    return $end
}

# Memecah isi sebuah section (mis. routers) menjadi daftar blok anak: @{Name; Lines}.
# Mengembalikan $null jika strukturnya tidak dikenali.
function Get-ChildBlocks {
    param([string[]]$Lines, [int]$Start, [int]$End)

    $blocks   = [System.Collections.Generic.List[object]]::new()
    $childLen = -1
    $j = $Start
    while ($j -lt $End) {
        if (Test-SkipLine $Lines[$j]) { $j++; continue }

        $len = Get-IndentLength $Lines[$j]
        if ($childLen -lt 0) { $childLen = $len }
        if ($len -ne $childLen -or $Lines[$j] -notmatch '^\s*([A-Za-z0-9_.\-]+):\s*$') { return $null }

        $name     = $Matches[1]
        $blockEnd = Get-BlockEnd -Lines $Lines -Start $j -Limit $End
        $blocks.Add([PSCustomObject]@{
            Name  = $name
            Lines = [string[]]@($Lines[$j..($blockEnd - 1)])
        })
        $j = $blockEnd
    }
    # Tanda koma mencegah list "dibongkar" saat dikembalikan
    return , $blocks
}

# Membaca satu file Traefik dynamic config.
# Hasil: hashtable dengan Ok, Reason, SectionIndent, Routers, Services.
function Read-RouterFile {
    param([string[]]$Lines)

    $result = @{
        Ok            = $false
        Reason        = ''
        SectionIndent = '  '
        Routers       = [System.Collections.Generic.List[object]]::new()
        Services      = @{}
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

    # 2. Baca section di dalam http: (hanya routers & services yang didukung)
    $i      = $httpIdx + 1
    $secLen = -1
    while ($i -lt $httpEnd) {
        if (Test-SkipLine $Lines[$i]) { $i++; continue }

        $len = Get-IndentLength $Lines[$i]
        if ($secLen -lt 0) { $secLen = $len; $result.SectionIndent = ' ' * $len }
        if ($len -ne $secLen -or $Lines[$i] -notmatch '^\s*([A-Za-z0-9_\-]+):\s*$') {
            $result.Reason = "struktur YAML tidak dikenali di baris $($i + 1)"
            return $result
        }

        $sectionName = $Matches[1]
        if ($sectionName -ne 'routers' -and $sectionName -ne 'services') {
            $result.Reason = "ada section '$sectionName' (hanya routers & services yang didukung)"
            return $result
        }

        $sectionEnd = Get-BlockEnd -Lines $Lines -Start $i -Limit $httpEnd
        $blocks = Get-ChildBlocks -Lines $Lines -Start ($i + 1) -End $sectionEnd
        if ($null -eq $blocks) {
            $result.Reason = "isi '$sectionName' tidak bisa dibaca"
            return $result
        }

        if ($sectionName -eq 'routers') {
            foreach ($b in $blocks) {
                # Ambil rule dan nama service dari baris-baris router
                $rule = $null; $service = $null
                foreach ($l in $b.Lines) {
                    if ($null -eq $rule -and $l -match '^\s*rule:\s*["''](.*)["'']\s*$') { $rule = $Matches[1] }
                    if ($null -eq $service -and $l -match '^\s*service:\s*["'']?([^"''\s]+)["'']?\s*$') { $service = $Matches[1] }
                }
                $result.Routers.Add([PSCustomObject]@{
                    Name    = $b.Name
                    Lines   = $b.Lines
                    Rule    = $rule
                    Service = $service
                })
            }
        }
        else {
            foreach ($b in $blocks) { $result.Services[$b.Name] = $b.Lines }
        }

        $i = $sectionEnd
    }

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

# =====================================================================
# Pass 1: baca & parse semua file, kumpulkan semua definisi service
# =====================================================================
$parsed      = [System.Collections.Generic.List[object]]::new()
$allServices = @{}

foreach ($file in $files) {
    $bytes  = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text   = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }

    $eol   = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [string[]]($text -split "`r?`n")
    $info  = Read-RouterFile -Lines $lines

    $parsed.Add([PSCustomObject]@{ File = $file; Eol = $eol; HasBom = $hasBom; Info = $info })

    # Simpan definisi service (dipakai bila router merujuk service di file lain)
    if ($info.Ok) {
        foreach ($k in $info.Services.Keys) {
            if (-not $allServices.ContainsKey($k)) { $allServices[$k] = $info.Services[$k] }
        }
    }
}

# =====================================================================
# Pass 2: pecah per file
# =====================================================================
$written       = @{}   # target yang sudah dibuat pada run ini (cegah tabrakan)
$totalSources  = 0
$totalCreated  = 0
$totalSkipped  = 0

foreach ($p in $parsed) {
    $src  = $p.File.FullName
    $info = $p.Info

    # --- Validasi file ---
    if (-not $info.Ok) {
        Write-Host "[$src]" -ForegroundColor Cyan
        Write-Warning "  Dilewati: $($info.Reason)"
        Write-Host ''
        $totalSkipped++
        continue
    }
    if ($info.Routers.Count -eq 0) { continue }   # tidak ada router, tidak ada yang dipecah

    # --- Kelompokkan router berdasarkan kunci grup ---
    $groups       = @{}
    $groupOrder   = [System.Collections.Generic.List[string]]::new()
    $unclassified = [System.Collections.Generic.List[string]]::new()

    foreach ($r in $info.Routers) {
        $key = $null
        if ($r.Rule -and $r.Rule -match 'PathPrefix\(`([^`]+)`\)') {
            $path = $Matches[1]
            $key  = Get-GroupKey -Path $path -Depth $GroupDepth -ActionWords $ActionWords
        }
        if (-not $key) { $unclassified.Add($r.Name); continue }

        $lk = $key.ToLowerInvariant()
        if (-not $groups.ContainsKey($lk)) {
            $groups[$lk] = [PSCustomObject]@{
                Key     = $key
                Routers = [System.Collections.Generic.List[object]]::new()
            }
            $groupOrder.Add($lk)
        }
        $groups[$lk].Routers.Add($r)
    }

    Write-Host "[$src]" -ForegroundColor Cyan

    if ($unclassified.Count -gt 0) {
        Write-Warning ("  Dilewati: router tanpa PathPrefix/tidak bisa dikelompokkan: " + ($unclassified -join ', '))
        Write-Host ''
        $totalSkipped++
        continue
    }

    # File yang hanya berisi 1 grup dan sudah bernama sesuai -> sudah rapi
    $firstTarget = Join-Path $p.File.DirectoryName ($groups[$groupOrder[0]].Key + '.yml')
    if ($groupOrder.Count -eq 1 -and $firstTarget -ieq $src) {
        Write-Host '  [SKIP] sudah sesuai (1 grup, nama file sama)' -ForegroundColor DarkGray
        Write-Host ''
        continue
    }

    $allOk     = $true
    $selfWrite = $false
    $backedUp  = $false

    foreach ($lk in $groupOrder) {
        $g          = $groups[$lk]
        $targetName = "$($g.Key).yml"
        $target     = Join-Path $p.File.DirectoryName $targetName
        $isSelf     = ($target -ieq $src)

        # Cek tabrakan nama file tujuan
        if ($written.ContainsKey($target.ToLowerInvariant())) {
            Write-Warning "  Dilewati grup '$($g.Key)': $targetName sudah dibuat dari file lain pada run ini."
            $allOk = $false; continue
        }
        if ((Test-Path -LiteralPath $target) -and -not $isSelf -and -not $Force) {
            Write-Warning "  Dilewati grup '$($g.Key)': $targetName sudah ada (pakai -Force untuk menimpa)."
            $allOk = $false; continue
        }

        # Kumpulkan service yang dipakai router di grup ini
        $serviceNames = [System.Collections.Generic.List[string]]::new()
        foreach ($r in $g.Routers) {
            if ($r.Service -and -not $serviceNames.Contains($r.Service)) { $serviceNames.Add($r.Service) }
        }

        # Susun isi file baru
        $si  = $info.SectionIndent
        $out = [System.Collections.Generic.List[string]]::new()
        $out.Add('http:')
        $out.Add("${si}routers:")
        foreach ($r in $g.Routers) {
            $out.Add('')
            $out.AddRange([string[]]$r.Lines)
        }

        $serviceBlocks = [System.Collections.Generic.List[object]]::new()
        foreach ($sn in $serviceNames) {
            if ($info.Services.ContainsKey($sn))  { $serviceBlocks.Add($info.Services[$sn]) }
            elseif ($allServices.ContainsKey($sn)) { $serviceBlocks.Add($allServices[$sn]) }
            else { Write-Warning "  Service '$sn' tidak ditemukan di file .yml mana pun (grup '$($g.Key)')." }
        }
        if ($serviceBlocks.Count -gt 0) {
            $out.Add('')
            $out.Add("${si}services:")
            foreach ($sb in $serviceBlocks) { $out.AddRange([string[]]$sb) }
        }

        Write-Host ("  {0,-55} ({1} router)" -f $targetName, $g.Routers.Count) -ForegroundColor Yellow

        if ($WhatIf) {
            Write-Host "    [WHATIF] tidak menulis $targetName" -ForegroundColor DarkYellow
        }
        else {
            # Backup file asli sekali saja sebelum ada perubahan
            if ($Backup -and -not $backedUp) {
                Copy-Item -LiteralPath $src -Destination "$src.bak" -Force
                Write-Host "    [BAK] $src.bak" -ForegroundColor DarkCyan
                $backedUp = $true
            }
            $newText = ($out -join $p.Eol) + $p.Eol
            $enc     = [System.Text.UTF8Encoding]::new([bool]$p.HasBom)
            [System.IO.File]::WriteAllText($target, $newText, $enc)
            Write-Host "    [OK] $targetName" -ForegroundColor Green
        }

        $written[$target.ToLowerInvariant()] = $src
        if ($isSelf) { $selfWrite = $true }
        $totalCreated++
    }

    # Hapus file asli bila diminta, semua grup sukses, dan file asli tidak ikut ditimpa
    if ($DeleteOriginal) {
        if (-not $allOk) {
            Write-Warning '  File asli dipertahankan karena ada grup yang dilewati.'
        }
        elseif ($selfWrite) {
            Write-Host '  [INFO] file asli dipakai sebagai salah satu hasil, tidak dihapus.' -ForegroundColor DarkGray
        }
        elseif ($WhatIf) {
            Write-Host "  [WHATIF] akan menghapus file asli: $([System.IO.Path]::GetFileName($src))" -ForegroundColor DarkYellow
        }
        else {
            Remove-Item -LiteralPath $src -Force
            Write-Host "  [DEL] $([System.IO.Path]::GetFileName($src))" -ForegroundColor Magenta
        }
    }
    elseif (-not $selfWrite) {
        Write-Host '  [INFO] file asli dipertahankan (pakai -DeleteOriginal untuk menghapus).' -ForegroundColor DarkGray
    }

    Write-Host ''
    $totalSources++
}

Write-Host ("Selesai. File diproses: {0}, file hasil: {1}, dilewati: {2}" -f $totalSources, $totalCreated, $totalSkipped) -ForegroundColor Cyan
