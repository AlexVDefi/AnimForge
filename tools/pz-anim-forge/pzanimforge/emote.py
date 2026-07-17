"""Generate a single-frame emote from the in-game editor's saved pose.

The Anim Forge "Single pose -> emote" mode writes an `emote` block to
~/Zomboid/Lua/AnimForge/anim_edit.json:

    {
      "order": "XYZ", "mode": "post",
      "clip": "Bob_Idle",                  # base clip the pose was dialed on
      "deltas": { "Bip01_R_UpperArm": { "rot": [..], "pos": [..] }, ... },
      "emote": { "name": "wave_custom", "baseClip": "Bob_Idle", "mod": "MyMod",
                 "build": "42" }
    }

`wire-emote` turns that into a drop-in emote for a mod:

  1. one renamed .x, baked from the base clip (deltas applied) and TRIMMED to a
     single key per bone so it holds a static pose
     -> <mod>/common/media/anims_X/Bob/Bob_<name>.x
  2. a self-contained AnimSet node gated on  emote == <name>  (looped so the
     pose holds until cancelled), matching vanilla emote nodes but flattened so
     it needs no x_extends
     -> <mod>/<build>/media/AnimSets/player/emote/<name>.xml

Trigger in-game with  player:playEmote("<name>")  (the editor's Preview button).
"""

import json
import os
import re

from . import x_edit
from . import paths


def _load_clip_text(pz, clip):
    if not pz:
        raise SystemExit("PZ install not found; pass --pz-install")
    src = os.path.join(pz, "media", "anims_X", "Bob", clip + ".x")
    if not os.path.isfile(src):
        raise SystemExit("vanilla clip not found: %s" % src)
    with open(src, "r", encoding="utf-8", errors="replace", newline="") as fh:
        return fh.read()


def _nonzero(v):
    return v and any(abs(float(c)) > 1e-9 for c in v)


def _apply_deltas(text, anim_set, deltas, order, mode):
    """Apply {bone: {rot,pos}} (or legacy [ex,ey,ez]) deltas to one clip's text."""
    applied = []
    for bone, delta in (deltas or {}).items():
        rot, pos = (delta.get("rot"), delta.get("pos")) if isinstance(delta, dict) \
            else (delta, None)
        rec = {"bone": bone}
        if _nonzero(rot):
            dq = x_edit.euler_to_quat(rot[0], rot[1], rot[2], order)
            try:
                text, keys, _ = x_edit.apply_delta(text, bone, dq, anim_set=anim_set, mode=mode)
                rec["rot"], rec["rotKeys"] = rot, keys
            except ValueError as e:
                rec["rotSkipped"] = str(e)
        if _nonzero(pos):
            try:
                text, tkeys, _ = x_edit.apply_translation_delta(text, bone, pos, anim_set=anim_set)
                rec["pos"], rec["posKeys"] = pos, tkeys
            except ValueError as e:
                rec["posSkipped"] = str(e)
        applied.append(rec)
    return text, applied


# One key entry: "<time>;<count>;<comma values>;;" (count is 4 for R, 3 for S/T).
_KEY_ENTRY = re.compile(r"(-?[\d.eE+-]+\s*;\s*\d+\s*;[^;]*;;)")
# An AnimationKey block; key bodies hold no nested braces, so non-greedy .*? to
# the first } is exact.
_BLOCK = re.compile(r"(AnimationKey\s+[RST]\s*\{)(.*?)(\})", re.S)


