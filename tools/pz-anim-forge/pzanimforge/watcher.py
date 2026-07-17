"""Unified auto-baker: ONE watcher for every Anim Forge save type.

The in-game editor writes its saves to the channel dir (~/Zomboid/Lua/AnimForge/). This watches for
each kind and bakes it into the target mod the instant you Save/Export - no manual bake step:

  * reload-attachment markers  -> retime the mod's reload node XML + hot-reload it live in-game
  * grip "Export set"          -> bake-set (renamed .x) + wire-set (gated AnimSet XML + Lua hook)
  * Gunworks reload pack        -> wire-gunworks (stage clips + nodes + RegisterReloadAnims.lua)
  * emote                       -> wire-emote (1-frame .x + emote-gated node)
  * mod .glb clip edit          -> bake-glb (rewrite the bone keys in place / to a chosen file)

The reload-marker path uses bake_request's claim/result protocol so the editor shows "baked" and the
change goes live with no restart; the rest are detected from anim_edit.json and baked via the CLI.
Pure file work: opens no sockets, needs no external helper. A bare single-clip "Save .x" (an override
with no target mod in the save) is the one case that can't auto-bake - the log prints the manual line.
"""
import json
import os
import subprocess
import sys
import time

from . import bake_request
from . import prop_fix


def _resolve_mod(mod, mod_roots):
    if not mod:
        return None
    for root in mod_roots:
        p = os.path.join(root, mod)
        if os.path.isdir(p):
            return p
    return None


def _run_cli(cli, args, log):
    r = subprocess.run([sys.executable, cli] + args, capture_output=True, text=True)
    if r.returncode != 0:
        log("  bake failed:\n" + (r.stderr or r.stdout).strip())
        return None
    try:
        return json.loads(r.stdout)
    except Exception:
        return r.stdout


def _refresh_reload_cache(channel_json, mod_roots, log):
    """Rebuild the editor's reload picker cache (reload_markers.json) after a gunworks bake, so the
    freshly baked node appears in "Edit reload attachments" without a manual `scan`. Non-fatal."""
    from .scan import scan
    channel_dir = os.path.dirname(channel_json)
    try:
        summary = scan(channel_dir, mods_dirs=mod_roots)
        log("  refreshed reload picker cache (%d reloads on disk)" % summary["reloads"]["count"])
    except Exception as e:
        log("  reload picker cache refresh failed: %s" % e)


def _route(spec, cli, channel_json, mod_roots, pz, log):
    """Dispatch one anim_edit.json save (everything except reload markers, which the request path
    owns) to the matching bake."""
    out = spec.get("output") or {}
    fmt = out.get("format")

    if fmt == "reloadMarkers":
        return  # handled by the reload-request path (keeps the live reload + the editor's status)

    if fmt == "glb":
        src = out.get("srcGlb")
        dst = out.get("dst") or src
        if not src:
            log("  glb save is missing srcGlb; skipping")
            return
        # Bake from a pristine copy of the source, not the live (possibly already-edited) file, so
        # re-saving an adjusted pose is non-cumulative - matching the .x path (always from vanilla).
        from . import glb_edit
        channel_dir = os.path.dirname(channel_json)
        try:
            pristine = glb_edit.pristine_source(channel_dir, src)
        except Exception as e:
            log("  (pristine capture failed, baking in place: %s)" % e)
            pristine = src
        r = _run_cli(cli, ["bake-glb", "--json", channel_json, "--src", pristine, "--dst", dst], log)
        if r is not None:
            try:
                glb_edit.record_baked(channel_dir, src, dst)
            except Exception:
                pass
            log("  baked mod glb (from pristine) -> %s" % dst)
        return

    s = spec.get("set") or {}
    if s.get("clips"):
        mod = _resolve_mod(s.get("mod"), mod_roots)
        if not mod:
            log("  grip set: mod '%s' not found under %s" % (s.get("mod"), ", ".join(mod_roots)))
            return
        _run_cli(cli, ["bake-set", "--json", channel_json, "--mod-root", mod, "--pz-install", pz or ""], log)
        _run_cli(cli, ["wire-set", "--json", channel_json, "--mod-root", mod, "--pz-install", pz or ""], log)
        log("  baked + wired grip set -> %s" % mod)
        return

    gw = spec.get("gunworks") or {}
    if gw.get("animId"):
        mod = _resolve_mod(gw.get("mod"), mod_roots)
        if not mod:
            log("  gunworks reload: mod '%s' not found (is block.mod set? enable the mod's dir under %s)"
                % (gw.get("mod"), ", ".join(mod_roots)))
            return
        _run_cli(cli, ["wire-gunworks", "--json", channel_json, "--mod-root", mod, "--pz-install", pz or ""], log)
        log("  built Gunworks reload pack -> %s" % mod)
        _refresh_reload_cache(channel_json, mod_roots, log)
        return

    em = spec.get("emote") or {}
    if em.get("name"):
        mod = _resolve_mod(em.get("mod"), mod_roots)
        if not mod:
            log("  emote: mod '%s' not found" % em.get("mod"))
            return
        _run_cli(cli, ["wire-emote", "--json", channel_json, "--mod-root", mod, "--pz-install", pz or ""], log)
        log("  built emote -> %s" % mod)
        return

    log("  single-clip save (override): no target mod in the save - bake it by hand, e.g.")
    log("      python cli.py bake --json \"%s\" --dst <mod>/common/media/anims_X/Bob/%s.x"
        % (channel_json, spec.get("clip", "Bob_Clip")))


