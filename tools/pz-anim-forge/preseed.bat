@echo off
REM ============================================================================
REM  Anim Forge PRE-SEED - run this ONCE before you launch the game.
REM
REM  PZ only indexes a mod's files at BOOT. A reload node you export in-game AFTER
REM  boot is unknown to the engine's file index, so it can't load until the next
REM  restart. This writes tiny STUB nodes + clips into your mod so the paths exist
REM  at boot; then the in-game "Export reload pack" overwrites the stubs and the
REM  reload goes LIVE with no restart.
REM
REM  EDIT the two lines below for your mod, then double-click. Re-run whenever you
REM  plan a new reload animId. Safe to re-run - it never clobbers a real reload
REM  (only creates missing stubs / refreshes its own).
REM ============================================================================
title Anim Forge Pre-Seed
cd /d "%~dp0"

REM --- EDIT THESE ---------------------------------------------------------------
REM  MOD_ROOT : your gun mod (the junction under Zomboid\mods works too).
REM  RELOADS  : how to choose which reloads to stub. Pick ONE:
REM     --all-guns                          auto-discover EVERY gun in the mod (easiest)
REM     --reload <animId>:<archetype> ...   one per reload, e.g. --reload M4:magazine
REM               archetypes: magazine | magazinehandgun | shotgun | revolver |
REM                           boltactionnomag | doublebarrel | lever
REM  Tip: name each in-game reload set to match the stub animId (--all-guns names
REM  them <MODULE><ITEM>, e.g. an item MyMod.M4CARBINE becomes MyModM4) so the
REM  in-game Export goes live with no restart.
set "MOD_ROOT=%USERPROFILE%\Zomboid\mods\MyGunMod"
set "RELOADS=--all-guns"
REM ------------------------------------------------------------------------------

where python >nul 2>nul
if errorlevel 1 (
  echo [!] Python 3 was not found on your PATH.
  echo     Install Python 3, or edit this file to point at your python.exe.
  echo.
  pause
  exit /b 1
)

python cli.py preseed --mod-root "%MOD_ROOT%" %RELOADS%
echo.
echo (pre-seed done - now launch the game, then Export your reload as usual)
pause
