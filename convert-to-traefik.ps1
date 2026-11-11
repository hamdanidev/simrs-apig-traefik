<#
.SYNOPSIS
    Konversi list endpoint (URL || METHOD) menjadi blok YAML router Traefik.

.DESCRIPTION
    Membaca file teks berisi baris "URL || METHOD", lalu menghasilkan blok YAML
    dengan format:
        <nama>_<method>:
          rule: "PathPrefix(`<path>`) && (Method(`<METHOD>`) || Method(`OPTIONS`))"
          service: service-erm
          entryPoints:
            - web
          middlewares:
            - "simrs-cors"
            - "simrs-auth"

    Aturan transformasi path:
      - {{base_url_erm_v1}}  -> /v1.0
      - Segmen ":id" / param  dihapus dari nama, rule tetap diakhiri "/"
      - Segmen angka di akhir (mis. delete/20261109113600) juga diperlakukan
        sebagai parameter (dihapus, rule diakhiri "/")
      - Nama = segmen dipisah "_" + "_" + method huruf kecil

.PARAMETER Path
    File input list endpoint.

.PARAMETER OutputPath
    (Opsional) File output YAML. Jika tidak diisi, hasil tampil ke console.

.EXAMPLE
    .\convert-to-traefik.ps1 -Path '.\endpoints.txt'

.EXAMPLE
    .\convert-to-traefik.ps1 -Path '.\endpoints.txt' -OutputPath '.\traefik-routers.yml'
#>

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [Parameter(Position = 1)]
    [string]$OutputPath
)

# ---------- Konfigurasi tetap ----------
$BaseUrlToken = '{{base_url_erm_v1}}'
$TargetPrefix = '/v1.0'
$Service      = 'service-erm'
$EntryPoint   = 'web'
$Middlewares  = @('simrs-cors', 'simrs-auth')
$Indent       = '    '

# ---------- Validasi ----------
if (-not (Test-Path -LiteralPath $Path)) {
    throw "File tidak ditemukan: $Path"
}

$lines = Get-Content -LiteralPath $Path
$blocks = [System.Collections.Generic.List[string]]::new()
$seen   = [System.Collections.Generic.HashSet[string]]::new()

# ---------- Proses tiap baris ----------
foreach ($line in $lines) {
    $t = $line.Trim()
    if (-not $t) { continue }

    # Format: "<url> || <METHOD>"
    if ($t -notmatch '^(.+?)\s*\|\|\s*(\w+)\s*$') { continue }
    $url    = $Matches[1].Trim()
    $method = $Matches[2].ToUpper()

    # Ganti base token -> path
    $pathPart = $url -replace [regex]::Escape($BaseUrlToken), ''
    if (-not $pathPart.StartsWith('/')) { $pathPart = '/' + $pathPart }
    $pathPart = $pathPart.TrimEnd('/')

    $segments = @($pathPart.Split('/') | Where-Object { $_ -ne '' })

    # Buang segmen param (:id) dan segmen angka di akhir
    $kept     = @()
    $hadParam = $false
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $seg                = $segments[$i]
        $isParam            = $seg -match '^:'
        $isTrailingNumeric  = ($i -eq $segments.Count - 1) -and ($seg -match '^\d+$')
        if ($isParam -or $isTrailingNumeric) {
            $hadParam = $true
            continue
        }
        $kept += $seg
    }

    if ($kept.Count -eq 0) { continue }

    # Nama router
    $name = ($kept -join '_') + '_' + $method.ToLower()
    if (-not $seen.Add($name)) { continue }   # dedupe

    # Path rule
    $rulePath = $TargetPrefix + '/' + ($kept -join '/')
    if ($hadParam) { $rulePath += '/' }

    # Rule string (backtick tunggal sesuai format Traefik)
    $ruleStr = 'PathPrefix(`' + $rulePath + '`) && (Method(`' + $method + '`) || Method(`OPTIONS`))'

    # Susun blok YAML
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine($Indent + $name + ':')
    [void]$sb.AppendLine($Indent + '  rule: "' + $ruleStr + '"')
    [void]$sb.AppendLine($Indent + '  service: ' + $Service)
    [void]$sb.AppendLine($Indent + '  entryPoints:')
    [void]$sb.AppendLine($Indent + '    - ' + $EntryPoint)
    [void]$sb.AppendLine($Indent + '  middlewares:')
    foreach ($mw in $Middlewares) {
        [void]$sb.AppendLine($Indent + '    - "' + $mw + '"')
    }
    [void]$sb.AppendLine('')

    $blocks.Add($sb.ToString())
}

# ---------- Output ----------
$out = ($blocks -join "`r`n").TrimEnd()

if ($OutputPath) {
    Set-Content -LiteralPath $OutputPath -Value $out -Encoding UTF8
    Write-Host "OK: $($blocks.Count) router -> $OutputPath" -ForegroundColor Green
}
else {
    Write-Output $out
}
