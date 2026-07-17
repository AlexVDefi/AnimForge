"""Marker-guarded prop-socket rotation fix for Project Zomboid reload `.glb` clips.

Blender's glTF exporter ships the two weapon-socket bones - `Bip01_Prop1` (the gun/primary
socket) and `Bip01_Prop2` (the off-hand / ramrod socket) - with a rest orientation 90 deg off
what PZ expects. Left uncorrected, the item riding that socket (e.g. the musket ramrod, or a
flintlock's off-hand cartridge) renders at a fixed wrong angle during the reload.

The fix is a -90 deg rotation about X, post-multiplied onto every rotation key of the socket
bone. That axis is not arbitrary: the engine conjugates every regular bone by R = -90 deg about
X (see glb_edit), and rotations about X commute with R, so the -90X reaches the game unchanged -
which is also why it needs NO glb_edit compensation.

Idempotency: which sockets are already corrected is recorded in the glTF `extras` block under
`pz_prop_fix` (a sorted list of bone names). The older `pz_prop1_fix` marker (Prop1 only) is
migrated on read. A bone already listed is skipped unless `force=True`, so re-running - or the
editor's "Bake fix" button clicked twice - can never double-rotate.

Pure file work: reads/writes only the `.glb` you point it at (the editor + watcher gate the path
to an existing `.glb` under a `mods/` tree). No sockets, no subprocess, no external helper.
"""
import json
import os
import struct

from . import glb_edit


# Both weapon-socket bones ship 90 deg off; each needs the same -90X correction.
PROP_BONES = ["Bip01_Prop1", "Bip01_Prop2"]
MARKER = "pz_prop_fix"           # extras -> sorted list of bones already corrected
LEGACY_MARKER = "pz_prop1_fix"   # older Prop1-only marker; migrated on read
JUNK_PREFIX = "[Action Stash]"

# -90 deg about X. Commutes with the engine's R modifier, so it is written raw (no compensation).
FIX_Q = glb_edit.axis_angle("x", -90.0)


def _real_anims(gltf):
    """The gltf's non-stashed animations (Blender leaves [Action Stash] clips behind)."""
    return [a for a in gltf.get("animations", []) if not a.get("name", "").startswith(JUNK_PREFIX)]


def _fixed_set(gltf):
    """Bones already corrected, per the extras marker (+ the legacy Prop1-only marker migrated in)."""
    fixed = set(gltf.get("extras", {}).get(MARKER) or [])
    if gltf.get("extras", {}).get(LEGACY_MARKER):
        fixed.add("Bip01_Prop1")
    return fixed


def _prop_present(gltf):
    """Prop-socket bones that actually have an animated rotation channel in this file."""
    node_idx = {n.get("name"): i for i, n in enumerate(gltf.get("nodes", []))}
    anims = _real_anims(gltf)
    present = []
    for bone in PROP_BONES:
        if bone not in node_idx:
            continue
        for a in anims:
            acc, _ = glb_edit._rotation_accessor(gltf, a, node_idx[bone])
            if acc is not None:
                present.append(bone)
                break
    return present


def read_gltf(path):
    """Decode just a glb's glTF JSON chunk (no bin). Enough for state()/scan - which only need the
    node list, animation channels, and extras - so it is cheap to run across every mod clip."""
    with open(path, "rb") as fh:
        head = fh.read(12)
        if head[:4] != b"glTF":
            raise ValueError("not a .glb")
        clen, ctype = struct.unpack("<II", fh.read(8))
        body = fh.read(clen)
    if ctype != 0x4E4F534A:  # first chunk is always JSON in a valid glb
        raise ValueError("first chunk is not JSON")
    return json.loads(body.decode("utf-8"))


def state_gltf(gltf):
    """Prop-socket state from an already-parsed glTF dict (no file read)."""
    present = _prop_present(gltf)
    fixed = _fixed_set(gltf)
    return {
        "present": present,
        "fixed": sorted(b for b in fixed if b in PROP_BONES),
        "needed": [b for b in present if b not in fixed],
    }


def state(path):
    """Report a glb's prop-socket state without mutating it:
    {present: [sockets animated], fixed: [sockets already corrected], needed: [present - fixed]}."""
    return state_gltf(read_gltf(path))


def apply(path, bones=None, force=False):
    """Post-multiply -90X onto every rotation key of each requested prop socket in `path`, in place.

    `bones` restricts the sockets to touch (default: both). A socket already marked fixed is skipped
    unless `force`. Records the extras marker; never rotates a non-prop bone. Returns a report dict.
    """
    ver, gltf, binbuf, orig_bin_len = glb_edit.load_glb(path)
    node_idx = {n.get("name"): i for i, n in enumerate(gltf.get("nodes", []))}
    anims = _real_anims(gltf)
    fixed = _fixed_set(gltf)
    targets = bones or PROP_BONES

    applied = []
    for bone in targets:
        if bone not in PROP_BONES:
            applied.append({"bone": bone, "skipped": "not a prop socket"})
            continue
        if bone in fixed and not force:
            applied.append({"bone": bone, "skipped": "already fixed"})
            continue
        if bone not in node_idx:
            applied.append({"bone": bone, "skipped": "absent"})
            continue
        keys = channels = 0
        for a in anims:
            acc, _ = glb_edit._rotation_accessor(gltf, a, node_idx[bone])
            if acc is None:
                continue
            keys += glb_edit._apply_to_channel(gltf, binbuf, acc, FIX_Q, "post")
            channels += 1
        if channels:
            fixed.add(bone)
            applied.append({"bone": bone, "keys": keys, "channels": channels})
        else:
            applied.append({"bone": bone, "skipped": "no rotation channel"})

    gltf.setdefault("extras", {})[MARKER] = sorted(b for b in fixed if b in PROP_BONES)
    gltf.get("extras", {}).pop(LEGACY_MARKER, None)

    out = glb_edit._rebuild(ver, gltf, binbuf, orig_bin_len)
    open(path, "wb").write(out)
    return {
        "ok": True,
        "path": os.path.abspath(path),
        "applied": applied,
        "fixed": sorted(b for b in fixed if b in PROP_BONES),
    }


