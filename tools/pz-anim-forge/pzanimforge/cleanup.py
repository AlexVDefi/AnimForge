"""Remove the dev-only AnimForge artifacts a FINISHED reload set no longer needs, leaving the real,
built reload nodes + posed clips intact.

Two kinds of leftover are cleared:
  1. Unbuilt preseed STUBS - AnimSet nodes still carrying the `__AnimForgePreseedStub__` marker (a
     reload that was pre-seeded but never actually built), plus the throwaway stub clip each one names.
  2. Clean-base COPIES - `Bob_*_afclean.x`. These are only a bake-time source (the shipped reload clips
     are self-contained renamed copies), so a finished/shipping set doesn't need them. They regenerate
     from "Clean base clips" if you edit the set again, so only run this once the set is done.

Idempotent, dry-run supported. Only ever deletes files that match the two patterns above.
"""
import os
import re

from . import paths
from . import preseed as preseedmod


def cleanup(mod_root, remove_clean_base=True, dry_run=False):
    mod_root = os.path.abspath(mod_root)
    build = paths.resolve_build(mod_root)
    nodes_dir = os.path.join(mod_root, build, "media", "AnimSets", "player", "actions")
    anims_dir = os.path.join(mod_root, "common", "media", "anims_X", "Bob")

    report = {
        "ok": True, "mod_root": mod_root, "build": build, "dry_run": dry_run,
        "removed": {"stubNodes": [], "stubClips": [], "cleanBase": []},
        "kept": {"realNodes": []},
    }

    # 1. unbuilt preseed stub nodes + the clip each one references
    if os.path.isdir(nodes_dir):
        for fn in sorted(os.listdir(nodes_dir)):
            if not fn.lower().endswith(".xml"):
                continue
            path = os.path.join(nodes_dir, fn)
            if not preseedmod._is_own_stub(path):
                report["kept"]["realNodes"].append(fn)
                continue
            try:
                with open(path, "r", encoding="utf-8", errors="ignore") as fh:
                    am = re.search(r"<m_AnimName>\s*([\s\S]*?)\s*</m_AnimName>", fh.read())
            except OSError:
                am = None
            clip_name = am.group(1).strip() if am else None
            if not dry_run:
                os.remove(path)
            report["removed"]["stubNodes"].append(path)
            if clip_name:
                clip_path = os.path.join(anims_dir, clip_name + ".x")
                if os.path.isfile(clip_path):
                    if not dry_run:
                        os.remove(clip_path)
                    report["removed"]["stubClips"].append(clip_path)

    # 2. clean-base copies (Bob_*_afclean.x) - a bake-time source only
    if remove_clean_base and os.path.isdir(anims_dir):
        for fn in sorted(os.listdir(anims_dir)):
            if fn.lower().endswith("_afclean.x"):
                path = os.path.join(anims_dir, fn)
                if not dry_run:
                    os.remove(path)
                report["removed"]["cleanBase"].append(path)

    report["counts"] = {k: len(v) for k, v in report["removed"].items()}
    return report
