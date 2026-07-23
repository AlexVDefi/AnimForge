# Anim Forge engine patches

The in-game editor needs a few engine methods the base game does not expose to Lua. These are added,
additively, to three classes and shipped as **loose class files** that shadow the copies inside
`projectzomboid.jar` (the game loads `.` before the jar on its classpath). The jar is never modified.

| Class | What Anim Forge adds |
|---|---|
| `zombie/core/skinnedmodel/animation/AnimationPlayer` | Live per-bone rotation/translation overrides, a force-held preview clip with play/pause/scrub, and bone gizmo world positions for the on-screen handles. |
| `zombie/Lua/LuaManager` | **One line** in `Exposer.exposeAll()` that exposes `AnimationPlayer` to Lua, so `getAnimationPlayer():...` methods are callable. |
| `zombie/ui/UI3DModel` | A per-widget "forced clip" so the animation browser can freeze each thumbnail model on one clip. |

All three are the game's own decompiled classes with these additions layered on top; nothing else is
changed. `AnimationPlayer` and `UI3DModel` are byte-for-byte vanilla plus the additive blocks;
`LuaManager` is vanilla plus the single exposure line.

## Install (most people)

A prebuilt `dist/` is included, compiled for the Project Zomboid build Anim Forge was released against.

```powershell
# from this java\ folder, in PowerShell:
.\install.ps1
```

Then fully quit and relaunch Project Zomboid. That's it.

`install.ps1` finds your install automatically (Steam registry + library scan); pass
`-PzInstallDir "<path to the folder with projectzomboid.jar>"` if it can't.

To revert to the stock game:

```powershell
.\uninstall.ps1
```

## Rebuild from source (only if the game updated)

A game update can change these engine classes, which makes the prebuilt `dist/` stale. If the editor's
live posing or browser thumbnails stop working after an update, the classes need rebuilding.

The patched **sources are not redistributed** - they are the game's own decompiled classes, which are
The Indie Stone's copyright. To rebuild, supply your own: decompile the three classes above from your
`projectzomboid.jar`, re-apply the additive blocks (they are small and self-contained - the
AnimationPlayer / UI3DModel additions and LuaManager's single exposure line), drop the results under
`src\`, then:

```powershell
.\build.ps1      # compiles src\ against your projectzomboid.jar -> dist\
.\install.ps1    # copies the fresh classes in
```

`build.ps1` needs a **JDK 21 or newer** (it targets `--release 21`, the safe floor for the game's
bundled Java 21-25 runtime). It finds `javac` via `JAVA_HOME` or a scan of common JDK folders; pass
`-JavacPath "<...>\bin\javac.exe"` to point it explicitly.

## How it works / safety

- The game's `ProjectZomboid64.json` classpath is `[".", "projectzomboid.jar"]` and it runs with the
  install folder as the working directory, so a class at `<install>\zombie\...\Foo.class` is loaded
  in preference to the one inside the jar. That is the entire mechanism.
- Installing only *adds* files; uninstalling *removes exactly those files* (tracked in
  `installed-manifest.json`) and the game falls back to the jar. Nothing is overwritten in place, so
  there is no backup to keep and nothing to corrupt.
- These are single-player client-side patches for editing animations. They are not needed on a server
  and have no gameplay effect unless the editor calls them.

## Files

```
dist/    prebuilt .class files (committed; this is what install.ps1 uses)
src/     the three patched engine sources - NOT redistributed (game copyright); supply your own to rebuild
build.ps1        compile src -> dist
install.ps1      copy dist into the game install (auto-detected)
uninstall.ps1    remove them again
_pzcommon.ps1    shared install-locator (dot-sourced by the above)
```
