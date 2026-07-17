"""pz-anim-forge command line.

Edit Project Zomboid vanilla .x character animations by rotating individual
bones, and ship them straight back as .x. The engine loads a mod .x through the
native loadX path - identical to how it loads the vanilla clip - so the edit
plays with zero coordinate-convention drift (no glb +90X / 0.01-scale dance).
Verified in-game 2026-06-11.

Subcommands:
  edit      one clip:  --src vanilla.x --dst out.x --bone B --euler x,y,z
                       [--set NAME | (default: every set)] [--mode post|pre]
                       [--order XYZ] [--rename-set NEW]
  batch     a manifest: --manifest config/jobs.handgun.json [--wire]
  bake      bake the in-game editor's saved deltas -> one new .x
  bake-set  bake the editor's deltas across a CLIP SET -> separate renamed .x
            in a mod (the per-gun route's animations)
  wire-set  generate the gated AnimSet XML clones + Lua hook that make a gun
            USE the bake-set output (held-pose nodes, flattened, tag/fullType-gated)
  preview   .x -> .glb for VIEWING only (assimp), to eyeball a delta without
            booting the game:  --src some.x --out-glb preview.glb

The glb export route (assimp + Blender surgery) is obsolete - it never matched
vanilla in-game. assimp survives only for `preview`.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pzanimforge import bake_request as brmod  # noqa: E402
from pzanimforge import emote as emotemod  # noqa: E402
from pzanimforge import glb_edit  # noqa: E402
from pzanimforge import gunworks as gwmod  # noqa: E402
from pzanimforge import reload_markers as rmmod  # noqa: E402
from pzanimforge import manifest as mf  # noqa: E402
from pzanimforge import paths  # noqa: E402
from pzanimforge import prop_fix as pfmod  # noqa: E402
from pzanimforge import scan as scanmod  # noqa: E402
from pzanimforge import wire as wiremod  # noqa: E402
from pzanimforge import wireset as wsmod  # noqa: E402
from pzanimforge import x_edit  # noqa: E402


def _euler(s):
    v = [float(x) for x in (s or "0,0,0").split(",")]
    if len(v) != 3:
        raise SystemExit("--euler needs three comma-separated degrees")
    return v


def cmd_edit(args):
    os.makedirs(os.path.dirname(os.path.abspath(args.dst)) or ".", exist_ok=True)
    r = x_edit.edit_file(
        os.path.abspath(args.src), os.path.abspath(args.dst),
        args.bone, _euler(args.euler), order=args.order,
        anim_set=args.anim_set, mode=args.mode, rename_to=args.rename_to,
    )
    print(json.dumps({"ok": True, "results": [r]}, indent=2))
    return 0


def cmd_edit_glb(args):
    """Rotate one bone in one mod .glb, with the -90X convention compensation so the
    author's game-space delta reproduces in-game for any axis."""
    r = glb_edit.edit_glb(
        os.path.abspath(args.src), os.path.abspath(args.dst),
        {args.bone: _euler(args.euler)}, order=args.order, mode=args.mode,
        do_compensate=not args.no_compensate, clip=args.clip,
    )
    print(json.dumps(r, indent=2))
    return 0


def cmd_bake_glb(args):
    """Bake the in-game editor's saved per-bone deltas into a mod .glb (same or new file).

    Reads the editor save {clip, deltas, order, mode}; the deltas are euler degrees in the
    author's game/local space. Each is compensated (C = R.D.R^-1) so it survives the engine's
    glTF -90X conjugation. --src is the mod's source .glb; --dst==--src edits in place.
    """
    with open(args.json, "r", encoding="utf-8") as fh:
        spec = json.load(fh)
    order = args.order or spec.get("order", "XYZ")
    mode = args.mode or spec.get("mode", "post")
    clip = args.clip or spec.get("clip")
    r = glb_edit.edit_glb(
        os.path.abspath(args.src), os.path.abspath(args.dst),
        spec.get("deltas", {}), order=order, mode=mode,
        do_compensate=not args.no_compensate, clip=clip,
    )
    print(json.dumps(r, indent=2))
    return 0


