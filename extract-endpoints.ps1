<#
.SYNOPSIS
    Ekstrak daftar URL + Method unik dari Postman Collection JSON.

.DESCRIPTION
    Mengambil setiap request.url.raw & request.method dari collection,
    lalu menampilkan dalam format: <url> || <method> tanpa duplikat.
    Dikelompokkan per kategori (top-level item) dengan baris kosong pemisah.

.PARAMETER Path
    Path file Postman collection (.json).

.PARAMETER OutputPath
    (Opsional) Path file output .txt. Jika tidak diisi, hasil tampil ke console.

.EXAMPLE
    .\extract-endpoints.ps1 -Path .\BE-ERM-Lesmana.json

.EXAMPLE
    .\extract-endpoints.ps1 -Path .\BE-ERM-Lesmana.json -OutputPath .\endpoints.txt
#>

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [Parameter(Position = 1)]
    [string]$OutputPath
)

# --- Validasi file ---
if (-not (Test-Path -LiteralPath $Path)) {
    throw "File tidak ditemukan: $Path"
}

# --- Load JSON ---
$json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
if (-not $json -or -not $json.item) {
    throw "File bukan Postman Collection yang valid (tidak ada 'item')."
}

$results = New-Object System.Collections.Generic.List[object]

# --- Traversal rekursif ---
function Walk-Items {
    param($items, [string]$category)

    foreach ($item in $items) {
        # Jika node ini punya request -> ambil url + method
        if ($item.PSObject.Properties.Name -contains 'request' -and $item.request) {
            $raw    = $item.request.url.raw
            $method = $item.request.method
            if ($raw) {
                $results.Add([PSCustomObject]@{
                    Category = $category
                    Url      = $raw
                    Method   = $method
                })
            }
        }

        # Jika node punya children -> rekursi
        if ($item.PSObject.Properties.Name -contains 'item' -and $item.item) {
            $cat = if ($category) { $category } else { $item.name }
            Walk-Items -items $item.item -category $cat
        }
    }
}

foreach ($topItem in $json.item) {
    if ($topItem.PSObject.Properties.Name -contains 'item' -and $topItem.item) {
        Walk-Items -items $topItem.item -category $topItem.name
    }
    elseif ($topItem.PSObject.Properties.Name -contains 'request' -and $topItem.request) {
        $raw    = $topItem.request.url.raw
        $method = $topItem.request.method
        if ($raw) {
            $results.Add([PSCustomObject]@{
                Category = ""
                Url      = $raw
                Method   = $method
            })
        }
    }
}

# --- Deduplikasi (preserve order kemunculan pertama) ---
$seen   = @{}
$unique = foreach ($r in $results) {
    $key = "$($r.Url)|$($r.Method)"
    if (-not $seen.ContainsKey($key)) {
        $seen[$key] = $true
        $r
    }
}

# --- Bangun output (baris kosong sebagai pemisah antar kategori) ---
$outputLines     = New-Object System.Collections.Generic.List[string]
$currentCategory = $null
$firstItem       = $true

foreach ($r in $unique) {
    if (-not $firstItem -and $r.Category -ne $currentCategory) {
        $outputLines.Add("")
    }
    $outputLines.Add("$($r.Url) || $($r.Method)")
    $currentCategory = $r.Category
    $firstItem       = $false
}

# --- Output ---
if ($OutputPath) {
    $outputLines | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    Write-Host "OK: $($outputLines.Count) baris ditulis ke $OutputPath" -ForegroundColor Green
}
else {
    $outputLines | ForEach-Object { Write-Output $_ }
}
