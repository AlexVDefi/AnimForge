"""Edit bone rotation keyframes inside a Project Zomboid `.glb` animation, in place.

Unlike `.x` (loaded by the native `loadX` path with no coordinate convention), the engine
loads `.glb` through `loadGLTF` (FileTask_LoadAnimation.java:84), which applies a per-bone
rotation modifier `R = -90 degrees about X` plus a 0.01 translation scale. For every regular
skeleton bone the engine CONJUGATES each rotation key:

    q_game = R^-1 . q_file . R                 (jassimp/ImportedSkeleton.java:257-327)

So a delta the author dials in live (via setBoneRotationOverride, in game/local space) does
NOT reach the game unchanged if we write it straight into the `.glb`: an X-axis delta commutes
with R and survives, but Y and Z do not (Y shows up as Z, Z as -Y).

To make a LOCAL/post delta `D` (the same convention x_edit uses for `.x`) reproduce in-game, we
pre-conjugate it and post-multiply the file key:

    C = R . D . R^-1
    q_file_new = q_file_old . C

Proof (regular/conjugated bone):
    R^-1 . (q_file . C) . R = R^-1 . q_file . R . D . R^-1 . R = (R^-1 . q_file . R) . D
                            = q_clip_game . D                                   (the desired local delta)

`C = R.D.R^-1` is just `D` with its rotation axis remapped by R (-90X): X->X, Y->-Z, Z->Y; the
angle is unchanged. Set compensate=False to write `D` raw (for the synthetic RootNode / any
topmost non-conjugated bone, whose keys the engine only right-multiplies by R).

Quaternions here are glTF order (x, y, z, w) throughout - NOT the w,x,y,z used by x_edit.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import shutil
import struct

JSON_CHUNK = 0x4E4F534A
BIN_CHUNK = 0x004E4942


# ---- pristine-source cache: make in-place glb editing NON-cumulative -------
# Editing a mod .glb bakes bone deltas straight into the file, so re-saving would compound (a 25 deg
# tweak then a 30 deg tweak -> 55 deg). The .x path never has this: it always bakes from the pristine
# vanilla clip. We give .glb the same behaviour by keeping a pristine copy of each edited glb and
# always baking from THAT (pristine + the editor's current deltas). The copy is captured the first
# time a glb is edited, and re-captured if the source is replaced externally (a fresh Blender export),
# detected by content hash - NOT mtime, since our own in-place bake always bumps the file's mtime.

def _sha(path):
    h = hashlib.sha1()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _pristine_paths(channel_dir, src_glb):
    src_glb = os.path.abspath(src_glb)
    cache = os.path.join(channel_dir, "glb_orig")
    key = hashlib.sha1(src_glb.replace("\\", "/").lower().encode("utf-8")).hexdigest()[:16]
    base = os.path.splitext(os.path.basename(src_glb))[0]
    pristine = os.path.join(cache, "%s_%s.glb" % (base, key))
    return src_glb, cache, pristine, pristine + ".json"


def pristine_source(channel_dir, src_glb):
    """Path to the pristine (pre-edit) copy of src_glb, capturing it on first use. Baking a glb edit
    from this instead of the live file makes editing non-cumulative. Re-captures when the live glb no
    longer matches our pristine OR our last bake output (i.e. it was re-exported outside the editor)."""
    src_glb, cache, pristine, meta = _pristine_paths(channel_dir, src_glb)
    os.makedirs(cache, exist_ok=True)
    last = None
    if os.path.isfile(meta):
        try:
            last = json.load(open(meta, encoding="utf-8")).get("lastBakedSha")
        except Exception:
            last = None
    live = _sha(src_glb)
    if (not os.path.isfile(pristine)) or (live != _sha(pristine) and live != last):
        shutil.copy2(src_glb, pristine)
    return pristine


def record_baked(channel_dir, src_glb, dst_glb):
    """Record the bake output's hash so the next edit can tell our own in-place bake from an external
    re-export of the source. Non-fatal."""
    src_glb, cache, pristine, meta = _pristine_paths(channel_dir, src_glb)
    try:
        json.dump({"lastBakedSha": _sha(dst_glb), "src": src_glb, "dst": os.path.abspath(dst_glb)},
                  open(meta, "w", encoding="utf-8"))
    except Exception:
        pass


# ---- quaternion helpers (glTF order: x, y, z, w) ---------------------------

def qmul(a, b):
    """Hamilton product a . b, both (x, y, z, w)."""
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    )


def qnorm(q):
    n = math.sqrt(sum(c * c for c in q)) or 1.0
    return tuple(c / n for c in q)


def qconj(q):
    x, y, z, w = q
    return (-x, -y, -z, w)


def axis_angle(axis, deg):
    """Unit quaternion (x, y, z, w) for `deg` about a principal axis."""
    h = math.radians(deg) / 2.0
    s = math.sin(h)
    a = {"x": (1, 0, 0), "y": (0, 1, 0), "z": (0, 0, 1)}[axis]
    return (a[0] * s, a[1] * s, a[2] * s, math.cos(h))


def euler_to_quat(rx_deg, ry_deg, rz_deg, order="XYZ"):
    """Intrinsic euler (degrees) -> quaternion (x, y, z, w), folded in `order`."""
    qmap = {
        "X": axis_angle("x", rx_deg),
        "Y": axis_angle("y", ry_deg),
        "Z": axis_angle("z", rz_deg),
    }
    q = (0.0, 0.0, 0.0, 1.0)
    for ch in order.upper():
        q = qmul(q, qmap[ch])
    return qnorm(q)


# ---- the engine's -90X convention + the compensation -----------------------

# R = -90 degrees about +X (the engine's animBonesRotateModifier), and its inverse (+90 X).
R = axis_angle("x", -90.0)
R_INV = axis_angle("x", 90.0)


def compensate(delta_q):
    """C = R . D . R^-1 : delta_q pre-conjugated so the engine's per-bone conjugation
    (R^-1 . q . R) reproduces the author's game-space delta exactly."""
    return qnorm(qmul(qmul(R, delta_q), R_INV))


