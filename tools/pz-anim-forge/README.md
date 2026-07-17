# pz-anim-forge

The command-line half of Anim Forge. It turns the in-game editor's saved changes into game-ready
Project Zomboid animation files, and edits vanilla `.x` clips directly (rotate individual bones and
ship them straight back as `.x`). It also scans your installed mods so the editor's **Mods** and
**Edit reload attachments** tabs know what exists.

This tool is bundled inside the Anim Forge mod; you normally invoke it from the editor's Export/Save
buttons (via the watcher below), but every command also runs by hand.

## The key idea: keep it as `.x`

PZ loads a `.x` animation through the engine's native `loadX` path, which applies only
`MAKE_LEFT_HANDED` — not the coordinate convention the `.glb`/`.fbx` paths bake in (a 0.01 scale plus
a -90 degree X bone rotation). So if you keep an animation as `.x` and edit only a bone's rotation
keyframes, the engine loads your file byte-for-byte the way it loads the vanilla clip, plus your
nudge. No round-trip through glb, no orientation drift, nothing to compensate for. This is what makes
the tool simple and correct.

(The old `.x` -> `.glb` -> Blender -> `.glb` route never matched vanilla in-game and is abandoned.
`assimp` survives only as a `.x` -> `.glb` **viewer** for the `preview` command.)

## Requirements

- Python 3. No third-party packages for `edit` / `batch` / `bake*` / `wire*` / `scan`.
- A Project Zomboid Build 42 install (auto-detected, or pass `--pz-install`).
- `preview` only: the `assimp` runtime DLL (set `PZAF_ASSIMP_DLL`). Not needed for anything else.

## The channel dir

The in-game editor reads and writes `%USERPROFILE%\Zomboid\Lua\AnimForge\` (its "channel dir"):
its saves (`anim_edit.json`), a live-reload request/result pair, and the discovery caches
(`mod_clips.json`, `reload_markers.json`). The commands below default to that dir; override with
`--channel-dir` or the `PZ_CHANNEL_DIR` env var.

## Common commands

**Scan your mods** (refresh the editor's Mods / reload tabs):

```
python cli.py scan
# also scan a mod you are developing outside ~/Zomboid/mods:
python cli.py scan --mod-root "C:\path\to\MyGunMod"
```

**Live watcher** (leave running while you edit; auto-bakes EVERY save type - grip sets, reload markers,
emotes, Gunworks packs, mod-glb edits - and hot-reloads reload edits live):

```
python cli.py watch                    # or double-click watch.bat
```

**Edit one vanilla clip's bone directly:**

```
python cli.py edit \
  --src "<PZ>/media/anims_X/Bob/Bob_IdleAimHandgun.x" \
  --dst "<MyGunMod>/common/media/anims_X/Bob/Bob_IdleAimHandgun.x" \
  --bone Bip01_R_Hand --euler 0,4,-2
```

`--euler` is degrees about the bone's local X,Y,Z (`--order`, default `XYZ`; `--mode post` rotates in
the bone's frame after its current rotation, `pre` before). Every AnimationSet is edited unless you
pass `--set NAME`.

**Bake the editor's saved grip set into a per-gun animation set** (renamed clips, vanilla untouched)
and wire the gun to use them:

```
python cli.py bake-set --json "%USERPROFILE%\Zomboid\Lua\AnimForge\anim_edit.json" --mod-root <MyGunMod>
python cli.py wire-set --json "%USERPROFILE%\Zomboid\Lua\AnimForge\anim_edit.json" --mod-root <MyGunMod>
```

`bake-set` writes `<prefix>_<clip>.x` into `common/media/anims_X/Bob/`. `wire-set` writes a
self-contained (flattened, no `x_extends`) gated AnimSet clone under `42/media/AnimSets/player/<state>/`
plus a client Lua hook, so only your gun uses the edited clips. The gun is identified by item tag
(`--tag`, default `<prefixlower>anims`) and/or explicit `--fulltypes`.

Other export flavors from the editor: `wire-gunworks` (a full Gunworks reload pack), `wire-emote` (a
one-frame emote), `reload-markers` / `bake-editor` (retime a reload node's attachment markers).

**Preview a delta without booting the game:**

```
python cli.py edit --src vanilla.x --dst test.x --bone Bip01_R_Hand --euler 0,8,0
python cli.py preview --src test.x --out-glb test.glb
```

Run `python cli.py -h` for the full list.

## Two ways to ship an edit

- **Override (simplest).** Output a `.x` under the SAME name as the vanilla clip (omit the rename).
  The mod file replaces vanilla globally for that animation — no AnimSet XML needed.
- **Per-gun.** Output under a NEW name (`bake-set` + `wire-set`) so only your gun uses it. The tool
  renames the AnimationSet, clones the gating nodes, and emits the Lua that flips the anim variable
  while the gun is held.

## Skeleton contract

Channels match the player skeleton by exact bone name. Root is `Dummy01`; biped bones are `Bip01_*`
(e.g. `Bip01_R_UpperArm`, `Bip01_R_Forearm`, `Bip01_R_Hand`); `Translation_Data` carries root motion.
`Dummy01` and `Translation_Data` are protected and the editor refuses to delta them. Editing a bone
rotates it and its children (FK); counter-rotate a child if you need, e.g., fingers held fixed.

## Layout

```
cli.py             entry point: edit | batch | bake | bake-set | wire-set | wire-gunworks |
                   wire-emote | reload-markers | bake-editor | bake-request | watch | scan |
                   preview | edit-glb | bake-glb
pzanimforge/
  x_edit.py        the editor core: bone-delta + set-rename text surgery on .x
  watcher.py       the unified auto-baker: routes each save type to its bake (what watch.bat runs)
  scan.py          scan installed mods -> mod_clips.json + reload_markers.json
  bake_request.py  reload-attachment bake + live-reload nudge (shared by the watcher)
  reload_markers.py  surgical <m_Events> retiming
  wireset.py / wire.py / flatten.py   gated AnimSet clone generation (per-gun)
  gunworks.py / emote.py              the Gunworks-reload and emote export routes
  manifest.py / paths.py             manifest loading, install/dir resolution
  glb_edit.py / assimp_ingest.py     the (obsolete) glb edit route + the preview viewer
config/            example manifest + cached bone list
gen_categories.py  regenerate the editor's AnimCategories.lua from the vanilla clips (after a game update)
watch.bat          double-click launcher for the unified live auto-baker (every save type)
```

## After a game update

If the editor's clip list looks stale, regenerate the category map:

```
python gen_categories.py
```

It scans `<PZ>/media/anims_X/Bob` and rewrites the mod's `AnimForge/AnimCategories.lua`.
