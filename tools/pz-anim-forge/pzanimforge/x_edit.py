"""Edit Project Zomboid DirectX .x animation files in place.

The whole point of this module: PZ loads a .x animation through the native
loadX path, which applies NO glb coordinate convention (no +90X bone rotation,
no 0.01 scale, no handedness re-import). So if we keep an animation as .x and
only rotate ONE bone's rotation keyframes by a constant local-space delta, the
engine loads it byte-for-byte the same way it loads the vanilla clip, plus the
single nudge. No round-trip through glb, no orientation drift. Verified in-game
2026-06-11 (unmodified copy = pixel-vanilla; a R_UpperArm delta raises exactly
that arm and nothing else).

Format being edited (text .x, "xof 0303txt"):

    AnimationSet <name> {
      Animation {
        { <BoneName> }
        AnimationKey R {            # keyType 0 = rotation, quats as w,x,y,z
          0;                        # keyType
          N;                        # number of keys
          <time>;4;w,x,y,z;;,       # one key per line, ',' separated, ';' last
          ...
        }
        AnimationKey S { ... }      # keyType 1 = scale  (count 3)
        AnimationKey T { ... }      # keyType 2 = translation (count 3)
      }
      ...
    }

We only ever touch the R block(s) of the requested bone, leaving every other
byte (S/T keys, other bones, the whole skinned-mesh + skeleton section) intact.
A vanilla .x can hold more than one AnimationSet; with anim_set=None we edit the
bone in EVERY set, with a name we edit only that set.
"""
from __future__ import annotations

import argparse
import math
import re
import sys


# ---- quaternion helpers (w, x, y, z) ---------------------------------------

def qmul(a, b):
    aw, ax, ay, az = a
    bw, bx, by, bz = b
    return (
        aw * bw - ax * bx - ay * by - az * bz,
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
    )


def qnorm(q):
    w, x, y, z = q
    n = math.sqrt(w * w + x * x + y * y + z * z) or 1.0
    return (w / n, x / n, y / n, z / n)


def euler_to_quat(rx_deg, ry_deg, rz_deg, order="XYZ"):
    """Intrinsic euler (degrees) -> quaternion (w,x,y,z), applied in `order`."""
    def axis_q(angle_deg, axis):
        h = math.radians(angle_deg) / 2.0
        s = math.sin(h)
        return (math.cos(h), axis[0] * s, axis[1] * s, axis[2] * s)

    qmap = {
        "X": axis_q(rx_deg, (1.0, 0.0, 0.0)),
        "Y": axis_q(ry_deg, (0.0, 1.0, 0.0)),
        "Z": axis_q(rz_deg, (0.0, 0.0, 1.0)),
    }
    q = (1.0, 0.0, 0.0, 0.0)
    for ch in order.upper():
        q = qmul(q, qmap[ch])
    return qnorm(q)


# ---- .x text surgery -------------------------------------------------------

# Matches one rotation key: "<time>;4;w,x,y,z;;" (the trailing separator , or ;
# is left untouched by the substitution).
_NUM = r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?"
_KEY_RE = re.compile(
    r"(\d+\s*;\s*4\s*;\s*)"
    r"(" + _NUM + r")\s*,\s*(" + _NUM + r")\s*,\s*(" + _NUM + r")\s*,\s*(" + _NUM + r")"
    r"(\s*;;)"
)


def _find_set_span(text, anim_set):
    """Return (start, end) char span of `AnimationSet <name> { ... }`.

    If anim_set is None, spans the whole text (so every set is in range).
    """
    if anim_set is None:
        return 0, len(text)
    m = re.search(r"AnimationSet\s+" + re.escape(anim_set) + r"\s*\{", text)
    if not m:
        raise ValueError("AnimationSet '%s' not found" % anim_set)
    depth = 0
    i = m.end() - 1  # at the opening brace
    while i < len(text):
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return m.start(), i + 1
        i += 1
    raise ValueError("Unterminated AnimationSet '%s'" % anim_set)