def engine_conjugate(q_file):
    """What the engine renders for a regular bone key: R^-1 . q_file . R. For tests/calibration."""
    return qnorm(qmul(qmul(R_INV, q_file), R))


# ---- glb chunk read / write ------------------------------------------------

def split(data):
    if data[:4] != b"glTF":
        raise ValueError("not a .glb")
    ver, total = struct.unpack("<II", data[4:12])
    if total != len(data):
        raise ValueError("header length %d != file size %d" % (total, len(data)))
    out = []
    off = 12
    while off < len(data):
        clen, ctype = struct.unpack("<II", data[off:off + 8])
        out.append([ctype, data[off + 8: off + 8 + clen]])
        off += 8 + clen + ((4 - clen % 4) % 4)
    return ver, out


def _rebuild(ver, gltf, binbuf, orig_bin_len):
    new_json = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    new_json += b" " * ((4 - len(new_json) % 4) % 4)
    binbuf = bytearray(binbuf)
    binbuf += b"\x00" * ((4 - len(binbuf) % 4) % 4)
    out = bytearray(b"glTF" + struct.pack("<II", ver, 0))
    out += struct.pack("<II", len(new_json), JSON_CHUNK) + new_json
    out += struct.pack("<II", orig_bin_len, BIN_CHUNK) + binbuf
    struct.pack_into("<I", out, 8, len(out))
    return bytes(out)


def load_glb(path):
    data = open(path, "rb").read()
    ver, chunks = split(data)
    gj = next(c for c in chunks if c[0] == JSON_CHUNK)
    gb = next(c for c in chunks if c[0] == BIN_CHUNK)
    gltf = json.loads(gj[1].decode("utf-8"))
    return ver, gltf, bytearray(gb[1]), len(gb[1])


# ---- per-bone rotation-channel edit ----------------------------------------

def _rotation_accessor(gltf, anim, node_idx):
    """The single rotation-output accessor for `node_idx` in `anim`, or None."""
    outs = [
        anim["samplers"][c["sampler"]]["output"]
        for c in anim["channels"]
        if c["target"]["node"] == node_idx and c["target"]["path"] == "rotation"
    ]
    if len(outs) != 1:
        return None, ("no rotation channel" if not outs else "%d rotation channels" % len(outs))
    target = outs[0]
    shared = sum(1 for c in anim["channels"]
                 if anim["samplers"][c["sampler"]]["output"] == target)
    if shared != 1:
        return None, "rotation accessor shared by %d channels" % shared
    return target, None


