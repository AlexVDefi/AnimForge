"""Standalone discovery scanner for the in-game Anim Forge editor.

The editor's "Mods" tab and its "Edit reload attachments" picker read two cache files from its channel
dir (~/Zomboid/Lua/AnimForge/):

  * mod_clips.json      = {"clips": [...]}                 -- every mod's custom .glb/.x clips
  * reload_markers.json = {"reloads": [...], "partsByGun": {...}}
                                                           -- Gunworks reload nodes + attachment markers

This module builds both by scanning your installed mods on disk, so the editor is fully usable without
any external helper. Run `pz-anim-forge scan` once (or whenever you add/change a mod), then open the
editor.

Only reads files; the sole writes are the two JSON caches inside the channel dir.
"""
import json
import os
import re

from . import prop_fix


# ------------------------------------------------------------------- mod discovery ---

def default_mod_roots():
    """Directories that each hold installed mods. Defaults: ~/Zomboid/mods (where Project Zomboid loads
    mods, one mod per subfolder) AND ~/Zomboid/Workshop (local Workshop staging, where each item nests
    its mod root(s) under <item>/Contents/mods/<mod>). _iter_mod_dirs unwraps the Workshop layout
    automatically. Override/extend with --mods-dir / --mod-root."""
    home = os.path.expanduser("~")
    return [os.path.join(home, "Zomboid", "mods"),
            os.path.join(home, "Zomboid", "Workshop")]


def _child_dir(parent, name_lower):
    """The immediate subdirectory of `parent` whose name matches `name_lower` case-insensitively (so
    'Contents' vs 'contents' both work), or None."""
    try:
        for n in os.listdir(parent):
            if n.lower() == name_lower and os.path.isdir(os.path.join(parent, n)):
                return os.path.join(parent, n)
    except OSError:
        pass
    return None


def contents_mods_dir(item_dir):
    """`<item_dir>/Contents/mods` if it exists (the ~/Zomboid/Workshop staging wrapper: a workshop item
    nests its actual mod root(s) under Contents/mods/<mod>), else None. Case-tolerant."""
    contents = _child_dir(item_dir, "contents")
    return contents and _child_dir(contents, "mods")


def _mod_roots_under(base):
    """Yield (modName, modRootPath) for each mod under a mods container `base`, transparently unwrapping
    the Workshop staging layout. A ~/Zomboid/mods subfolder IS a mod; a ~/Zomboid/Workshop subfolder is
    a workshop ITEM whose real mod root(s) live under <item>/Contents/mods/<mod> (one item can bundle
    several mods). Detected by a Contents/mods dir on the subfolder."""
    for name in sorted(os.listdir(base)):
        sub = os.path.join(base, name)
        if not os.path.isdir(sub):
            continue
        cm = contents_mods_dir(sub)
        if cm:
            for m in sorted(os.listdir(cm)):
                mp = os.path.join(cm, m)
                if os.path.isdir(mp):
                    yield m, mp
        else:
            yield name, sub


def _iter_mod_dirs(mods_dirs, mod_roots):
    """Yield (modName, modRootPath) for every mod: each explicit --mod-root, plus every mod under each
    --mods-dir (immediate subfolder, or a Workshop item's Contents/mods/<mod>). Deduped by mod name."""
    seen = set()
    for root in mod_roots or []:
        root = os.path.abspath(root)
        if os.path.isdir(root):
            name = os.path.basename(root.rstrip("\\/"))
            if name not in seen:
                seen.add(name)
                yield name, root
    for base in mods_dirs or []:
        if not os.path.isdir(base):
            continue
        for name, path in _mod_roots_under(base):
            if name not in seen:
                seen.add(name)
                yield name, path


def _walk_files(root, want, depth=10):
    """Yield absolute paths of files matching predicate `want(name, fullpath)`, bounded in depth,
    skipping .git / node_modules."""
    root = os.path.abspath(root)
    base_depth = root.rstrip("\\/").count(os.sep)
    for dirpath, dirnames, filenames in os.walk(root):
        if dirpath.count(os.sep) - base_depth > depth:
            dirnames[:] = []
            continue
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules")]
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            if want(fn, full):
                yield full


# ------------------------------------------------------------------ clip discovery ---