def _iter_bone_key_blocks(text, span, bone, key_letter):
    """Yield (body_start, body_end) for every `{ bone } ... AnimationKey <L> { }`
    in the span (one per AnimationSet that animates the bone). L is R/S/T."""
    lo, hi = span
    bone_re = re.compile(r"\{\s*" + re.escape(bone) + r"\s*\}")
    key_re = re.compile(r"AnimationKey\s+" + key_letter + r"\s*\{")
    pos = lo
    while True:
        bm = bone_re.search(text, pos, hi)
        if not bm:
            return
        rm = key_re.search(text, bm.end(), hi)
        if not rm:
            return
        body_start = rm.end()
        close = text.index("}", body_start)  # key body has no nested braces
        yield body_start, close
        pos = close + 1


def _transform_body(body, delta_q, mode):
    n = [0]

    def repl(m):
        n[0] += 1
        q = (float(m.group(2)), float(m.group(3)),
             float(m.group(4)), float(m.group(5)))
        out = qmul(q, delta_q) if mode == "post" else qmul(delta_q, q)
        w, x, y, z = qnorm(out)
        return "%s%.6f,%.6f,%.6f,%.6f%s" % (m.group(1), w, x, y, z, m.group(6))

    return _KEY_RE.sub(repl, body), n[0]


_TKEY_RE = re.compile(
    r"(\d+\s*;\s*3\s*;\s*)"
    r"(" + _NUM + r")\s*,\s*(" + _NUM + r")\s*,\s*(" + _NUM + r")"
    r"(\s*;;)"
)


def apply_translation_delta(text, bone, dpos, anim_set=None):
    """Add dpos=(dx,dy,dz) to every translation (T) key of `bone`. Mirrors the
    live engine override's parent-frame position add. Returns (text, keys, sets)."""
    span = _find_set_span(text, anim_set)
    blocks = list(_iter_bone_key_blocks(text, span, bone, "T"))
    if not blocks:
        raise ValueError("bone '%s' has no AnimationKey T in the target set(s)"
                         % bone)
    dx, dy, dz = dpos
    n = [0]

    def repl(m):
        n[0] += 1
        x = float(m.group(2)) + dx
        y = float(m.group(3)) + dy
        z = float(m.group(4)) + dz
        return "%s%.6f,%.6f,%.6f%s" % (m.group(1), x, y, z, m.group(5))

    for body_start, body_end in reversed(blocks):
        new_body = _TKEY_RE.sub(repl, text[body_start:body_end])
        text = text[:body_start] + new_body + text[body_end:]
    return text, n[0], len(blocks)


def apply_delta(text, bone, delta_q, anim_set=None, mode="post"):
    """Rotate every rotation key of `bone` by delta_q. Returns (text, keys, sets).

    mode 'post' (default) applies the delta in the bone's local frame after its
    current rotation (q * d); 'pre' applies it before (d * q).
    """
    span = _find_set_span(text, anim_set)
    blocks = list(_iter_bone_key_blocks(text, span, bone, "R"))
    if not blocks:
        raise ValueError("bone '%s' has no AnimationKey R in the target set(s)"
                         % bone)
    keys = 0
    # edit last-to-first so earlier char offsets stay valid as we splice
    for body_start, body_end in reversed(blocks):
        new_body, n = _transform_body(text[body_start:body_end], delta_q, mode)
        text = text[:body_start] + new_body + text[body_end:]
        keys += n
    return text, keys, len(blocks)


# Identity per key type: rotation quaternion (w,x,y,z)=(1,0,0,0), scale (1,1,1), translation (0,0,0).
_IDENTITY_KEY = {
    "R": "1.000000,0.000000,0.000000,0.000000",
    "S": "1.000000,1.000000,1.000000",
    "T": "0.000000,0.000000,0.000000",
}


