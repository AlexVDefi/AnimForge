<#
.SYNOPSIS
    Compile Anim Forge's three engine shadow-class patches against the game jar.

.DESCRIPTION
    Anim Forge's in-game editor drives a handful of methods the base game does not expose to Lua
    (live per-bone pose overrides, a force-held preview clip, bone gizmo world positions, and a
    per-thumbnail forced clip for the animation browser). Those methods are added, additively, to
    three engine classes:

        zombie/core/skinnedmodel/animation/AnimationPlayer
        zombie/Lua/LuaManager                (one line: expose AnimationPlayer to Lua)
        zombie/ui/UI3DModel                  (browser thumbnails)

    This script compiles the patched sources in src/ against your Project Zomboid jar and writes the
    resulting .class files to dist/. install.ps1 then copies them into the game install, where they
    shadow the originals in projectzomboid.jar (the game's classpath is ["." , "projectzomboid.jar"],
    so a loose class on disk wins). Nothing here is Anim-Forge-specific tooling: it is plain javac.

    You only need to run this if you want to rebuild from source (for example after a game update that
    changes these classes). A prebuilt dist/ is shipped for the game version this was released against.

.PARAMETER PzInstallDir
    Project Zomboid (Build 42) install root - the folder that directly contains projectzomboid.jar.
    Default: the PZ_INSTALL_DIR env var, else common Steam paths, else a Steam library scan.

.PARAMETER JavacPath
    Full path to javac.exe from a JDK 21 or newer. Default: JAVAC_PATH env, JAVA_HOME\bin\javac.exe,
    a scan of common JDK dirs, then javac on PATH.

.EXAMPLE
    .\build.ps1
.EXAMPLE
    .\build.ps1 -PzInstallDir "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid"
#>
param(
    [string]$PzInstallDir = $env:PZ_INSTALL_DIR,
    [string]$JavacPath = $env:JAVAC_PATH
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_pzcommon.ps1"

# --- resolve javac (JDK 21+) ---------------------------------------------------------------------
function Resolve-Javac([string]$explicit) {
    if ($explicit -and (Test-Path $explicit)) { return $explicit }
    if ($env:JAVA_HOME) {
        $j = Join-Path $env:JAVA_HOME "bin\javac.exe"
        if (Test-Path $j) { return $j }
    }
    foreach ($base in @(
            "C:\Program Files\Java\jdk-25", "C:\Program Files\Java\jdk-24",
            "C:\Program Files\Java\jdk-23", "C:\Program Files\Java\jdk-22",
            "C:\Program Files\Java\jdk-21",
            "C:\Program Files\Microsoft\jdk-21",
            "C:\Program Files\Eclipse Adoptium\jdk-21",
            "C:\Program Files\Zulu\zulu-21")) {
        $j = Join-Path $base "bin\javac.exe"
        if (Test-Path $j) { return $j }
    }
    $cmd = Get-Command javac -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$PzInstallDir = Resolve-PzInstall $PzInstallDir
$javac = Resolve-Javac $JavacPath
$pzJar = Join-Path $PzInstallDir "projectzomboid.jar"
$srcDir = Join-Path $PSScriptRoot "src"
$outDir = Join-Path $PSScriptRoot "dist"

if (-not $javac)             { throw "javac not found. Install a JDK 21+ and set JAVA_HOME, or pass -JavacPath." }
if (-not (Test-Path $javac)) { throw "javac not found at $javac" }
if (-not (Test-Path $pzJar)) { throw "projectzomboid.jar not found at $pzJar  (pass -PzInstallDir or set PZ_INSTALL_DIR)" }
if (-not (Test-Path $srcDir)){ throw "src dir not found at $srcDir" }

if (Test-Path $outDir) { Remove-Item -Recurse -Force $outDir }
New-Item -ItemType Directory -Force $outDir | Out-Null

$sources = Get-ChildItem -Recurse -Path $srcDir -Filter "*.java" | ForEach-Object { $_.FullName }
Write-Host "Compiling $($sources.Count) source(s) against $pzJar"
Write-Host "  javac: $javac"

# --release 21 = the safe floor: the class files load on the game's bundled Java 21..25 runtimes.
$javacArgs = @("--release", "21", "-cp", $pzJar, "-d", $outDir) + $sources
& $javac @javacArgs
if ($LASTEXITCODE -ne 0) { throw "javac failed with exit code $LASTEXITCODE" }

$classes = Get-ChildItem -Recurse -Path $outDir -Filter "*.class"
Write-Host ""
Write-Host "OK: produced $($classes.Count) .class file(s) in dist\" -ForegroundColor Green
$classes | ForEach-Object { "  " + $_.FullName.Substring($outDir.Length + 1) }
Write-Host ""
Write-Host "Next: .\install.ps1   (copies these into the game install)"