def _apply_to_channel(gltf, binbuf, accessor_idx, cq, mode):
    """Multiply every key in a VEC4 float rotation accessor by cq (post: q.cq, pre: cq.q)."""
    acc = gltf["accessors"][accessor_idx]
    if acc.get("type") != "VEC4" or acc.get("componentType") != 5126 or acc.get("normalized"):
        raise ValueError("expected non-normalized float VEC4 rotations")
    bv = gltf["bufferViews"][acc["bufferView"]]
    if bv.get("byteStride") not in (None, 16):
        raise ValueError("interleaved rotation data unsupported")
    start = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    count = acc["count"]
    for k in range(count):
        o = start + 16 * k
        q = struct.unpack_from("<4f", binbuf, o)
        q2 = qmul(q, cq) if mode == "post" else qmul(cq, q)
        struct.pack_into("<4f", binbuf, o, *qnorm(q2))
    return count


def _iter_anims(gltf, clip):
    """The animation(s) to edit: the one named `clip` if given and present, else all."""
    anims = gltf.get("animations", [])
    if clip:
        named = [a for a in anims if a.get("name") == clip]
        if named:
            return named
    return anims


def edit_glb(src, dst, deltas, order="XYZ", mode="post", do_compensate=True, clip=None):
    """Apply per-bone rotation deltas to `src` .glb, write `dst` (dst==src => in place).

    `deltas` is {bone: [ex,ey,ez]} or {bone: {"rot":[...], "pos":[...]}} - euler degrees in the
    author's game/local space (exactly what the editor stores). Rotation only for now.
    Returns a report dict. Bones absent / without a rotation channel are skipped with a note.
    """
    ver, gltf, binbuf, orig_bin_len = load_glb(src)
    node_idx = {n.get("name"): i for i, n in enumerate(gltf.get("nodes", []))}
    anims = _iter_anims(gltf, clip)
    applied = []

    for bone, delta in deltas.items():
        rot = delta.get("rot") if isinstance(delta, dict) else delta
        rec = {"bone": bone}
        if not rot or not any(abs(float(c)) > 1e-9 for c in rot):
            rec["skipped"] = "zero/absent rotation"
            applied.append(rec)
            continue
        if bone not in node_idx:
            rec["skipped"] = "bone not in file"
            applied.append(rec)
            continue

        d = euler_to_quat(rot[0], rot[1], rot[2], order)
        cq = compensate(d) if do_compensate else qnorm(d)

        keys = 0
        channels = 0
        errs = []
        for anim in anims:
            acc, err = _rotation_accessor(gltf, anim, node_idx[bone])
            if acc is None:
                errs.append(err)
                continue
            keys += _apply_to_channel(gltf, binbuf, acc, cq, mode)
            channels += 1
        if channels:
            rec.update(rot=rot, keys=keys, channels=channels, compensated=do_compensate)
        else:
            rec["skipped"] = "; ".join(sorted(set(errs))) or "no rotation channel"
        applied.append(rec)

    out = _rebuild(ver, gltf, binbuf, orig_bin_len)
    os.makedirs(os.path.dirname(os.path.abspath(dst)) or ".", exist_ok=True)
    open(dst, "wb").write(out)
    return {"ok": True, "src": os.path.abspath(src), "dst": os.path.abspath(dst),
            "inPlace": os.path.abspath(src) == os.path.abspath(dst), "applied": applied}


# ---- offline self-test: the compensation round-trip ------------------------

def _selftest():
    """Verify that writing C = R.D.R^-1 (post) and applying the engine conjugation
    (R^-1 . q . R) reproduces the local delta D for ANY axis, on a non-identity base."""
    import random
    random.seed(1)
    ok = True
    cases = [("X", (17, 0, 0)), ("Y", (0, 23, 0)), ("Z", (0, 0, 31)),
             ("XYZ", (11, -19, 27))]
    # a non-identity base file key (arbitrary)
    base = qnorm(euler_to_quat(12, -34, 56))
    for label, e in cases:
        d = euler_to_quat(*e)                       # game/local delta the author wants
        cq = compensate(d)
        q_file_new = qnorm(qmul(base, cq))          # post-multiply (matches x_edit 'post')
        game = engine_conjugate(q_file_new)         # what the engine renders
        want = qnorm(qmul(engine_conjugate(base), d))  # q_clip_game . D
        # compare up to sign (q and -q are the same rotation)
        dot = abs(sum(a * b for a, b in zip(game, want)))
        good = abs(dot - 1.0) < 1e-5
        ok = ok and good
        print("  %-4s delta %-14s -> %s (dot=%.7f)" % (label, e, "OK" if good else "MISMATCH", dot))
    print("selftest:", "PASS" if ok else "FAIL")
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if _selftest() else 1)