def cmd_reload_markers(args):
    """Rewrite a reload node's gw attachment markers (gwSetProp/gwPartToHand/gwPartToGun) in place.

    Reads the in-game editor save {output:{nodeFile, markers:[{event,timePc,value}]}}; the surgical
    edit preserves the loadFinished/playReloadSound preamble and node conditions. --src/--dst override
    the save's nodeFile (dst == src edits in place).
    """
    with open(args.json, "r", encoding="utf-8") as fh:
        spec = json.load(fh)
    out = spec.get("output") or {}
    src = args.src or out.get("nodeFile")
    if not src:
        raise SystemExit("no node file (pass --src or save an output.nodeFile from the editor)")
    dst = args.dst or out.get("dst") or src
    markers = out.get("markers") or spec.get("markers") or []
    r = rmmod.edit_file(os.path.abspath(src), os.path.abspath(dst), markers)
    print(json.dumps(r, indent=2))
    return 0


def cmd_bake_editor(args):
    """Bake the editor's reloadMarkers save in place + nudge the live reload (shared core).

    A direct, on-demand bake (no request file)."""
    ch = args.channel_dir or paths.default_channel_dir()
    pz = args.pz_install or paths.default_pz_install()
    print(json.dumps(brmod.bake_from_editor(ch, pz), indent=2))
    return 0


def cmd_bake_request(args):
    """Process one pending reload-attachment bake request, if any (shared core).

    Atomically claims <channel>/rfx_bake_request.json, bakes, and writes rfx_bake_result.json.
    Runnable by hand or by a watcher. Prints the result (or a 'no pending request')."""
    ch = args.channel_dir or paths.default_channel_dir()
    pz = args.pz_install or paths.default_pz_install()
    r = brmod.process_pending_request(ch, pz)
    print(json.dumps(r if r is not None else {"ok": False, "error": "no pending request"}, indent=2))
    return 0


def cmd_watch(args):
    """Unified watcher: auto-bake EVERY save type (grip set, reload markers, emote, gunworks, glb)
    as it happens, no external helper needed. This is what watch.bat runs."""
    from pzanimforge import watcher
    ch = args.channel_dir or paths.default_channel_dir()
    pz = args.pz_install or paths.default_pz_install()
    watcher.watch(ch, os.path.abspath(__file__), pz_install=pz,
                  mod_roots=args.mods_dir or None, interval=args.interval)
    return 0


def cmd_watch_reload_bake(args):
    """Legacy watcher: reload-attachment saves only. Prefer `watch` (all save types)."""
    ch = args.channel_dir or paths.default_channel_dir()
    pz = args.pz_install or paths.default_pz_install()
    brmod.watch(ch, pz, interval=args.interval)
    return 0


def cmd_batch(args):
    m = mf.load(args.manifest)
    job = mf.to_job(m)
    delta = job["delta"]
    if not delta or not delta["bone"]:
        raise SystemExit("manifest has no delta.bone to apply")
    if delta["bone"] in m["protected_bones"]:
        raise SystemExit("refusing to edit protected bone %r" % delta["bone"])

    results = []
    for c in job["clips"]:
        os.makedirs(os.path.dirname(c["out_path"]), exist_ok=True)
        r = x_edit.edit_file(
            c["src"], c["out_path"], delta["bone"], delta["euler"],
            order=delta["order"], anim_set=c["anim_set"],
            mode=delta["mode"], rename_to=c["rename_to"],
        )
        r["src"] = c["src"]
        results.append(r)
    print(json.dumps({"ok": True, "results": results}, indent=2))

    if args.wire:
        for clip in m["clips"]:
            w = clip.get("wire")
            if not w:
                continue
            out_name = clip.get("out") or clip.get("clip")
            path = wiremod.write_node(
                m["output"]["mod_root"], w.get("state", "player/actions"),
                w.get("node_name", out_name), out_name, w.get("conditions"),
                blend_time=w.get("blend_time", 0.2),
                looped=w.get("looped", True), priority=w.get("priority", 10),
            )
            print("wired AnimSet node:", path)
    return 0


