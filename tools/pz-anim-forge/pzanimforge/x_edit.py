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
