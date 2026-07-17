<#
.SYNOPSIS
    One-shot Anim Forge setup: make the mod visible to Project Zomboid, install the engine patch,
    and scan your mods for the editor's optional tabs.

.DESCRIPTION
    Run this from the repo root. It performs the three install steps from the README:

      1. Links this folder into %USERPROFILE%\Zomboid\mods\AnimForge (a directory junction, so the
         game loads it and it stays in sync). Skipped if that path already exists.
      2. Installs the prebuilt engine patch into your Project Zomboid install (java\install.ps1).
      3. Runs the mod-discovery scan (needs Python) so the "Mods" and reload tabs populate.

    Each step is optional via a switch, and each is safe to re-run.

.PARAMETER PzInstallDir
    Project Zomboid install root (folder containing projectzomboid.jar). Auto-detected if omitted.

.PARAMETER SkipLink     Do not create the mods junction.
.PARAMETER SkipPatch    Do not install the engine patch.
.PARAMETER SkipScan     Do not run the mod scan.

.EXAMPLE
    .\Setup.ps1
#>
param(
    [string]$PzInstallDir = $env:PZ_INSTALL_DIR,
    [switch]$SkipLink,
    [switch]$SkipPatch,
    [switch]$SkipScan
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

Write-Host "=== Anim Forge setup ===" -ForegroundColor Cyan

# --- 1. link the mod into the Zomboid mods folder ------------------------------------------------
if (-not $SkipLink) {
    $modsDir = Join-Path $env:USERPROFILE "Zomboid\mods"
    $link = Join-Path $modsDir "AnimForge"
    if (Test-Path $link) {
        Write-Host "[1/3] Mod already present at $link - leaving it."
    } else {
        New-Item -ItemType Directory -Force $modsDir | Out-Null
        try {
            New-Item -ItemType Junction -Path $link -Target $root -ErrorAction Stop | Out-Null
            Write-Host "[1/3] Linked mod: $link -> $root" -ForegroundColor Green
        } catch {
            Write-Warning "[1/3] Could not create a junction ($($_.Exception.Message))."
            Write-Warning "      Copy this folder to $link manually instead."
        }
    }
} else {
    Write-Host "[1/3] Skipped mod link."
}

# --- 2. install the engine patch -----------------------------------------------------------------
if (-not $SkipPatch) {
    Write-Host "[2/3] Installing engine patch..."
    $installArgs = @{}
    if ($PzInstallDir) { $installArgs["PzInstallDir"] = $PzInstallDir }
    & (Join-Path $root "java\install.ps1") @installArgs
} else {
    Write-Host "[2/3] Skipped engine patch."
}

# --- 3. scan installed mods ----------------------------------------------------------------------
if (-not $SkipScan) {
    $py = Get-Command python -ErrorAction SilentlyContinue
    if ($py) {
        Write-Host "[3/3] Scanning installed mods for the editor's Mods / reload tabs..."
        & $py.Source (Join-Path $root "tools\pz-anim-forge\cli.py") scan | Out-Host
    } else {
        Write-Warning "[3/3] Python not found on PATH - skipping the scan."
        Write-Warning "      Install Python 3 and run: python tools\pz-anim-forge\cli.py scan"
    }
} else {
    Write-Host "[3/3] Skipped mod scan."
}

Write-Host ""
Write-Host "Done. Fully quit and relaunch Project Zomboid, enable 'Anim Forge' in the Mods menu," -ForegroundColor Green
Write-Host "load a save, and press Home to open the editor." -ForegroundColor Green