def engine_anim_name(src_path):
    """The engine's getAnimName form: media-relative path, lowercased, extension and a leading
    anims/ or anims_x/ segment stripped. Returns None if the file is not under a media/ dir."""
    norm = src_path.replace("\\", "/")
    m = re.search(r"/media/(.+)$", norm, re.IGNORECASE)
    if not m:
        return None
    rel = m.group(1).lower()
    dot = rel.rfind(".")
    if dot > -1:
        rel = rel[:dot]
    if rel.startswith("anims/"):
        rel = rel[len("anims/"):]
    elif rel.startswith("anims_x/"):
        rel = rel[len("anims_x/"):]
    return rel


def list_anim_clips(mods_dirs, mod_roots):
    """Every mod's custom animation clips (.glb/.x under a media/ dir). Matches the editor's ModClip
    schema: {mod, name, stem, format, srcPath, animsSubdir}."""
    clips = []
    for mod_name, base in _iter_mod_dirs(mods_dirs, mod_roots):
        for src in _walk_files(base, lambda fn, full: fn.lower().endswith((".glb", ".x"))):
            name = engine_anim_name(src)
            if not name:
                continue
            rel_dir = os.path.relpath(os.path.dirname(src), base).replace("\\", "/")
            stem = re.sub(r"\.[^.]+$", "", os.path.basename(src))
            is_glb = src.lower().endswith(".glb")
            entry = {
                "mod": mod_name,
                "name": name,
                "stem": stem,
                "format": "glb" if is_glb else "x",
                "srcPath": src,
                "animsSubdir": rel_dir,
            }
            # Prop-socket rotation state, so the editor's "Correct ramrod rotation" tick knows which
            # off-hand/gun sockets this clip still needs fixed (and starts ticked when already baked).
            # Only animation glbs (under anims_x/anims) can have prop sockets - skip the many model
            # glbs some mods ship, both to keep scan fast and to avoid parsing non-clips. Best-effort.
            is_anim = re.search(r"/anims(_x)?/", src.replace("\\", "/"), re.IGNORECASE) is not None
            if is_glb and is_anim:
                try:
                    st = prop_fix.state_gltf(prop_fix.read_gltf(src))
                    if st["present"]:
                        entry["propBones"] = st["present"]
                        entry["propFix"] = st["fixed"]
                except Exception:
                    pass
            clips.append(entry)
    clips.sort(key=lambda c: (c["mod"].lower(), c["stem"].lower()))
    return clips


# --------------------------------------------------- Gunworks reload-node discovery ---

GW_EVENTS = {"gwSetProp", "gwSetHandProp", "gwPartToHand", "gwPartToGun", "gwSetPart"}


def _parse_event_block(block):
    nm = re.search(r"<m_EventName>\s*([\s\S]*?)\s*</m_EventName>", block)
    if not nm:
        return None
    val = re.search(r"<m_ParameterValue>([\s\S]*?)</m_ParameterValue>", block)
    tpc = re.search(r"<m_TimePc>\s*([\s\S]*?)\s*</m_TimePc>", block)
    tm = re.search(r"<m_Time>\s*([\s\S]*?)\s*</m_Time>", block)
    rec = {"event": nm.group(1), "value": val.group(1) if val else ""}
    if tpc:
        try:
            rec["timePc"] = float(tpc.group(1))
        except ValueError:
            rec["timePc"] = 0.0
    elif tm:
        rec["time"] = tm.group(1)
    return rec


def _parse_reload_nodes(xml, node_file, mod):
    out = []
    for m in re.finditer(r"<animNode>([\s\S]*?)</animNode>", xml):
        node = m.group(1)
        gw = re.search(
            r"<m_Conditions>\s*<m_Name>\s*GunworksReloadAnim\s*</m_Name>[\s\S]*?"
            r"<m_StringValue>\s*([\s\S]*?)\s*</m_StringValue>", node)
        if not gw:
            continue
        clip = re.search(r"<m_AnimName>\s*([\s\S]*?)\s*</m_AnimName>", node)
        markers = []
        for em in re.finditer(r"<m_Events>([\s\S]*?)</m_Events>", node):
            rec = _parse_event_block(em.group(1))
            if rec and rec["event"] in GW_EVENTS:
                markers.append(rec)
        out.append({
            "mod": mod, "animId": gw.group(1),
            "clip": clip.group(1) if clip else "",
            "nodeFile": node_file, "markers": markers,
        })
    return out


def _mod_reload_prop_items(base):
    """Item fullTypes ("Mod.Item") referenced in a mod's reload-registration Lua - the marker
    whitelist for the item dropdown."""
    found = set()

    def want(fn, full):
        low = fn.lower()
        return low == "registerreloadanims.lua" or (
            re.search(r"register.*reload.*\.lua$", low) is not None)

    for f in _walk_files(base, want):
        try:
            with open(f, "r", encoding="utf-8", errors="ignore") as fh:
                text = fh.read()
        except OSError:
            continue
        if "partState" not in text:
            continue
        for q in re.finditer(r"""["']([A-Za-z0-9_]+\.[A-Za-z0-9_]+)["']""", text):
            found.add(q.group(1))
    return sorted(found)


