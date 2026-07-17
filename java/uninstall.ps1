<#
.SYNOPSIS
    Remove Anim Forge's engine patches from your Project Zomboid install.

.DESCRIPTION
    Deletes exactly the loose .class files install.ps1 copied in, so the game falls back to the stock
    classes inside projectzomboid.jar (which this never touched). Uses installed-manifest.json when
    present; otherwise it derives the file list from dist/. Empty package folders it created are pruned.

.PARAMETER PzInstallDir
    Project Zomboid install root. Default: the manifest's recorded path, then PZ_INSTALL_DIR / Steam scan.

.EXAMPLE
    .\uninstall.ps1
#>
param(
    [string]$PzInstallDir = $env:PZ_INSTALL_DIR
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_pzcommon.ps1"

$manifestPath = Join-Path $PSScriptRoot "installed-manifest.json"
$relClasses = @()
if (Test-Path $manifestPath) {
    $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $relClasses = @($m.classes)
    if (-not $PzInstallDir -and $m.pzInstallDir) { $PzInstallDir = $m.pzInstallDir }
} else {
    $distDir = Join-Path $PSScriptRoot "dist"
    if (-not (Test-Path $distDir)) { throw "No installed-manifest.json and no dist\ to derive the file list from." }
    $relClasses = @(Get-ChildItem -Recurse -Path $distDir -Filter "*.class" |
        ForEach-Object { $_.FullName.Substring($distDir.Length).TrimStart('\', '/') -replace '\\', '/' })
}

if (-not (Test-PzInstall $PzInstallDir)) { $PzInstallDir = Resolve-PzInstall $PzInstallDir }
Write-Host "Removing $($relClasses.Count) patch class(es) from:"
Write-Host "  $PzInstallDir" -ForegroundColor Cyan

$removed = 0
$dirs = New-Object System.Collections.Generic.HashSet[string]
foreach ($rel in $relClasses) {
    $dst = Join-Path $PzInstallDir ($rel -replace '/', '\')
    if (Test-Path $dst) {
        Remove-Item -Force $dst
        $removed++
        Write-Host "  - $rel"
        [void]$dirs.Add((Split-Path $dst -Parent))
    }
}
# Prune package folders we may have created, only if now empty, walking upward toward the install root.
foreach ($d in $dirs) {
    $cur = $d
    while ($cur -and ($cur.Length -gt $PzInstallDir.Length) -and (Test-Path $cur) -and
           -not (Get-ChildItem -Force $cur -ErrorAction SilentlyContinue)) {
        Remove-Item -Force $cur
        $cur = Split-Path $cur -Parent
    }
}
if (Test-Path $manifestPath) { Remove-Item -Force $manifestPath }

Write-Host ""
Write-Host "Done. Removed $removed class(es). Restart Project Zomboid to run stock." -ForegroundColor Green