def _to_single_frame(text, anim_set):
    """Trim every AnimationKey block in `anim_set` to its first key, so the clip
    holds a single static pose. Returns (text, blocks_trimmed)."""
    lo, hi = x_edit._find_set_span(text, anim_set)
    seg = text[lo:hi]

    def fix(m):
        head, body, tail = m.group(1), m.group(2), m.group(3)
        mm = re.match(r"(\s*\d+\s*;\s*)(\d+)(\s*;\s*)(.*)", body, re.S)
        if not mm:
            return m.group(0)
        pre, _count, sep, rest = mm.group(1), mm.group(2), mm.group(3), mm.group(4)
        em = _KEY_ENTRY.search(rest)
        if not em:
            return m.group(0)
        # keyType line + count forced to 1 + the single first key, terminated ';'
        return head + pre + "1" + sep + em.group(1) + ";\n" + tail

    seg2, n = _BLOCK.subn(fix, seg)
    return text[:lo] + seg2 + text[hi:], n


def _build_node_xml(name, anim_name, blend_time):
    """Self-contained emote AnimSet node, gated on emote == <name>, looped so the
    one-frame pose holds until the player cancels (mirrors vanilla looped.xml)."""
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<animNode>\n"
        "  <m_Name>%s</m_Name>\n"
        "  <m_AnimName>%s</m_AnimName>\n"
        "  <m_Looped>true</m_Looped>\n"
        "  <m_BlendTime>%s</m_BlendTime>\n"
        "  <m_EarlyTransitionOut>true</m_EarlyTransitionOut>\n"
        "  <m_SpeedScale>1.00</m_SpeedScale>\n"
        "  <m_SyncTrackingEnabled>false</m_SyncTrackingEnabled>\n"
        "  <m_Conditions>\n"
        "    <m_Name>emote</m_Name>\n"
        "    <m_Type>STRING</m_Type>\n"
        "    <m_Value>%s</m_Value>\n"
        "  </m_Conditions>\n"
        "  <m_Events>\n"
        "    <m_EventName>EmoteLooped</m_EventName>\n"
        "    <m_Time>End</m_Time>\n"
        "    <m_ParameterValue></m_ParameterValue>\n"
        "  </m_Events>\n"
        "</animNode>\n"
    ) % (name, anim_name, blend_time, name)


def wire_emote(save_json, mod_root, pz_install, build=None, dry_run=False):
    with open(save_json, "r", encoding="utf-8") as fh:
        spec = json.load(fh)

    em = spec.get("emote")
    if not em:
        raise SystemExit("editor save has no 'emote' block")
    name = em.get("name")
    if not name:
        raise SystemExit("emote.name is required")
    base_clip = em.get("baseClip") or spec.get("clip")
    if not base_clip:
        raise SystemExit("emote.baseClip (or top-level clip) is required")

    order = spec.get("order", "XYZ")
    mode = spec.get("mode", "post")
    mod_root = os.path.abspath(mod_root)
    build = paths.resolve_build(mod_root, explicit=build, from_json=em.get("build"))
    anim_name = "Bob_" + name

    anims_dir = os.path.join(mod_root, "common", "media", "anims_X", "Bob")
    node_dir = os.path.join(mod_root, build, "media", "AnimSets", "player", "emote")

    report = {
        "ok": True, "name": name, "baseClip": base_clip, "anim": anim_name,
        "mod_root": mod_root, "build": build, "clip": None, "node": None,
    }

    # 1. bake -> apply deltas -> trim to one frame -> rename the set
    text = _load_clip_text(pz_install, base_clip)
    text, applied = _apply_deltas(text, base_clip, spec.get("deltas"), order, mode)
    text, frames = _to_single_frame(text, base_clip)
    text, _ = x_edit.rename_set(text, base_clip, anim_name)
    report["applied"] = applied
    report["blocksTrimmed"] = frames

    clip_path = os.path.join(anims_dir, anim_name + ".x")
    node_path = os.path.join(node_dir, name + ".xml")
    if not dry_run:
        os.makedirs(anims_dir, exist_ok=True)
        os.makedirs(node_dir, exist_ok=True)
        with open(clip_path, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        with open(node_path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(_build_node_xml(name, anim_name, "0.30"))
    report["clip"] = clip_path
    report["node"] = node_path
    return report