def _mod_weapon_parts_by_gun(base, out):
    """Scan a mod's .txt item scripts for WeaponPart items: gun fullType -> PartType -> [part
    fullTypes]. Feeds the gwSetPart editor's location + part dropdowns."""
    def want(fn, full):
        return fn.lower().endswith(".txt") and "scripts" in full.replace("\\", "/").lower()

    for f in _walk_files(base, want):
        try:
            with open(f, "r", encoding="utf-8", errors="ignore") as fh:
                text = fh.read()
        except OSError:
            continue
        mod_match = re.search(r"\bmodule\s+([A-Za-z0-9_]+)\s*\{", text)
        if not mod_match:
            continue
        module_name = mod_match.group(1)
        for im in re.finditer(r"\bitem\s+([A-Za-z0-9_]+)\s*\{([^}]*)\}", text):
            body = im.group(2)
            pt = re.search(r"\bPartType\s*=\s*([A-Za-z0-9_]+)", body)
            mo = re.search(r"\bMountOn\s*=\s*([^,\r\n]+)", body)
            if not pt or not mo:
                continue
            full_type = "%s.%s" % (module_name, im.group(1))
            for gun in (s.strip() for s in mo.group(1).split(";")):
                if not gun:
                    continue
                by_type = out.setdefault(gun, {})
                lst = by_type.setdefault(pt.group(1), [])
                if full_type not in lst:
                    lst.append(full_type)


def list_reload_nodes(mods_dirs, mod_roots):
    """Every mod's Gunworks reload AnimSet nodes + markers + prop whitelist, plus the per-gun parts
    map. Returns (reloads, partsByGun)."""
    reloads = []
    parts_by_gun = {}
    for mod_name, base in _iter_mod_dirs(mods_dirs, mod_roots):
        xml_files = list(_walk_files(
            base, lambda fn, full: fn.lower().endswith(".xml") and "animsets" in full.replace("\\", "/").lower()))
        _mod_weapon_parts_by_gun(base, parts_by_gun)
        if not xml_files:
            continue
        prop_items = _mod_reload_prop_items(base)
        for xf in xml_files:
            try:
                with open(xf, "r", encoding="utf-8", errors="ignore") as fh:
                    xml = fh.read()
            except OSError:
                continue
            if "GunworksReloadAnim" not in xml:
                continue
            for n in _parse_reload_nodes(xml, xf, mod_name):
                n["propItems"] = prop_items
                reloads.append(n)
    reloads.sort(key=lambda r: (r["mod"].lower(), r["animId"].lower()))
    return reloads, parts_by_gun


# --------------------------------------------------------------------- entry point ---

def scan(channel_dir, mods_dirs=None, mod_roots=None):
    """Build both caches into the channel dir. Returns a summary dict."""
    if not mods_dirs and not mod_roots:
        mods_dirs = default_mod_roots()
    mods_dirs = mods_dirs or []
    mod_roots = mod_roots or []

    clips = list_anim_clips(mods_dirs, mod_roots)
    reloads, parts_by_gun = list_reload_nodes(mods_dirs, mod_roots)

    os.makedirs(channel_dir, exist_ok=True)
    clips_path = os.path.join(channel_dir, "mod_clips.json")
    reloads_path = os.path.join(channel_dir, "reload_markers.json")
    with open(clips_path, "w", encoding="utf-8") as fh:
        json.dump({"clips": clips}, fh)
    with open(reloads_path, "w", encoding="utf-8") as fh:
        json.dump({"reloads": reloads, "partsByGun": parts_by_gun}, fh)

    mods_with_clips = sorted({c["mod"] for c in clips})
    mods_with_reloads = sorted({r["mod"] for r in reloads})
    return {
        "ok": True,
        "channelDir": channel_dir,
        "scanned": {"modsDirs": [os.path.abspath(d) for d in mods_dirs],
                    "modRoots": [os.path.abspath(d) for d in mod_roots]},
        "clips": {"count": len(clips), "mods": mods_with_clips, "file": clips_path},
        "reloads": {"count": len(reloads), "mods": mods_with_reloads, "file": reloads_path,
                    "gunsWithParts": len(parts_by_gun)},
    }
