@echo off
REM ============================================================================
REM  Anim Forge auto-baker - ONE watcher for every save type.
REM
REM  Double-click this, then leave the window open while you edit. Every time you
REM  Save or Export in the in-game editor it bakes into your mod automatically:
REM    - grip "Export set"      -> renamed .x clips + gated AnimSet XML + Lua hook
REM    - reload attachments     -> retimes the reload XML and hot-reloads it LIVE
REM    - emote / Gunworks reload -> the matching pack, into your mod
REM    - mod .glb clip edit     -> rewrites the bone keys in place
REM  Close the window (or Ctrl+C) to stop.
REM
REM  Pure file work: no network, no other tools. It only touches the channel dir,
REM  your mod's own files, and (for the live reload) the game's AnimSets/Defaults.xml.
REM ============================================================================
title Anim Forge Auto-Bake  (leave open while editing)
cd /d "%~dp0"

where python >nul 2>nul
if errorlevel 1 (
  echo [!] Python 3 was not found on your PATH.
  echo     Install Python 3, or edit this file to point at your python.exe.
  echo.
  pause
  exit /b 1
)

python cli.py watch
echo.
echo (watcher stopped)
pause