def _nonzero(v):
    return v and any(abs(float(c)) > 1e-9 for c in v)


def _load_clip_text(pz, clip):
    if not pz:
        raise SystemExit("PZ install not found; pass --pz-install")
    src = os.path.join(pz, "media", "anims_X", "Bob", clip + ".x")
    if not os.path.isfile(src):
        raise SystemExit("vanilla clip not found: %s" % src)
    with open(src, "r", encoding="utf-8", errors="replace", newline="") as fh:
        return fh.read()


def _apply_deltas(text, clip, deltas, order, mode):
    """Apply every {bone: rotation+translation} delta to one clip's .x text.
    Each delta is legacy [ex,ey,ez] (rotation) or {rot:[...], pos:[...]}."""
    applied = []
    for bone, delta in deltas.items():
        rot, pos = (delta.get("rot"), delta.get("pos")) if isinstance(delta, dict) \
            else (delta, None)
        rec = {"bone": bone}
        if _nonzero(rot):
            dq = x_edit.euler_to_quat(rot[0], rot[1], rot[2], order)
            try:
                text, keys, _ = x_edit.apply_delta(text, bone, dq,
                                                   anim_set=clip, mode=mode)
                rec["rot"], rec["rotKeys"] = rot, keys
            except ValueError as e:
                rec["rotSkipped"] = str(e)
        if _nonzero(pos):
            try:
                text, tkeys, _ = x_edit.apply_translation_delta(
                    text, bone, pos, anim_set=clip)
                rec["pos"], rec["posKeys"] = pos, tkeys
            except ValueError as e:
                rec["posSkipped"] = str(e)
        applied.append(rec)
    return text, applied


def _out_name(prefix, clip):
    """<prefix>_<clip-without-leading-Bob_>, e.g. MyGun_IdleAimHandgun."""
    base = clip[4:] if clip.startswith("Bob_") else clip
    return "%s_%s" % (prefix, base)


def cmd_bake(args):
    """Bake the editor's saved deltas into ONE new .x (single clip)."""
    with open(args.json, "r", encoding="utf-8") as fh:
        spec = json.load(fh)
    clip = spec["clip"]
    order, mode = spec.get("order", "XYZ"), spec.get("mode", "post")
    pz = args.pz_install or paths.default_pz_install()
    text = _load_clip_text(pz, clip)
    text, applied = _apply_deltas(text, clip, spec.get("deltas", {}), order, mode)
    if args.rename_set:
        text, _ = x_edit.rename_set(text, clip, args.rename_set)
    os.makedirs(os.path.dirname(os.path.abspath(args.dst)) or ".", exist_ok=True)
    with open(args.dst, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)
    print(json.dumps({"ok": True, "clip": clip, "dst": os.path.abspath(args.dst),
                      "applied": applied}, indent=2))
    return 0


