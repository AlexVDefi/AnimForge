<#
    Shared helper: locate a Project Zomboid (Build 42) install, read-only.
    Dot-sourced by build.ps1 / install.ps1 / uninstall.ps1.

    Resolution order: an explicit path argument, then the PZ_INSTALL_DIR env var, then common Steam
    locations, then a scan of every Steam library listed in libraryfolders.vdf. An install is only
    accepted if projectzomboid.jar sits directly inside it.
#>

function Test-PzInstall([string]$dir) {
    return $dir -and (Test-Path (Join-Path $dir "projectzomboid.jar"))
}

function Get-SteamLibraries {
    $roots = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string]
    function Add-Root([string]$p) {
        if ($p -and (Test-Path $p) -and $seen.Add($p)) { $roots.Add($p) }
    }
    $steam = $null
    try {
        $k = Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue
        if ($k -and $k.SteamPath) { $steam = $k.SteamPath }
    } catch {}
    if (-not $steam) {
        try {
            $k = Get-ItemProperty -Path "HKLM:\Software\WOW6432Node\Valve\Steam" -ErrorAction SilentlyContinue
            if ($k -and $k.InstallPath) { $steam = $k.InstallPath }
        } catch {}
    }
    foreach ($p in @($steam, "C:\Program Files (x86)\Steam", "C:\Program Files\Steam")) { Add-Root $p }
    foreach ($base in @($roots.ToArray())) {
        $vdf = Join-Path $base "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($m in ([regex]'"path"\s*"([^"]+)"').Matches((Get-Content $vdf -Raw))) {
                Add-Root ($m.Groups[1].Value -replace '\\\\', '\')
            }
        }
    }
    return $roots
}

function Resolve-PzInstall([string]$explicit) {
    if (Test-PzInstall $explicit) { return (Resolve-Path $explicit).Path }
    if (Test-PzInstall $env:PZ_INSTALL_DIR) { return (Resolve-Path $env:PZ_INSTALL_DIR).Path }
    foreach ($c in @(
            "D:\Games\Steam\steamapps\common\ProjectZomboid",
            "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid",
            "C:\Program Files\Steam\steamapps\common\ProjectZomboid")) {
        if (Test-PzInstall $c) { return $c }
    }
    foreach ($lib in Get-SteamLibraries) {
        $cand = Join-Path $lib "steamapps\common\ProjectZomboid"
        if (Test-PzInstall $cand) { return $cand }
    }
    throw "Could not find a Project Zomboid install (projectzomboid.jar). Pass -PzInstallDir or set PZ_INSTALL_DIR."
}
