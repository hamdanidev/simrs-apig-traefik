<#
.SYNOPSIS
    Rapihkan nama router Traefik di semua file .yml di folder dynamic (rekursif).

.DESCRIPTION
    Scan semua file .yml di bawah $Root (default: folder tempat skrip ini berada).
    Setiap router yang punya:
        rule: "PathPrefix(`<path>`) && (Method(`<M>`) ..."
    akan di-rename menjadi:
        <version>_<segmen-path>..._<METHOD>

    Dimana:
      - <version>     : v1, v2, dst. dari segmen "/v1.0/", "/v2.0/"
      - <segmen-path> : segmen path setelah version, trailing "/" dibuang,
                        segmen param (":id") dan trailing numeric dihilangkan
      - <METHOD>      : sesuai method pada rule, SELALU UPPERCASE
                        (GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS)

    Rule, service, entryPoints, middlewares TIDAK diubah - hanya nama router.
    File di-scan rekursif, semua subfolder ikut diproses.

.PARAMETER Root
    Folder akar pencarian file .yml.
    Default: folder tempat skrip ini berada ($PSScriptRoot).

.PARAMETER WhatIf
    Preview perubahan tanpa menulis file.

.PARAMETER Backup
    Buat file .bak sebelum menulis ulang.

.EXAMPLE
    PS> .\rerapihkan-router.ps1

.EXAMPLE
    PS> .\rerapihkan-router.ps1 -Root 'D:\traefik\dynamic'

.EXAMPLE
    PS> .\rerapihkan-router.ps1 -WhatIf

.EXAMPLE
    PS> .\rerapihkan-router.ps1 -Backup
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Root = $PSScriptRoot,

    [switch]$WhatIf,

    [switch]$Backup
)

# ---------- Validasi root ----------
if (-not $Root) { $Root = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $Root)) {
    throw "Folder tidak ditemukan: $Root"
}
$Root = (Resolve-Path -LiteralPath $Root).Path

$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.yml')
if ($files.Count -eq 0) {
    Write-Warning "Tidak ada file .yml di bawah: $Root"
    return
}

Write-Host "Scan folder : $Root" -ForegroundColor Cyan
Write-Host "File .yml   : $($files.Count)" -ForegroundColor Cyan
Write-Host ("Mode        : " + $(if ($WhatIf) { 'WHATIF (preview)' } else { 'APPLY (menulis file)' })) -ForegroundColor Cyan
Write-Host ''

# ---------- Helper: bangun nama router baru ----------
function Convert-ToRouterName {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Method
    )

    $segments = @($Path -split '/' | Where-Object { $_ -ne '' })
    if ($segments.Count -eq 0) { return $null }

    # Version prefix: /v1.0/ -> v1, /v2.0/ -> v2
    $versionPart = $null
    if ($segments[0] -match '^v(\d+)\.\d+$') {
        $versionPart = "v$($Matches[1])"
        $segments = if ($segments.Count -gt 1) { $segments[1..($segments.Count - 1)] } else { @() }
    }

    # Buang segmen param & trailing numeric
    $kept = @()
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $seg               = $segments[$i]
        $isParam           = $seg -match '^:'
        $isTrailingNumeric = ($i -eq $segments.Count - 1) -and ($seg -match '^\d+$')
        if ($isParam -or $isTrailingNumeric) { continue }
        $kept += $seg
    }

    if ($kept.Count -eq 0) { return $null }

    # Method SELALU UPPERCASE
    # $methodSuffix = $Method.ToUpperInvariant()
    $methodSuffix = $Method # tidak di uppercse

    $parts = @()
    if ($versionPart) { $parts += $versionPart }
    $parts += $kept
    $parts += $methodSuffix
    return ($parts -join '_')
}

# ---------- Proses tiap file ----------
$totalFiles   = 0
$totalRenamed = 0

foreach ($file in $files) {
    Write-Host "[$($file.FullName)]" -ForegroundColor Cyan

    # --- Baca bytes + deteksi BOM + line ending ---
    $bytes  = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text   = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }

    $eol   = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = @($text -split "`r?`n")

    $changed      = $false
    $fileRenames  = 0
    $seenNewNames = [System.Collections.Generic.HashSet[string]]::new()

    for ($i = 0; $i -lt $lines.Count; $i++) {

        # Cari baris "name:" (indent > 0, karakter aman)
        if ($lines[$i] -notmatch '^(\s+)([A-Za-z0-9_\-]+):\s*$') { continue }
        $indent  = $Matches[1]
        $oldName = $Matches[2]

        # Cari baris rule berikutnya (skip blank)
        $ruleIdx = -1
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            if ($lines[$j].Trim() -ne '') { $ruleIdx = $j; break }
        }
        if ($ruleIdx -lt 0) { continue }
        if ($lines[$ruleIdx] -notmatch 'rule:\s*"(.*)"\s*$') { continue }
        $ruleContent = $Matches[1]

        # Parse path & method dari rule
        if ($ruleContent -notmatch 'PathPrefix\(`([^`]+)`\)') { continue }
        $path = $Matches[1]
        if ($ruleContent -notmatch 'Method\(`(\w+)`\)') { continue }
        $method = $Matches[1]

        $newName = Convert-ToRouterName -Path $path -Method $method
        if (-not $newName) { continue }
        if ($newName -eq $oldName) { [void]$seenNewNames.Add($newName); continue }

        if (-not $seenNewNames.Add($newName)) {
            Write-Warning "  Tabrakan nama '$newName' (dari '$oldName') - dilewati"
            continue
        }

        Write-Host ("  {0,-45} -> {1}" -f $oldName, $newName) -ForegroundColor Yellow
        $lines[$i] = "$indent$newName`:"
        $changed     = $true
        $fileRenames++
    }

    if (-not $changed) {
        Write-Host "  (tidak ada perubahan)" -ForegroundColor DarkGray
        Write-Host ''
        continue
    }

    $totalFiles++
    $totalRenamed += $fileRenames

    if ($WhatIf) {
        Write-Host "  [WHATIF] tidak menulis $($file.Name) ($fileRenames router)" -ForegroundColor DarkYellow
    }
    else {
        if ($Backup) {
            $bak = "$($file.FullName).bak"
            Copy-Item -LiteralPath $file.FullName -Destination $bak -Force
            Write-Host "  [BAK] $bak" -ForegroundColor DarkCyan
        }
        $newText = ($lines -join $eol)
        $enc     = [System.Text.UTF8Encoding]::new([bool]$hasBom)
        [System.IO.File]::WriteAllText($file.FullName, $newText, $enc)
        Write-Host "  [OK] $($file.Name) ($fileRenames router)" -ForegroundColor Green
    }
    Write-Host ''
}

Write-Host ("Selesai. File diubah: {0}, total router di-rename: {1}" -f $totalFiles, $totalRenamed) -ForegroundColor Cyan