def cmd_bake_set(args):
    """Bake the editor's deltas across a SET of vanilla clips into SEPARATE,
    renamed .x files in a mod (never touching the vanilla animations).

    Reads {set:{clips, namePrefix, mod}, deltas, ...}; for each clip writes
    <prefix>_<clip>.x with its AnimationSet renamed to match, under
    <mod_root>/<anims_subdir>/.
    """
    with open(args.json, "r", encoding="utf-8") as fh:
        spec = json.load(fh)
    s = spec.get("set") or {}
    clips = (args.clips.split(",") if args.clips else s.get("clips")) \
        or [spec.get("clip")]
    prefix = args.prefix or s.get("namePrefix") or "Edited"
    order, mode = spec.get("order", "XYZ"), spec.get("mode", "post")
    deltas = spec.get("deltas", {})
    pz = args.pz_install or paths.default_pz_install()
    out_dir = os.path.join(os.path.abspath(args.mod_root),
                           *args.anims_subdir.split("/"))
    os.makedirs(out_dir, exist_ok=True)
    results = []
    for clip in clips:
        text = _load_clip_text(pz, clip)
        text, applied = _apply_deltas(text, clip, deltas, order, mode)
        out = _out_name(prefix, clip)
        text, _ = x_edit.rename_set(text, clip, out)
        dst = os.path.join(out_dir, out + ".x")
        with open(dst, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        results.append({"clip": clip, "out": out, "dst": dst, "applied": applied})
    print(json.dumps({"ok": True, "prefix": prefix, "count": len(results),
                      "out_dir": out_dir, "results": results}, indent=2))
    return 0


def cmd_wire_set(args):
    """Generate the AnimSet XML clones + Lua hook that make a gun USE the
    edited clips that `bake-set` produced. Reads the same editor save file."""
    pz = args.pz_install or paths.default_pz_install()
    if not pz:
        raise SystemExit("PZ install not found; pass --pz-install")
    fulltypes = [t for t in (args.fulltypes or "").split(",") if t]
    report = wsmod.wire_set(
        os.path.abspath(args.json), os.path.abspath(args.mod_root), pz,
        prefix=args.prefix, tag_id=args.tag, fulltypes=fulltypes,
        var_name=args.var, priority=args.priority, scope=args.scope,
        dry_run=args.dry_run, build=args.build,
    )
    print(json.dumps(report, indent=2))
    return 0


def cmd_wire_gunworks(args):
    """Generate a complete Gunworks reload pack (renamed .x clips + gated AnimSet
    nodes + RegisterReloadAnims.lua) from the editor save's 'gunworks' block."""
    pz = args.pz_install or paths.default_pz_install()
    if not pz:
        raise SystemExit("PZ install not found; pass --pz-install")
    report = gwmod.wire_gunworks(
        os.path.abspath(args.json), os.path.abspath(args.mod_root), pz,
        build=args.build, lua_namespace=args.lua_namespace, dry_run=args.dry_run,
    )
    print(json.dumps(report, indent=2))
    return 0


def cmd_wire_emote(args):
    """Bake a single-frame emote (renamed .x + emote-gated AnimSet node) from the
    editor save's 'emote' block."""
    pz = args.pz_install or paths.default_pz_install()
    if not pz:
        raise SystemExit("PZ install not found; pass --pz-install")
    report = emotemod.wire_emote(
        os.path.abspath(args.json), os.path.abspath(args.mod_root), pz,
        build=args.build, dry_run=args.dry_run,
    )
    print(json.dumps(report, indent=2))
    return 0


def cmd_prop_fix(args):
    """Marker-guarded -90X correction of a reload glb's off-hand/gun prop sockets.

    --status --glb PATH   report {present, fixed, needed} without changing the file
    --glb PATH            fix that one glb (optionally --bones Bip01_Prop2, --force)
    --mod ROOT            fix every glb under a mod root that still needs it
    --json REQUEST        process an editor request file ({glb|mod, scope, bones, force})

    The fix is idempotent: a socket already recorded in the glb's `pz_prop_fix` marker is skipped
    unless --force, so re-running can never double-rotate.
    """
    bones = [b for b in (args.bones or "").split(",") if b] or None
    if args.status:
        if not args.glb:
            raise SystemExit("--status needs --glb")
        print(json.dumps(dict(pfmod.state(os.path.abspath(args.glb)),
                              glb=os.path.abspath(args.glb)), indent=2))
        return 0
    if args.json:
        with open(args.json, "r", encoding="utf-8") as fh:
            spec = json.load(fh)
        roots = args.mods_dir or scanmod.default_mod_roots()
        print(json.dumps(pfmod.bake_from_request(spec, roots), indent=2))
        return 0
    if args.mod:
        print(json.dumps(pfmod.apply_mod(os.path.abspath(args.mod), force=args.force), indent=2))
        return 0
    if args.glb:
        print(json.dumps(pfmod.apply(os.path.abspath(args.glb), bones=bones, force=args.force),
                         indent=2))
        return 0
    raise SystemExit("prop-fix needs one of --glb, --mod, --json, or --status --glb")


def cmd_scan(args):
    """Scan installed mods and refresh the editor's discovery caches (mod_clips.json +
    reload_markers.json) in the channel dir, so the editor's "Mods" and "Edit reload
    attachments" tabs populate with no external helper."""
    ch = args.channel_dir or paths.default_channel_dir()
    r = scanmod.scan(ch, mods_dirs=args.mods_dir or None, mod_roots=args.mod_root or None)
    print(json.dumps(r, indent=2))
    return 0


def cmd_preview(args):
    from pzanimforge import assimp_ingest  # lazy: only needed for viewing
    out = os.path.abspath(args.out_glb)
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    inter = assimp_ingest.x_to_glb(
        os.path.abspath(args.src), out,
        os.path.join(paths.tool_root(), "work", "fixed"))
    print(json.dumps({"ok": True, "preview_glb": inter}, indent=2))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="pz-anim-forge")
    sub = ap.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("edit", help="rotate one bone in one .x")
    e.add_argument("--src", required=True)
    e.add_argument("--dst", required=True)
    e.add_argument("--bone", required=True)
    e.add_argument("--euler", required=True, help="x,y,z degrees")
    e.add_argument("--order", default="XYZ")
    e.add_argument("--set", dest="anim_set", default=None,
                   help="AnimationSet name (default: edit the bone in ALL sets)")
    e.add_argument("--mode", default="post", choices=["post", "pre"])
    e.add_argument("--rename-set", dest="rename_to", default=None)
    e.set_defaults(func=cmd_edit)

    b = sub.add_parser("batch", help="run a manifest")
    b.add_argument("--manifest", required=True)
    b.add_argument("--wire", action="store_true",
                   help="also emit AnimNode XML for clips with a 'wire' block")
    b.set_defaults(func=cmd_batch)

    bk = sub.add_parser("bake", help="bake the in-game editor's saved deltas -> new .x")
    bk.add_argument("--json", required=True, help="editor save file")
    bk.add_argument("--dst", required=True, help="output .x")
    bk.add_argument("--rename-set", dest="rename_set", default=None)
    bk.add_argument("--pz-install", dest="pz_install", default=None)
    bk.set_defaults(func=cmd_bake)

    bs = sub.add_parser("bake-set",
                        help="bake editor deltas across a CLIP SET -> separate renamed .x in a mod")
    bs.add_argument("--json", required=True, help="editor save file (with a 'set' block)")
    bs.add_argument("--mod-root", dest="mod_root", required=True)
    bs.add_argument("--anims-subdir", dest="anims_subdir",
                    default="common/media/anims_X/Bob")
    bs.add_argument("--prefix", default=None, help="output name prefix (else from JSON)")
    bs.add_argument("--clips", default=None, help="comma list to override the JSON set")
    bs.add_argument("--pz-install", dest="pz_install", default=None)
    bs.set_defaults(func=cmd_bake_set)

    ws = sub.add_parser("wire-set",
                        help="generate AnimSet XML clones + Lua so a gun USES the baked clip set")
    ws.add_argument("--json", required=True, help="editor save file (with a 'set' block)")
    ws.add_argument("--mod-root", dest="mod_root", required=True)
    ws.add_argument("--prefix", default=None, help="clip name prefix (else from JSON)")
    ws.add_argument("--tag", default=None,
                    help="namespaced item tag to gate on (default <prefixlower>anims)")
    ws.add_argument("--fulltypes", default=None,
                    help="comma list of exact gun fullTypes to also gate on")
    ws.add_argument("--var", default=None, help="anim variable name (default <prefix>Equipped)")
    ws.add_argument("--priority", type=int, default=100, help="m_ConditionPriority for clones")
    ws.add_argument("--scope", default="pose", choices=["pose", "all"],
                    help="'pose' (held-pose nodes, default) or 'all' (any anim ref, incl. transitions)")
    ws.add_argument("--build", dest="build", default=None,
                    help="mod build subdir (default: the mod's build folder, else 42)")
    ws.add_argument("--pz-install", dest="pz_install", default=None)
    ws.add_argument("--dry-run", dest="dry_run", action="store_true",
                    help="report what would be written without writing")
    ws.set_defaults(func=cmd_wire_set)

    wg = sub.add_parser("wire-gunworks",
                        help="generate a Gunworks reload pack (clips + AnimSet nodes + RegisterReloadAnims.lua) from the editor save")
    wg.add_argument("--json", required=True, help="editor save file (with a 'gunworks' block)")
    wg.add_argument("--mod-root", dest="mod_root", required=True,
                    help="target gun mod root (the mod that requires Gunworks)")
    wg.add_argument("--build", default=None,
                    help="mod build subdir (default: the mod's build folder, else 42; or from JSON)")
    wg.add_argument("--lua-namespace", dest="lua_namespace", default=None,
                    help="lua require dir under media/lua/shared (default = mod dir name or from JSON)")
    wg.add_argument("--pz-install", dest="pz_install", default=None)
    wg.add_argument("--dry-run", dest="dry_run", action="store_true",
                    help="report what would be written without writing")
    wg.set_defaults(func=cmd_wire_gunworks)

    we = sub.add_parser("wire-emote",
                        help="bake a single-frame emote (.x + emote-gated AnimSet node) from the editor save")
    we.add_argument("--json", required=True, help="editor save file (with an 'emote' block)")
    we.add_argument("--mod-root", dest="mod_root", required=True, help="target mod root")
    we.add_argument("--build", default=None,
                    help="mod build subdir (default: the mod's build folder, else 42; or from JSON)")
    we.add_argument("--pz-install", dest="pz_install", default=None)
    we.add_argument("--dry-run", dest="dry_run", action="store_true",
                    help="report what would be written without writing")
    we.set_defaults(func=cmd_wire_emote)

    eg = sub.add_parser("edit-glb",
                        help="rotate one bone in a mod .glb (with -90X convention compensation)")
    eg.add_argument("--src", required=True, help="source .glb")
    eg.add_argument("--dst", required=True, help="output .glb (== src for in-place)")
    eg.add_argument("--bone", required=True)
    eg.add_argument("--euler", required=True, help="x,y,z degrees (game/local space)")
    eg.add_argument("--order", default="XYZ")
    eg.add_argument("--mode", default="post", choices=["post", "pre"])
    eg.add_argument("--clip", default=None, help="restrict to this animation name (else all)")
    eg.add_argument("--no-compensate", dest="no_compensate", action="store_true",
                    help="write the delta raw (for the root/topmost non-conjugated bone)")
    eg.set_defaults(func=cmd_edit_glb)

    bg = sub.add_parser("bake-glb",
                        help="bake the in-game editor's deltas into a mod .glb (same or new file)")
    bg.add_argument("--json", required=True, help="editor save file")
    bg.add_argument("--src", required=True, help="source mod .glb")
    bg.add_argument("--dst", required=True, help="output .glb (== src for in-place)")
    bg.add_argument("--order", default=None)
    bg.add_argument("--mode", default=None, choices=["post", "pre"])
    bg.add_argument("--clip", default=None, help="restrict to this animation name (else all)")
    bg.add_argument("--no-compensate", dest="no_compensate", action="store_true")
    bg.set_defaults(func=cmd_bake_glb)

    rm = sub.add_parser("reload-markers",
                        help="rewrite a reload node's gw attachment markers in place (from the editor save)")
    rm.add_argument("--json", required=True, help="editor save file (output.nodeFile + output.markers)")
    rm.add_argument("--src", default=None, help="node XML (overrides output.nodeFile)")
    rm.add_argument("--dst", default=None, help="output node XML (== src for in-place)")
    rm.set_defaults(func=cmd_reload_markers)

    be = sub.add_parser("bake-editor",
                        help="bake the editor's reloadMarkers save in place + live-reload (shared core)")
    be.add_argument("--channel-dir", dest="channel_dir", default=None,
                    help="editor channel dir (default ~/Zomboid/Lua/AnimForge)")
    be.add_argument("--pz-install", dest="pz_install", default=None,
                    help="PZ install root for the live-reload nudge (default: auto-detect)")
    be.set_defaults(func=cmd_bake_editor)

    brq = sub.add_parser("bake-request",
                         help="process one pending reload-attachment bake request, if any (shared core)")
    brq.add_argument("--channel-dir", dest="channel_dir", default=None)
    brq.add_argument("--pz-install", dest="pz_install", default=None)
    brq.set_defaults(func=cmd_bake_request)

    w = sub.add_parser("watch",
                       help="ONE watcher for every save type (grip set, reload markers, emote, "
                            "gunworks, glb) - what watch.bat runs")
    w.add_argument("--channel-dir", dest="channel_dir", default=None,
                   help="editor channel dir (default ~/Zomboid/Lua/AnimForge)")
    w.add_argument("--mods-dir", dest="mods_dir", action="append", default=None,
                   help="folder holding the mods to bake into (repeatable; default ~/Zomboid/mods)")
    w.add_argument("--pz-install", dest="pz_install", default=None)
    w.add_argument("--interval", type=float, default=0.5, help="poll seconds (default 0.5)")
    w.set_defaults(func=cmd_watch)

    wr = sub.add_parser("watch-reload-bake",
                        help="legacy: reload-attachment saves only (prefer `watch`)")
    wr.add_argument("--channel-dir", dest="channel_dir", default=None)
    wr.add_argument("--pz-install", dest="pz_install", default=None)
    wr.add_argument("--interval", type=float, default=0.5, help="poll seconds (default 0.5)")
    wr.set_defaults(func=cmd_watch_reload_bake)

    sc = sub.add_parser("scan",
                        help="scan installed mods and refresh the editor's discovery caches "
                             "(mod_clips.json + reload_markers.json)")
    sc.add_argument("--channel-dir", dest="channel_dir", default=None,
                    help="editor channel dir (default ~/Zomboid/Lua/AnimForge)")
    sc.add_argument("--mods-dir", dest="mods_dir", action="append", default=None,
                    help="a folder holding installed mods (repeatable; default ~/Zomboid/mods)")
    sc.add_argument("--mod-root", dest="mod_root", action="append", default=None,
                    help="path to a single mod's root to also scan (repeatable, e.g. a dev copy)")
    sc.set_defaults(func=cmd_scan)

    pf = sub.add_parser("prop-fix",
                        help="marker-guarded -90X fix of a reload glb's prop sockets "
                             "(ramrod/off-hand); idempotent")
    pf.add_argument("--glb", default=None, help="a single mod .glb to fix (or --status this glb)")
    pf.add_argument("--mod", default=None, help="a mod root: fix every glb under it that needs it")
    pf.add_argument("--json", default=None, help="an editor request file ({glb|mod, scope, bones})")
    pf.add_argument("--bones", default=None,
                    help="comma list of prop sockets to touch (default: Bip01_Prop1,Bip01_Prop2)")
    pf.add_argument("--force", action="store_true", help="re-apply even if already marked fixed")
    pf.add_argument("--status", action="store_true", help="report the glb's state, change nothing")
    pf.add_argument("--mods-dir", dest="mods_dir", action="append", default=None,
                    help="mods root(s) used to resolve --json scope 'mod' (default ~/Zomboid/mods)")
    pf.set_defaults(func=cmd_prop_fix)

    p = sub.add_parser("preview", help=".x -> .glb for VIEWING only (assimp)")
    p.add_argument("--src", required=True)
    p.add_argument("--out-glb", required=True)
    p.set_defaults(func=cmd_preview)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
