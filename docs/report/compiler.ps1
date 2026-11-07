# Compile le rapport en convertissant temporairement les SVG de docs/diagrams en PDF.
#
# 1. Chaque docs/diagrams/*.svg est converti en PDF vectoriel (Chrome ou Edge en mode headless).
# 2. Le rapport est compile avec latexmk ; la macro \diagramme utilise alors les PDF.
# 3. Les PDF temporaires sont supprimes, meme si la compilation echoue.
#
# Utilisation (depuis n'importe quel dossier) :
#   powershell -ExecutionPolicy Bypass -File docs\report\compiler.ps1
# Options :
#   -Garder   conserve les PDF des diagrammes apres la compilation

param([switch]$Garder)

$ErrorActionPreference = 'Stop'
$rapportDir  = $PSScriptRoot
$diagrammes  = Join-Path $rapportDir '..\diagrams' | Resolve-Path | Select-Object -ExpandProperty Path

# --- Navigateur headless (Chrome, sinon Edge) ---
$navigateur = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $navigateur) { throw "Ni Chrome ni Edge n'a ete trouve : impossible de convertir les SVG." }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("svg2pdf_" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
$pdfCrees = @()

try {
    # --- 1. Conversion SVG -> PDF ---
    foreach ($svg in Get-ChildItem -Path $diagrammes -Filter *.svg) {
        $pdf = [IO.Path]::ChangeExtension($svg.FullName, '.pdf')
        if (Test-Path $pdf) { Write-Host "  (deja present, conserve) $($svg.BaseName).pdf"; continue }

        # Dimensions : attributs width/height de la balise <svg>, sinon le viewBox
        $entete = [regex]::Match((Get-Content -Raw $svg.FullName), '<svg\b[^>]*>').Value
        $w = [regex]::Match($entete, '\bwidth="([\d.]+)').Groups[1].Value
        $h = [regex]::Match($entete, '\bheight="([\d.]+)').Groups[1].Value
        if (-not $w -or -not $h) {
            $vb = [regex]::Match($entete, 'viewBox="[\d.\-]+[\s,]+[\d.\-]+[\s,]+([\d.]+)[\s,]+([\d.]+)"')
            $w = $vb.Groups[1].Value; $h = $vb.Groups[2].Value
        }
        if (-not $w -or -not $h) { throw "Dimensions introuvables dans $($svg.Name)" }

        $url  = ([Uri]$svg.FullName).AbsoluteUri
        $html = Join-Path $tmp "$($svg.BaseName).html"
        Set-Content -Path $html -Encoding UTF8 -Value @"
<!doctype html><html><head><meta charset="utf-8"><style>
@page { size: ${w}px ${h}px; margin: 0 }
html, body { margin: 0; padding: 0 }
img { display: block; width: ${w}px; height: ${h}px }
</style></head><body><img src="$url"></body></html>
"@
        $arguments = @('--headless', '--disable-gpu', '--allow-file-access-from-files',
                       '--no-pdf-header-footer', "--user-data-dir=`"$tmp\profil`"",
                       "--print-to-pdf=`"$pdf`"", "`"$(([Uri]$html).AbsoluteUri)`"")
        Start-Process -FilePath $navigateur -ArgumentList $arguments -Wait -WindowStyle Hidden
        if (-not (Test-Path $pdf)) { throw "Echec de la conversion de $($svg.Name)" }
        $pdfCrees += $pdf
        Write-Host "  SVG -> PDF : $($svg.BaseName)"
    }

    # --- 2. Compilation ---
    Push-Location $rapportDir
    try {
        latexmk -pdf -interaction=nonstopmode -synctex=1 rapport.tex
        $code = $LASTEXITCODE
    } finally { Pop-Location }
}
finally {
    # --- 3. Nettoyage ---
    if (-not $Garder) {
        foreach ($pdf in $pdfCrees) { Remove-Item -Force -ErrorAction SilentlyContinue $pdf }
        if ($pdfCrees) { Write-Host "  PDF temporaires des diagrammes supprimes." }
    }
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
}

if ($code -ne 0) { Write-Host "La compilation a echoue (code $code), voir rapport.log." -ForegroundColor Red }
else             { Write-Host "Rapport compile : $(Join-Path $rapportDir 'rapport.pdf')" -ForegroundColor Green }
exit $code
