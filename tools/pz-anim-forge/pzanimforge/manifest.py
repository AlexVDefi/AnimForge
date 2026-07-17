"""Load + validate a pz-anim-forge job manifest and expand it into per-clip
.x edits (the native loadX path - no glb).

Manifest schema (see config/jobs.handgun.json):
{
  "name": "handgun_hand_offset_v1",
  "pz_install": "D:/Games/.../ProjectZomboid",   # optional, auto-detected
  "source_anims_dir": "media/anims_X/Bob",         # relative to pz_install
  "delta": { "bone": "Bip01_R_Hand", "rotation_euler_deg": [0,4,-2],
             "rotation_order": "XYZ", "mode": "post" },
  "protected_bones": ["Dummy01", "Translation_Data"],
  "clips": [ { "src": "Bob_IdleAimHandgun.x", "clip": "Bob_IdleAimHandgun"
               # optional: "out" (new name -> renames set), "anim_set"
               #           ("ALL" edits every set in the file) } ],
  "output": { "mod_root": "c:/dev/mods/MyGunMod",
              "anims_subdir": "common/media/anims_X/Bob" }
}

Output is a .x per clip. With out == clip (default) it OVERRIDES the vanilla
clip globally (no AnimSet XML needed - the validated path). With a distinct
out it ships under a new name (set renamed to match) for a per-gun AnimNode.
"""

import json
import os

from .paths import default_pz_install

DEFAULT_ANIMS_SUBDIR = "common/media/anims_X/Bob"
DEFAULT_PROTECTED = ["Dummy01", "Translation_Data"]


def load(path):
    with open(path, "r", encoding="utf-8") as fh:
        m = json.load(fh)
    return validate(m)


def validate(m):
    if "clips" not in m or not m["clips"]:
        raise ValueError("manifest has no clips")
    if "output" not in m or "mod_root" not in m["output"]:
        raise ValueError("manifest.output.mod_root is required")
    m.setdefault("opts", {})
    m.setdefault("protected_bones", list(DEFAULT_PROTECTED))
    m.setdefault("source_anims_dir", "media/anims_X/Bob")
    if not m.get("pz_install"):
        m["pz_install"] = default_pz_install()
    if not m["pz_install"]:
        raise ValueError("pz_install not set and could not be auto-detected")
    m["output"].setdefault("anims_subdir", DEFAULT_ANIMS_SUBDIR)
    return m


def resolve_clip(m, clip):
    src = clip["src"]
    if not os.path.isabs(src):
        src = os.path.join(m["pz_install"], m["source_anims_dir"], src)
    src = os.path.normpath(src)
    clip_name = clip.get("clip") or os.path.splitext(os.path.basename(src))[0]
    # Default OVERRIDE behaviour: ship under the same name, so the mod .x
    # replaces the vanilla one with no AnimSet wiring (the validated path).
    out_name = clip.get("out") or clip_name
    out_path = os.path.normpath(os.path.join(
        m["output"]["mod_root"], m["output"]["anims_subdir"], out_name + ".x"))
    # Which AnimationSet inside the .x to edit: the clip name by default, or
    # None to edit the bone in every set the file contains.
    anim_set = clip.get("anim_set", clip_name)
    if anim_set in ("*", "ALL"):
        anim_set = None
    # For a gun-specific ship (out != clip), rename the set to match the new
    # filename so an AnimNode's m_AnimName can point at it.
    rename_to = out_name if (out_name != clip_name and anim_set) else None
    return {
        "src": src,
        "clip": clip_name,
        "out": out_name,
        "out_path": out_path,
        "anim_set": anim_set,
        "rename_to": rename_to,
    }


def to_job(m):
    delta = m.get("delta") or {}
    return {
        "protected_bones": m["protected_bones"],
        "delta": {
            "bone": delta.get("bone"),
            "euler": delta.get("rotation_euler_deg", [0.0, 0.0, 0.0]),
            "order": delta.get("rotation_order", "XYZ"),
            "mode": delta.get("mode", "post"),
        } if delta.get("bone") else None,
        "clips": [resolve_clip(m, c) for c in m["clips"]],
    }
