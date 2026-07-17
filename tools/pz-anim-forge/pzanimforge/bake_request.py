"""Shared core for the reload-attachment auto-bake.

The in-game "Save to mod" button writes two files into the Zomboid channel dir: `anim_edit.json`
(the reloadMarkers spec) and `rfx_bake_request.json` (a small trigger). This module turns that
request into an edited mod file + a live in-game reload. It backs two entry points that share the
same code so they can never drift: `cli.py watch-reload-bake` (the double-click .bat watcher) and
`cli.py bake-request` / `bake-editor` (a one-shot bake you can run by hand).

SAFETY. This does only file work -- no sockets, no network, no subprocesses. Every write is confined
to exactly what the bake needs:
  * the channel dir's own result/claim files,
  * an EXISTING AnimSet `.xml` that lives inside a `mods` tree (the reload node being retimed), and
  * the base install's `media/AnimSets/Defaults.xml`, rewritten with its OWN bytes (an mtime-only
    nudge) and only when it still parses as a Defaults doc.
`validate_node_file` is the gate that keeps a malformed/hostile request from pointing the edit at
anything else on disk.
"""
import json
import os
import time

from . import reload_markers


# ------------------------------------------------------------------ safety gate ---

def validate_node_file(node_file):
    """Return the absolute path of a reload node the bake is allowed to edit, or raise ValueError.

    Only an EXISTING `.xml` under a `.../mods/.../media/AnimSets/...` path qualifies. `os.path.abspath`
    collapses any `..`, and we never create files, so a request can only ever retime a real mod
    AnimSet node -- never touch anything else on the machine.
    """
    if not node_file or not isinstance(node_file, str):
        raise ValueError("no nodeFile")
    ap = os.path.abspath(node_file)
    slashed = ap.replace("\\", "/").lower()
    if not slashed.endswith(".xml"):
        raise ValueError("nodeFile must be a .xml")
    if "/mods/" not in slashed:
        raise ValueError("nodeFile must live under a 'mods' directory")
    if "/media/animsets/" not in slashed:
        raise ValueError("nodeFile must be under media/AnimSets")
    if not os.path.isfile(ap):
        raise ValueError("nodeFile does not exist (the bake never creates files)")
    return ap


# --------------------------------------------------------------- live-reload nudge ---

def nudge_defaults(pz_install_dir):
    """Fire the engine's AnimSets file watcher by rewriting Defaults.xml with its own bytes.

    The engine (AdvancedAnimator.checkModifiedFiles, every tick) reloads ALL AnimSets -- mod dirs
    included -- when a file under the base install's media/AnimSets changes, so this makes the mod
    edit go live with no restart. We READ the bytes first, only write them back if they still look
    like a valid Defaults doc, and never change the content -- so a hiccup can't corrupt this base
    game file. Returns True if the nudge happened.
    """
    if not pz_install_dir:
        return False
    trigger = os.path.join(pz_install_dir, "media", "AnimSets", "Defaults.xml")
    try:
        if not os.path.isfile(trigger):
            return False
        with open(trigger, "rb") as fh:
            buf = fh.read()
        if len(buf) == 0 or b"</Defaults>" not in buf:
            return False
        with open(trigger, "wb") as fh:
            fh.write(buf)
        return True
    except OSError:
        return False


# ------------------------------------------------------------------- the bake ---

def bake_from_editor(channel_dir, pz_install_dir=None):
    """Read `<channel_dir>/anim_edit.json` (a reloadMarkers save), retime the mod node XML in place,
    then nudge Defaults.xml for a live reload. Returns a result dict; never raises."""
    editor_json = os.path.join(channel_dir, "anim_edit.json")
    if not os.path.isfile(editor_json):
        return {"ok": False, "error": "no anim_edit.json in channel dir"}
    try:
        with open(editor_json, "r", encoding="utf-8") as fh:
            spec = json.load(fh)
    except Exception as e:
        return {"ok": False, "error": "anim_edit.json unreadable: %s" % e}

    out = spec.get("output") or {}
    if out.get("format") != "reloadMarkers":
        return {"ok": False, "error": "anim_edit.json is not a reloadMarkers save"}
    try:
        node = validate_node_file(out.get("nodeFile"))
    except ValueError as e:
        return {"ok": False, "error": "rejected nodeFile: %s" % e}

    markers = out.get("markers") or spec.get("markers") or []
    try:
        report = reload_markers.edit_file(node, node, markers)
    except Exception as e:
        return {"ok": False, "error": "bake failed: %s" % e}

    live = nudge_defaults(pz_install_dir)
    return {"ok": True, "src": node, "dst": node, "report": report, "liveReload": live}


# ---------------------------------------------------------- request-file lifecycle ---

def _write_result(channel_dir, result):
    """Publish the result atomically so the game's Lua poll never reads a half-written file. The tmp
    is per-process (pid in the name): with several bake watchers running
    two bakes could otherwise write the SAME shared tmp concurrently and produce a corrupt result."""
    tmp = os.path.join(channel_dir, "rfx_bake_result.json.%d.tmp" % os.getpid())
    final = os.path.join(channel_dir, "rfx_bake_result.json")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(result, fh)
    os.replace(tmp, final)


def process_pending_request(channel_dir, pz_install_dir=None):
    """If a bake request is waiting, atomically claim it (so multiple watchers can run without
    double-processing), bake, and publish the result. Returns the result dict, or
    None if there was no request (or another watcher won the claim)."""
    req = os.path.join(channel_dir, "rfx_bake_request.json")
    if not os.path.isfile(req):
        return None
    claim = "%s.%d.claim" % (req, os.getpid())  # unique per process -> no cross-watcher clobber
    try:
        os.replace(req, claim)  # atomic; only one claimer wins, the rest get OSError
    except OSError:
        return None
    ts = None
    try:
        try:
            with open(claim, "r", encoding="utf-8") as fh:
                ts = json.load(fh).get("ts")
        except Exception:
            ts = None
        result = bake_from_editor(channel_dir, pz_install_dir)
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


def watch(channel_dir, pz_install_dir=None, interval=0.5, log=None):
    """Poll the channel dir for bake requests and process them, forever. Pure file work -- opens no
    sockets and reaches nothing outside the channel dir, the validated mod node, and Defaults.xml."""
    if log is None:
        def log(msg):
            print(msg, flush=True)  # flush so the .bat console shows each line as it happens
    log("pz-anim-forge reload auto-bake watcher")
    log("  channel : %s" % channel_dir)
    log("  live-reload : %s" % (
        "on  (%s)" % pz_install_dir if pz_install_dir
        else "OFF - bake only, restart to see changes (set PZ_INSTALL_DIR to enable)"))
    log("  watching for 'Save to mod' clicks... leave this window open while modding (Ctrl+C to stop)")
    while True:
        try:
            result = process_pending_request(channel_dir, pz_install_dir)
            if result is not None:
                if result.get("ok"):
                    log("  baked %s  (live-reload=%s)" % (result.get("dst"), result.get("liveReload")))
                else:
                    log("  FAILED: %s" % result.get("error"))
        except Exception as e:  # keep the watcher alive no matter what a single request does
            log("  error: %s" % e)
        time.sleep(interval)