def _iter_mod_glbs(mod_root):
    for dirpath, dirnames, filenames in os.walk(mod_root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules")]
        for fn in filenames:
            if fn.lower().endswith(".glb"):
                yield os.path.join(dirpath, fn)


def apply_mod(mod_root, force=False):
    """Fix every glb under `mod_root` that still has an uncorrected animated prop socket.
    Returns {ok, root, fixed: [reports for glbs changed], skipped: n}. Idempotent per glb."""
    changed, skipped = [], 0
    for glb in sorted(_iter_mod_glbs(mod_root)):
        try:
            st = state(glb)
        except Exception as e:
            changed.append({"path": os.path.abspath(glb), "ok": False, "error": str(e)})
            continue
        if st["needed"] or force:
            changed.append(apply(glb, force=force))
        else:
            skipped += 1
    return {"ok": True, "root": os.path.abspath(mod_root), "fixed": changed, "skipped": skipped}


# ---------------------------------------------------- safety gate + request lifecycle ---

def validate_glb(glb_path):
    """Return the abspath of a .glb the fix is allowed to touch, or raise ValueError.

    Mirrors bake_request.validate_node_file: only an EXISTING `.glb` under a `.../mods/...` tree
    qualifies. `abspath` collapses any `..`, and we never create files - so a request can only ever
    rotate a real mod animation, never anything else on the machine."""
    if not glb_path or not isinstance(glb_path, str):
        raise ValueError("no glb path")
    ap = os.path.abspath(glb_path)
    slashed = ap.replace("\\", "/").lower()
    if not slashed.endswith(".glb"):
        raise ValueError("path must be a .glb")
    if "/mods/" not in slashed:
        raise ValueError("glb must live under a 'mods' directory")
    if not os.path.isfile(ap):
        raise ValueError("glb does not exist (the fix never creates files)")
    return ap


def _resolve_mod_root(mod, mod_roots):
    for root in mod_roots or []:
        p = os.path.join(root, mod)
        if os.path.isdir(p):
            return os.path.abspath(p)
    return None


def bake_from_request(spec, mod_roots):
    """Run one prop-fix request dict. scope 'mod' fixes every glb under the named mod (validated to
    live under a mods root); otherwise fixes the single validated `glb`. Never raises."""
    force = bool(spec.get("force"))
    scope = spec.get("scope") or ("mod" if spec.get("mod") and not spec.get("glb") else "clip")
    try:
        if scope == "mod":
            root = _resolve_mod_root(spec.get("mod"), mod_roots)
            if not root:
                return {"ok": False, "error": "mod %r not found under a mods root" % spec.get("mod")}
            # keep the batch inside a real mods tree (same gate the single-glb path applies)
            if "/mods/" not in root.replace("\\", "/").lower():
                return {"ok": False, "error": "mod root is not under a 'mods' directory"}
            r = apply_mod(root, force=force)
            return dict(r, scope="mod")
        glb = validate_glb(spec.get("glb"))
        bones = spec.get("bones") or None
        r = apply(glb, bones=bones, force=force)
        return dict(r, scope="clip")
    except ValueError as e:
        return {"ok": False, "error": "rejected: %s" % e}
    except Exception as e:
        return {"ok": False, "error": "prop-fix failed: %s" % e}


def _write_result(channel_dir, result):
    tmp = os.path.join(channel_dir, "glb_prop_fix_result.json.%d.tmp" % os.getpid())
    final = os.path.join(channel_dir, "glb_prop_fix_result.json")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(result, fh)
    os.replace(tmp, final)


def process_pending_request(channel_dir, mod_roots):
    """If glb_prop_fix_request.json is waiting, atomically claim it, run the fix, and publish
    glb_prop_fix_result.json. Returns the result dict, or None if there was no request."""
    req = os.path.join(channel_dir, "glb_prop_fix_request.json")
    if not os.path.isfile(req):
        return None
    claim = "%s.%d.claim" % (req, os.getpid())
    try:
        os.replace(req, claim)  # atomic; only one claimer wins
    except OSError:
        return None
    ts = None
    try:
        try:
            with open(claim, "r", encoding="utf-8") as fh:
                spec = json.load(fh)
        except Exception as e:
            spec = {}
            result = {"ok": False, "error": "request unreadable: %s" % e}
        else:
            ts = spec.get("ts")
            result = bake_from_request(spec, mod_roots)
        result = dict(result, ts=ts)
        try:
            _write_result(channel_dir, result)
        except OSError:
            pass
        return result
    finally:
        try:
            os.remove(claim)
        except OSError:
            pass
