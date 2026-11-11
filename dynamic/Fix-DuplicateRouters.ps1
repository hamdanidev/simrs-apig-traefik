<#
.SYNOPSIS
    Reorder (dan opsional: comment) router duplikat "duplicat_*" pada file .yml/.yaml.

.DESCRIPTION
    Memindai semua file .yml/.yaml di dalam -Path secara rekursif.
    Setiap router (key yang diakhiri suffix HTTP method: GET/POST/PUT/DELETE/
    PATCH/OPTIONS/HEAD) yang ber-prefix "duplicat_" akan dipindahkan tepat
    di bawah router aslinya (yang tanpa prefix).

    Gunakan -Hide untuk sekaligus meng-comment blok duplikat dengan prefix "# ".

.PARAMETER Path
    Folder root yang akan di-scan. Default: .\dynamic

.PARAMETER Hide
    Comment out blok router duplikat (tiap baris non-kosong diberi "# ").

.PARAMETER DryRun
    Tampilkan preview hasil tanpa menulis ke file.

.PARAMETER Backup
    Simpan backup "<file>.bak" sebelum menimpa file.

.EXAMPLE
    .\Fix-DuplicateRouters.ps1 -Path .\dynamic -DryRun

.EXAMPLE
    .\Fix-DuplicateRouters.ps1 -Path .\dynamic -Hide -Backup
#>
[CmdletBinding()]
param(
    [string]$Path = ".\dynamic",
    [switch]$Hide,
    [switch]$DryRun,
    [switch]$Backup
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "Folder not found: $Path"
}

# Regex: baris awal router.
#   'dup'  -> prefix opsional "duplicat_"
#   'base' -> nama router + suffix method (dipakai sebagai kunci pencocokan)
$RouterRegex = '^(?<indent>\s+)(?<dup>duplicat_)?(?<base>[\w\-]+_(?:GET|POST|PUT|DELETE|PATCH|OPTIONS|HEAD)):\s*$'

function Split-Routers {
    param([string[]]$Lines)

    $starts = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $RouterRegex) {
            $starts.Add([pscustomobject]@{
                Index   = $i
                IsDup   = [bool]$Matches['dup']
                BaseKey = $Matches['base']
                Header  = $Lines[$i]
            })
        }
    }

    $prefix = @()
    $blocks = New-Object System.Collections.Generic.List[object]

    if ($starts.Count -gt 0) {
        if ($starts[0].Index -gt 0) {
            $prefix = @($Lines[0..($starts[0].Index - 1)])
        }
        for ($r = 0; $r -lt $starts.Count; $r++) {
            $s = $starts[$r].Index
            $e = if ($r -lt $starts.Count - 1) { $starts[$r + 1].Index - 1 } else { $Lines.Count - 1 }
            $blocks.Add([pscustomobject]@{
                Info  = $starts[$r]
                Lines = @($Lines[$s..$e])
            })
        }
    }

    return [pscustomobject]@{ Prefix = $prefix; Blocks = $blocks }
}

function Reorder-Routers {
    param([pscustomobject]$Parsed, [switch]$DoHide)

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($l in $Parsed.Prefix) { $out.Add($l) }

    $blocks = $Parsed.Blocks
    $used = [bool[]]::new($blocks.Count)
    $moved = $false
    $commented = $false

    # Pass 1: setiap router asli, lalu semua duplikatnya.
    for ($i = 0; $i -lt $blocks.Count; $i++) {
        if ($used[$i]) { continue }
        if ($blocks[$i].Info.IsDup) { continue }

        $used[$i] = $true
        foreach ($l in $blocks[$i].Lines) { $out.Add($l) }

        for ($j = 0; $j -lt $blocks.Count; $j++) {
            if ($used[$j]) { continue }
            if (-not $blocks[$j].Info.IsDup) { continue }
            if ($blocks[$j].Info.BaseKey -ne $blocks[$i].Info.BaseKey) { continue }

            $used[$j] = $true
            $moved = $true
            if ($DoHide) {
                $commented = $true
                foreach ($l in $blocks[$j].Lines) {
                    if ([string]::IsNullOrWhiteSpace($l)) { $out.Add($l) }
                    else { $out.Add("# $l") }
                }
            } else {
                foreach ($l in $blocks[$j].Lines) { $out.Add($l) }
            }
        }
    }

    # Pass 2: duplikat tanpa pasangan -> taruh di akhir + warning.
    for ($i = 0; $i -lt $blocks.Count; $i++) {
        if ($used[$i]) { continue }
        $used[$i] = $true
        Write-Warning ("Orphan duplicate: {0}" -f $blocks[$i].Info.Header.Trim())
        foreach ($l in $blocks[$i].Lines) { $out.Add($l) }
    }

    return [pscustomobject]@{
        Lines     = $out
        Moved     = $moved
        Commented = $commented
    }
}

# Kumpulkan target file
$targets = @(Get-ChildItem -Path $Path -Recurse -File |
    Where-Object { $_.Extension -in '.yml', '.yaml' })

if ($targets.Count -eq 0) {
    Write-Host "No .yml/.yaml files found under: $Path"
    return
}

$changed = 0
$failed  = 0

foreach ($file in $targets) {
    try {
        # Deteksi encoding/newline asli agar tidak mengubah format file
        $raw   = [System.IO.File]::ReadAllText($file.FullName)
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        $hadBom = ($bytes.Length -ge 3 -and
                   $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

        $newline = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
        $hadTrailingNewline = $raw.EndsWith("`n")

        $lines = @(Get-Content -LiteralPath $file.FullName)
        if ($lines.Count -eq 0) { continue }

        $parsed = Split-Routers -Lines $lines
        if ($parsed.Blocks.Count -eq 0) {
            Write-Verbose "No router entries: $($file.FullName)"
            continue
        }

        $result = Reorder-Routers -Parsed $parsed -DoHide:($Hide.IsPresent)

        $oldText = $lines -join $newline
        $newText = $result.Lines -join $newline
        if ($oldText -ceq $newText) {
            Write-Verbose "Unchanged: $($file.FullName)"
            continue
        }

        $changed++
        Write-Host ("Changed: {0}  (moved={1}, commented={2})" -f
            $file.FullName, $result.Moved, $result.Commented)

        if ($DryRun) {
            Write-Host "--- PREVIEW: $($file.FullName) ---"
            $result.Lines | ForEach-Object { Write-Host $_ }
            Write-Host "--- END PREVIEW ---"
            continue
        }

        if ($Backup) {
            Copy-Item -LiteralPath $file.FullName -Destination "$($file.FullName).bak" -Force
        }

        $outText = ($result.Lines -join $newline)
        if ($hadTrailingNewline) { $outText += $newline }
        $enc = New-Object System.Text.UTF8Encoding($hadBom)
        [System.IO.File]::WriteAllText($file.FullName, $outText, $enc)
    }
    catch {
        $failed++
        Write-Warning ("Failed {0}: {1}" -f $file.FullName, $_.Exception.Message)
    }
}

Write-Host ""
Write-Host ("Summary: changed={0}, failed={1}, scanned={2}" -f $changed, $failed, $targets.Count)
