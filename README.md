# Anim Forge

An in-game animation editor for **Project Zomboid (Build 42)**. Pose character bones live with
on-screen gizmos, retime the attachment markers on weapon reload animations, and export/bake custom
animations into game-ready files — all from inside the game.

Anim Forge is fully standalone: the in-game mod, the engine patch it needs, and the command-line
baking tool are all included in this one package.

- **Open it in-game** with the **Toggle Anim Forge** keybind (default **Home**), rebindable under
  Options > Key Bindings.

---

## What it does

- **Live posing.** Force-holds any animation clip on your character and lets you rotate/translate its
  bones with click-and-drag gizmos (the same rings/arrows style as the game's own attachment editor).
  The equipped/preview weapon rides on the hand, so you can dial a grip against the actual gun.
- **Keyframe timeline.** Play / pause / scrub the held clip, drop keyframes per bone, and preview the
  interpolation live.
- **Animation browser.** A searchable grid of live 3D thumbnails of every vanilla clip (and your mod
  clips), grouped by weapon and theme; click one to load it into the editor.
- **Reload attachment editor.** Retime the `gwSetProp` / `gwPartToHand` / `gwPartToGun` markers on a
  Gunworks-style reload (which prop attaches to which hand, and when) on a color-coded timeline, with
  live preview.
- **Export + bake.** Save the dialed changes and the bundled `pz-anim-forge` tool turns them into
  game-ready `.x` animations, gated AnimSet XML, and the small Lua hook that makes one gun use them —
  optionally with a save → bake → live-reload loop that needs no game restart.

---

## Requirements

- Project Zomboid, **Build 42**.
- **Windows** (the install/build scripts are PowerShell; the game patch mechanism is Windows-oriented).
- **Python 3** on your PATH — only for the baking tool and the mod-discovery scanner (not for the
  editor UI itself).
- A **JDK 21+** — only if you ever need to *rebuild* the engine patch after a game update (a prebuilt
  patch is included, so you do not need a JDK for normal use).

---

## Install (three steps)

### 1. Install the mod

Put this whole folder where Project Zomboid can see it, as `AnimForge` under your Zomboid `mods`
folder — i.e. `%USERPROFILE%\Zomboid\mods\AnimForge\` (so the game finds
`...\mods\AnimForge\42\mod.info`). Copying the folder there works; a directory junction works too and
keeps it in sync if you are developing it.

The bundled **`Setup.ps1`** does this for you (plus steps 2 and 3) — see "One-shot setup" below.

Then launch the game and enable **Anim Forge** in the Mods menu.

### 2. Install the engine patch (one time)

The editor drives a few engine methods the base game does not expose to Lua. Those are shipped as
prebuilt shadow classes; install them with:

```powershell
cd java
.\install.ps1
```

Then fully quit and relaunch the game. This is additive and reversible (`java\uninstall.ps1` reverts
it). Details and the rebuild-from-source path are in [java/README.md](java/README.md). **Without this
step the editor opens but live posing and the browser thumbnails will not work.**

### 3. (Optional) Scan your mods for the extra tabs

The editor's **Mods** tab and **Edit reload attachments** picker read a small cache of what is
installed. Generate it any time you add or change a mod:

```powershell
python tools\pz-anim-forge\cli.py scan
```

This only reads your mods and writes two small JSON files into the editor's channel dir
(`%USERPROFILE%\Zomboid\Lua\AnimForge\`). Skip it if you only edit vanilla clips.

### One-shot setup

From the repo root, this does all three (junction the mod, install the patch, run the scan):

```powershell
.\Setup.ps1
```

Restart the game afterwards and enable the mod.

---

## Using the editor

1. Load a save (the editor works on your in-world character).
2. Press **Home** to open Anim Forge.
3. **Browse…** to pick a clip, or use the weapon/clip controls; the character freezes on it.
4. Click a bone node on the character (or pick from the panel) and drag the gizmo to pose it. **R**
   toggles rotate/translate handles; **Space** plays/pauses the clip.
5. Drop keyframes as you scrub to build motion; the scrub bar shows the keyframe ticks.
6. **Export / Save Set** writes the change out. Then build it into the mod:
   - Easiest: double-click **`tools\pz-anim-forge\watch.bat`** and leave it open. It auto-bakes every
     save type into your mod the moment you Save/Export — grip sets, emotes, Gunworks reload packs,
     mod-glb edits, and reload-attachment edits (those hot-reload live, no restart).
   - Or run the matching `pz-anim-forge` command by hand (see
     [tools/pz-anim-forge/README.md](tools/pz-anim-forge/README.md)).

Full keyboard shortcuts are listed in the editor's own on-screen legend.

---

## Uninstall

- **Engine patch:** `cd java; .\uninstall.ps1` (restores the stock game).
- **Mod:** remove/disable `AnimForge` from your Zomboid `mods` folder.

---

## Troubleshooting

- **The editor opens but the character does not move / thumbnails are blank.** The engine patch is not
  installed (or a game update made it stale). Run `java\install.ps1` and restart the game; if the game
  updated, rebuild first with `java\build.ps1` (see [java/README.md](java/README.md)).
- **The "Mods" or "Edit reload attachments" tab is empty.** Run `python tools\pz-anim-forge\cli.py
  scan`, then reopen the tab.
- **A baked change does not show up.** Make sure the watcher (`watch.bat`) is running, or run the bake
  command yourself; some changes need a game restart (the editor's toast says which).
- **Boot stalls after adding the mod.** Never place a junction or symlink inside a mod's
  `media/anims_X` folder — the engine scans it recursively and will hang. Anim Forge ships no
  `anims_X` of its own, so this only applies to the gun mods you build with it.

---

## Layout

```
42/                     the in-game mod (Build 42 layout; this is what PZ loads)
  mod.info
  media/lua/client/AnimForge/   the editor (AnimEditor, AnimProjects, AnimCategories, theme, widgets)
  media/lua/shared/AnimForge/   JSON helper
java/                   the engine patch: sources, prebuilt classes, build/install/uninstall scripts
tools/pz-anim-forge/    the command-line baking tool + the mod-discovery scanner + the live watcher
Setup.ps1               one-shot: junction the mod, install the patch, run the scan
```

## How it works (short version)

The editor writes its dialed changes to `%USERPROFILE%\Zomboid\Lua\AnimForge\`. The `pz-anim-forge`
tool reads those and edits Project Zomboid `.x` animations directly (keeping them as `.x` so they load
byte-for-byte the way the game loads a vanilla clip — no coordinate-convention drift), plus generates
the AnimSet XML + Lua that makes a specific gun use them. The engine patch is three of the game's own
classes with a handful of additive methods, loaded as loose classes that shadow the jar. Nothing is
overwritten in place and every step is reversible.
