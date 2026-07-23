"""Request lifecycle for the in-game editor's "Bake clean base clips" button.

The reload-set editor sends the project's stock base clips here; we write a deduped, despiked copy
of each into the mod (gunworks.bake_clean_base_clips) and publish a result the editor polls to
retarget its stage baseClips. Mirrors prop_fix's claim/result protocol - pure file work, never
raises out of the watcher loop.
"""
import json
import os

from . import gunworks


def _resolve_mod_root(mod, mod_roots):
    for root in mod_roots or []:
        p = os.path.join(root, mod)
        if os.path.isdir(p):
            return os.path.abspath(p)
    return None


def bake_from_request(spec, mod_roots, pz_install):
    """Run one clean-base request dict {mod, baseClips:[...]}. Never raises.

    Gated to a real mod under a `mods/` tree (same guard the prop-fix path applies) so a request can
    only ever write clean clips into a mod, never anywhere else on the machine."""
    try:
        root = _resolve_mod_root(spec.get("mod"), mod_roots)
        if not root:
            return {"ok": False, "error": "mod %r not found under a mods root" % spec.get("mod")}
        if "/mods/" not in root.replace("\\", "/").lower():
            return {"ok": False, "error": "mod root is not under a 'mods' directory"}
        base_clips = spec.get("baseClips") or []
        if not base_clips:
            return {"ok": False, "error": "no baseClips in request"}
        return gunworks.bake_clean_base_clips(root, pz_install, base_clips)
    except Exception as e:
        return {"ok": False, "error": "clean-base failed: %s" % e}


def _write_result(channel_dir, result):
    tmp = os.path.join(channel_dir, "clean_base_result.json.%d.tmp" % os.getpid())
    final = os.path.join(channel_dir, "clean_base_result.json")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(result, fh)
    os.replace(tmp, final)


def process_pending_request(channel_dir, mod_roots, pz_install):
    """If clean_base_request.json is waiting, atomically claim it, bake the clean clips, and publish
    clean_base_result.json. Returns the result dict, or None if there was no request."""
    req = os.path.join(channel_dir, "clean_base_request.json")
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
            result = bake_from_request(spec, mod_roots, pz_install)
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