def watch(channel_dir, cli_path, pz_install=None, mod_roots=None, interval=0.5, log=None):
    """Poll the channel dir forever, baking each save type as it appears."""
    if log is None:
        def log(msg):
            print(msg, flush=True)
    if not mod_roots:
        mod_roots = [os.path.join(os.path.expanduser("~"), "Zomboid", "mods")]
    channel_json = os.path.join(channel_dir, "anim_edit.json")

    log("Anim Forge auto-baker  (every save type)")
    log("  channel : %s" % channel_dir)
    log("  mods    : %s" % ", ".join(mod_roots))
    log("  live-reload : %s" % (
        "on  (%s)" % pz_install if pz_install
        else "OFF - reload edits bake but need a restart (set PZ_INSTALL_DIR to enable)"))
    log("  Save / Export in the editor; leave this open while modding (Ctrl+C to stop).")

    # Heartbeat the editor reads to show its "Auto-bake: LIVE" pill. Rewritten every ~2s; removed on
    # exit so the editor flips to "OFF" the moment this stops.
    status_path = os.path.join(channel_dir, "watcher_status.json")

    def write_status():
        try:
            os.makedirs(channel_dir, exist_ok=True)
            with open(status_path, "w", encoding="utf-8") as fh:
                json.dump({"ts": time.time(), "pid": os.getpid()}, fh)
        except OSError:
            pass

    write_status()
    last_status = time.time()

    last = None
    while True:
        try:
            now = time.time()
            if now - last_status >= 2.0:
                last_status = now
                write_status()
            # 1) reload-attachment markers: claim/bake/result + live-reload nudge.
            r = bake_request.process_pending_request(channel_dir, pz_install)
            if r is not None:
                if r.get("ok"):
                    log("  reload markers baked -> %s  (live-reload=%s)" % (r.get("dst"), r.get("liveReload")))
                else:
                    log("  reload markers FAILED: %s" % r.get("error"))

            # 1b) ramrod/prop-socket rotation fix: claim/fix/result (marker-guarded, idempotent).
            pf = prop_fix.process_pending_request(channel_dir, mod_roots)
            if pf is not None:
                if pf.get("ok"):
                    if pf.get("scope") == "mod":
                        log("  prop rotation fix: %d glb(s) fixed, %d already OK"
                            % (len(pf.get("fixed", [])), pf.get("skipped", 0)))
                    else:
                        log("  prop rotation fix -> %s  (fixed=%s)" % (pf.get("path"), pf.get("fixed")))
                    # Refresh the discovery cache so mod_clips.json's propFix tracks the fixed glb.
                    # Without this the editor reads a stale "still needs fixing" next session and
                    # would double-rotate on a live preview / no-op on a re-bake.
                    _refresh_reload_cache(channel_json, mod_roots, log)
                else:
                    log("  prop rotation fix FAILED: %s" % pf.get("error"))

            # 2) every other save type, detected from anim_edit.json.
            mt = os.path.getmtime(channel_json) if os.path.exists(channel_json) else None
            if mt and mt != last:
                last = mt
                time.sleep(0.2)  # let the in-game write settle
                try:
                    with open(channel_json, encoding="utf-8") as fh:
                        spec = json.load(fh)
                except Exception as e:
                    log("  (save not readable yet: %s)" % e)
                    continue
                log("save detected " + time.strftime("%H:%M:%S"))
                _route(spec, cli_path, channel_json, mod_roots, pz_install, log)
        except KeyboardInterrupt:
            try:
                os.remove(status_path)
            except OSError:
                pass
            log("stopped")
            return
        except Exception as e:  # never let one bad save kill the watcher
            log("  error: %s" % e)
        time.sleep(interval)