def flatten_bone(text, bone, anim_set=None):
    """Pin `bone` to IDENTITY (no rotation/translation, unit scale) on every R/S/T key in the set(s).

    The engine reparents the off-hand prop bone Bip01_Prop2 onto Bip01_L_Hand for every player
    (IsoPlayer.onAnimPlayerCreated -> addBoneReparent). A reload clip baked from a vanilla base still
    carries the vanilla mag-prop keys on that bone, so a mod prop attached there both jitters AND floats
    at the clip's arbitrary offset (now interpreted relative to the hand). Pinning the bone to identity
    makes it sit exactly AT the hand and simply follow it; the reload markers (gwPartToHand/gwPartToGun)
    then own all of the prop's intended gun<->hand motion. Lenient: a bone with no keys in a set is
    skipped, not an error. Returns (text, keys_pinned)."""
    span = _find_set_span(text, anim_set)
    pinned = 0
    # R = rotation (4-value key); S + T = scale/translation (3-value key). One block per animating set.
    for key_re, letter in ((_KEY_RE, "R"), (_TKEY_RE, "S"), (_TKEY_RE, "T")):
        const = _IDENTITY_KEY[letter]
        last = key_re.groups                          # group index of the trailing ';;'
        for body_start, body_end in reversed(list(_iter_bone_key_blocks(text, span, bone, letter))):
            def repl(m, const=const, last=last):
                return m.group(1) + const + m.group(last)
            new_body, n = key_re.subn(repl, text[body_start:body_end])
            text = text[:body_start] + new_body + text[body_end:]
            pinned += n
    return text, pinned


