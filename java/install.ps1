<#
.SYNOPSIS
    Install Anim Forge's engine patches into your Project Zomboid install.

.DESCRIPTION
    Copies the compiled patch classes from dist/ into the game folder, preserving their package paths
    (for example dist\zombie\ui\UI3DModel.class -> <install>\zombie\ui\UI3DModel.class). The game's
    classpath is ["." , "projectzomboid.jar"] with the working directory set to the install folder, so
    a loose .class on disk is loaded ahead of the copy inside the jar. The jar is never modified.

    This is additive and fully reversible: uninstall.ps1 deletes exactly the files this copied, which
    restores the stock behaviour (the game falls back to the jar).

    If dist/ is missing, run build.ps1 first (or use the prebuilt dist/ shipped with Anim Forge).
    Re-run this after a game update if you rebuild the patches.

.PARAMETER PzInstallDir
    Project Zomboid (Build 42) install root. Default: PZ_INSTALL_DIR env, common paths, Steam scan.

.EXAMPLE
    .\install.ps1
#>
param(
    [string]$PzInstallDir = $env:PZ_INSTALL_DIR
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_pzcommon.ps1"

$distDir = Join-Path $PSScriptRoot "dist"
if (-not (Test-Path $distDir)) {
    throw "dist\ not found. Run .\build.ps1 first (or restore the prebuilt dist\)."
}
$classes = Get-ChildItem -Recurse -Path $distDir -Filter "*.class"
if ($classes.Count -eq 0) { throw "dist\ has no .class files. Run .\build.ps1." }

$PzInstallDir = Resolve-PzInstall $PzInstallDir
Write-Host "Installing $($classes.Count) patch class(es) into:"
Write-Host "  $PzInstallDir" -ForegroundColor Cyan

$installed = 0
foreach ($c in $classes) {
    $rel = $c.FullName.Substring($distDir.Length).TrimStart('\', '/')
    $dst = Join-Path $PzInstallDir $rel
    New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
    Copy-Item -Force $c.FullName $dst
    $installed++
    Write-Host "  + $rel"
}

# A small manifest so uninstall.ps1 knows exactly what to remove, and re-runs are idempotent.
$manifest = @{
    installedAt  = (Get-Date).ToString("s")
    pzInstallDir = $PzInstallDir
    classes      = @($classes | ForEach-Object { $_.FullName.Substring($distDir.Length).TrimStart('\', '/') -replace '\\', '/' })
}
$manifestPath = Join-Path $PSScriptRoot "installed-manifest.json"
$manifest | ConvertTo-Json -Depth 4 | Out-File -Encoding utf8 $manifestPath

Write-Host ""
Write-Host "Done. Installed $installed class(es)." -ForegroundColor Green
Write-Host "Restart Project Zomboid (fully quit and relaunch) for the patch to take effect."
Write-Host "To revert: .\uninstall.ps1"