def despike_bone(text, bone, anim_set=None, factor=3.5, floor=0.02):
    """Remove isolated outlier ('spike') translation keys from a bone via a Hampel median-3 filter.

    A vanilla off-hand prop track (Bip01_Prop2) is a mostly-smooth trajectory but carries a handful of
    keyframes that jump far off and back (unused vanilla mag-prop garbage), which jitters a mod prop
    attached there. For each of x/y/z, a key whose deviation from the median of {prev,self,next} exceeds
    `factor` times the median deviation (floored) is replaced by that median - so only true spikes move,
    the smooth motion is preserved, and the prop follows the hand cleanly. Returns (text, keys_fixed)."""
    span = _find_set_span(text, anim_set)
    fixed = 0
    for body_start, body_end in reversed(list(_iter_bone_key_blocks(text, span, bone, "T"))):
        body = text[body_start:body_end]
        vals = [[float(m.group(2)), float(m.group(3)), float(m.group(4))]
                for m in _TKEY_RE.finditer(body)]
        n = len(vals)
        if n < 3:
            continue
        new = [list(v) for v in vals]
        for c in range(3):
            med = [None] * n
            devs = []
            for i in range(1, n - 1):
                m3 = sorted((vals[i - 1][c], vals[i][c], vals[i + 1][c]))[1]
                med[i] = m3
                devs.append(abs(vals[i][c] - m3))
            if not devs:
                continue
            mdev = sorted(devs)[len(devs) // 2]
            thr = max(floor, factor * mdev)
            for i in range(1, n - 1):
                if abs(vals[i][c] - med[i]) > thr:
                    new[i][c] = med[i]
        for i in range(n):
            if new[i] != vals[i]:
                fixed += 1
        idx = [0]

        def repl(m):
            i = idx[0]
            idx[0] += 1
            v = new[i]
            return "%s%.6f,%.6f,%.6f%s" % (m.group(1), v[0], v[1], v[2], m.group(5))

        text = text[:body_start] + _TKEY_RE.sub(repl, body) + text[body_end:]
    return text, fixed


def freeze_bone_to_frame0(text, bone, anim_set=None):
    """Pin `bone` to its FIRST keyframe's value on every R/S/T key in the set(s), making its pose a
    single constant for the whole clip.

    Used to 'seat' an off-hand prop (Bip01_Prop2): the vanilla prop track is a moving trajectory, so a
    mag attached there rides that path (offset from the hand) AND looks different forward vs reversed (a
    magazine unload is the load clip reversed). Freezing the bone to its frame-0 value drops the motion,
    so the prop sits at one fixed offset from the hand and the load + unload look identical. The frame-0
    value is taken AFTER any deltas are applied, so an authored Prop2 offset defines exactly where it
    sits. Lenient: a bone with no keys in a set is skipped. Returns (text, keys_frozen)."""
    span = _find_set_span(text, anim_set)
    frozen = 0
    for key_re, letter in ((_KEY_RE, "R"), (_TKEY_RE, "S"), (_TKEY_RE, "T")):
        last = key_re.groups                          # trailing ';;' group
        for body_start, body_end in reversed(list(_iter_bone_key_blocks(text, span, bone, letter))):
            body = text[body_start:body_end]
            first = key_re.search(body)
            if not first:
                continue
            g0, g1, gl = first.group(0), first.group(1), first.group(last)
            const = g0[len(g1): len(g0) - len(gl)]    # the value portion of the first key, verbatim
            def repl(m, const=const, last=last):
                return m.group(1) + const + m.group(last)
            new_body, n = key_re.subn(repl, body)
            text = text[:body_start] + new_body + text[body_end:]
            frozen += n
    return text, frozen


def rename_set(text, old_name, new_name):
    """Rename `AnimationSet old { ... }` -> `AnimationSet new { ... }`. Used by
    the gun-specific route (ship under a new name gated by an AnimNode)."""
    pat = re.compile(r"(AnimationSet\s+)" + re.escape(old_name) + r"(\s*\{)")
    new_text, n = pat.subn(lambda m: m.group(1) + new_name + m.group(2), text)
    if n == 0:
        raise ValueError("AnimationSet '%s' not found to rename" % old_name)
    return new_text, n


def edit_file(src, dst, bone, euler, order="XYZ", anim_set=None, mode="post",
              rename_to=None):
    """Read src .x, rotate `bone` by `euler` (and optionally rename the set),
    write dst .x. Returns a small report dict."""
    # newline="" disables universal-newline translation so the original CRLF
    # line endings of the vanilla .x survive the round-trip byte-exact.
    with open(src, "r", encoding="utf-8", errors="replace", newline="") as fh:
        text = fh.read()
    dq = euler_to_quat(euler[0], euler[1], euler[2], order)
    text, keys, sets = apply_delta(text, bone, dq, anim_set=anim_set, mode=mode)
    renamed = None
    if rename_to and rename_to != anim_set:
        if not anim_set:
            raise ValueError("rename_to requires an explicit anim_set")
        text, _ = rename_set(text, anim_set, rename_to)
        renamed = rename_to
    with open(dst, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)
    return {"dst": dst, "bone": bone, "keys": keys, "sets": sets,
            "renamed_set": renamed}


def _parse_args(argv):
    p = argparse.ArgumentParser(description="Rotate one bone in a PZ .x animation")
    p.add_argument("--src", required=True)
    p.add_argument("--dst", required=True)
    p.add_argument("--bone", required=True)
    p.add_argument("--euler", required=True,
                   help="degrees as rx,ry,rz (local-space delta)")
    p.add_argument("--order", default="XYZ")
    p.add_argument("--set", dest="anim_set", default=None,
                   help="AnimationSet name (default: edit the bone in ALL sets)")
    p.add_argument("--mode", default="post", choices=["post", "pre"])
    p.add_argument("--rename-set", dest="rename_to", default=None,
                   help="rename the (named) AnimationSet, for a new-name ship")
    return p.parse_args(argv)


def main(argv=None):
    a = _parse_args(argv if argv is not None else sys.argv[1:])
    euler = [float(v) for v in a.euler.split(",")]
    if len(euler) != 3:
        raise SystemExit("--euler needs three comma-separated degrees")
    r = edit_file(a.src, a.dst, a.bone, euler, order=a.order,
                  anim_set=a.anim_set, mode=a.mode, rename_to=a.rename_to)
    print("edited %d rotation key(s) across %d set(s) of %s -> %s%s"
          % (r["keys"], r["sets"], r["bone"], r["dst"],
             (" (set renamed to %s)" % r["renamed_set"]) if r["renamed_set"]
             else ""))


if __name__ == "__main__":
    main()
