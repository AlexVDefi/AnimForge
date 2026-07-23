"""Pre-seed stub Gunworks reload nodes + clips so a NEW reload hot-loads with NO game restart.

WHY THIS EXISTS
PZ indexes every mod file into ZomboidFileSystem.activeFileMap at BOOT. A node .xml created AFTER boot
is not in that map, so AnimState.Parse -> resolveFileOrGUID cannot turn its relative path into an
absolute one and the load fails with FileNotFoundException -- the new reload node never loads until the
next restart (observed live: refreshAnimSets -> AnimNode.Parse -> FileNotFoundException). Separately, a
mod's anims_X dir only gets a live file-watcher if it held >=1 clip at boot
(ModelManager.AnimDirReloader, bHasAnims). So a brand-new reload can't go live at all.

A stub present AT BOOT fixes both: the stub node reserves the node's path in activeFileMap, and the
stub .x puts a clip in the anims dir so its watcher registers. Then the in-game "Export reload pack"
OVERWRITES the stub with the real node + posed clip, the live-reload nudge re-parses the node, and the
anim watcher reloads the clip -- all live, no restart.

The stub node is INERT: it gates on an anim variable the engine never sets, so it can never be selected
before the real export replaces it, and (because that variable is NOT GunworksReloadAnim) the in-game
reload picker's scan skips it. The stub .x is a generic vanilla reload clip renamed -- throwaway, since
it is never played (inert node) and is overwritten on the first export.

USAGE (run BEFORE launching the game):
    python cli.py preseed --mod-root <mod> --reload NAM4:magazine --reload NAFamas:magazine
or auto-discover from the mod's existing RegisterReloadAnims_*.lua:
    python cli.py preseed --mod-root <mod> --from-mod

Idempotent + non-destructive: an existing REAL node/clip is kept (never clobbered) unless --force; our
own stub nodes are refreshed in place.
"""
import os
import re

from . import gunworks
from . import paths
from . import x_edit


# archetype -> ordered reload stages (canonical keys). Mirrors tools/pz-anim-forge gen_categories.py
# RELOAD_ARCHETYPES (loadShort is magazine-fed only). Stages only: the stub clip uses one generic
# source, so the per-stage base clips are not needed here.
ARCHETYPE_STAGES = {
    "magazine": ["load", "loadShort", "rack", "unload"],
    "magazinehandgun": ["load", "loadShort", "rack", "unload"],
    "shotgun": ["load", "rack", "unload"],
    "revolver": ["load", "rack", "unload"],
    "boltactionnomag": ["load", "rack", "unload"],
    "doublebarrel": ["load", "rack", "unload"],
    "lever": ["load", "rack", "unload"],
}

# "magazinehandgun" is an editor-only alias that saves as "magazine" (gunworks.py); accept both.
_ARCH_ALIAS = {"magazinehandgun": "magazine"}

# The DISTINCT vanilla base clips each archetype's stages default to (mirrors gen_categories.py
# RELOAD_ARCHETYPES). Pre-seeding the despiked clean copy of these so it's present AT BOOT means the
# editor's clean-base preview works with no restart (the editor retargets its stage baseClips to the
# same <clip>_afclean names, and a brand-new clip only loads at boot). Keyed by the editor archetype
# (magazine vs magazinehandgun differ: rifle vs handgun base).
ARCHETYPE_BASE_CLIPS = {
    "magazine":        ["Bob_Reload_Rifle_Load", "Bob_Reload_Rifle_Rack"],
    "magazinehandgun": ["Bob_Reload_Handgun_Load", "Bob_Reload_Handgun_Rack"],
    "shotgun":         ["Bob_Reload_Shotgun_Load", "Bob_Reload_Shotgun_Rack"],
    "revolver":        ["Bob_Reload_Revolver_Load", "Bob_Reload_Revolver_Rack"],
    "boltactionnomag": ["Bob_Reload_Shotgun_Load", "Bob_Reload_Bolt_Rack"],
    "doublebarrel":    ["Bob_Reload_DBShotgun_Load", "Bob_Reload_DBShotgun_Rack"],
    "lever":           ["Bob_Reload_Lever_Load", "Bob_Reload_Lever_Rack"],
}

# A generic, always-present vanilla reload clip used as the throwaway stub-clip source.
_STUB_CLIP_SOURCE = "Bob_Reload_Rifle_Load"

# A condition on an anim variable the engine never sets, so a stub node can NEVER be selected before
# the real export overwrites it. NOT GunworksReloadAnim, so the reload-picker scan (scan.py) skips it.
_STUB_CONDITION = "__AnimForgePreseedStub__"


def _stub_node_xml(node_name, anim_name):
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<animNode>\n"
        "  <m_Name>%s</m_Name>\n"
        "  <m_AnimName>%s</m_AnimName>\n"
        "  <m_Looped>false</m_Looped>\n"
        "  <m_SpeedScale>ReloadSpeed</m_SpeedScale>\n"
        "  <m_ConditionPriority>10</m_ConditionPriority>\n"
        "  <m_Conditions>\n"
        "    <m_Name>%s</m_Name>\n"
        "    <m_Type>STRING</m_Type>\n"
        "    <m_StringValue>never</m_StringValue>\n"
        "  </m_Conditions>\n"
        "</animNode>\n"
    ) % (node_name, anim_name, _STUB_CONDITION)


def _is_own_stub(path):
    """True if `path` is one of OUR stub nodes (safe to refresh), not a real reload node."""
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as fh:
            return _STUB_CONDITION in fh.read()
    except OSError:
        return False


# A trailing weapon-type word dropped from the item name so the derived animId stays short + readable
# (M4CARBINE -> M4 -> NAM4). Only the exact trailing word is removed; G36C / BOLTER keep their names.
_WEAPON_SUFFIXES = ("CARBINE", "RIFLE", "PISTOL", "REVOLVER", "SHOTGUN", "SMG", "ASSAULT", "GUN")

# An `item` block that reads as a firearm. Item bodies are flat (no nested braces) in PZ scripts.
_ITEM_RE = re.compile(r"\bitem\s+([A-Za-z0-9_]+)\s*\{([^{}]*)\}")
_MODULE_RE = re.compile(r"\bmodule\s+([A-Za-z0-9_]+)\s*\{")


def gun_anim_id(module, item):
    """Derive a reload animId from a gun's module + item name: strip a trailing common weapon-type word,
    then prefix the module namespace. NA + M4CARBINE -> NAM4; NA + FAMAS -> NAFAMAS; NA + G36C -> NAG36C.
    Deterministic, so the in-game editor can auto-fill the SAME id when a gun is picked (matches the stub)."""
    name = item
    up = name.upper()
    for suf in _WEAPON_SUFFIXES:
        if up.endswith(suf) and len(up) > len(suf):
            name = name[:len(name) - len(suf)]
            break
    return module + name


def guns_from_mod(mod_root):
    """Discover every gun defined in the mod's item scripts, as (animId, archetype, fullType). A gun is
    an `item` block that reads as a firearm (ItemType weapon / SubCategory Firearm / IsAimedFirearm).
    Archetype is `magazine` when the item declares a MagazineType; a gun with none is returned with a
    `None` archetype so the caller can flag it (a non-mag archetype can't be inferred reliably)."""
    out, seen = [], set()
    for dirpath, _dirs, files in os.walk(mod_root):
        for fn in files:
            if not fn.lower().endswith(".txt"):
                continue
            full = os.path.join(dirpath, fn)
            if "scripts" not in full.replace("\\", "/").lower():
                continue
            try:
                with open(full, "r", encoding="utf-8", errors="ignore") as fh:
                    text = fh.read()
            except OSError:
                continue
            mm = _MODULE_RE.search(text)
            module = mm.group(1) if mm else None
            if not module:
                continue
            for im in _ITEM_RE.finditer(text):
                item_name, body = im.group(1), im.group(2)
                low = body.lower()
                # A real firearm, not a WeaponPart attachment: IsAimedFirearm is the reliable tell (mag /
                # stock / sight attachments never carry it), backed by an EXACT ItemType=base:weapon
                # (the `\b` keeps base:weaponpart from matching).
                is_weapon = "isaimedfirearm" in low \
                    or re.search(r"itemtype\s*=\s*base:weapon\b", low) is not None
                if not is_weapon:
                    continue
                full_type = "%s.%s" % (module, item_name)
                anim_id = gun_anim_id(module, item_name)
                if anim_id in seen:
                    continue
                seen.add(anim_id)
                archetype = "magazine" if re.search(r"magazinetype\s*=", low) else None
                out.append((anim_id, archetype, full_type))
    out.sort(key=lambda r: r[0].lower())
    return out


def reloads_from_mod(mod_root):
    """Discover (animId, archetype) from a mod's generated RegisterReloadAnims_*.lua. A magazine
    profile omits `archetype` (gunworks.py _build_profile), so a missing one means magazine."""
    out = []
    for dirpath, _dirs, files in os.walk(mod_root):
        for fn in files:
            low = fn.lower()
            if not (low.startswith("registerreloadanims") and low.endswith(".lua")):
                continue
            try:
                with open(os.path.join(dirpath, fn), "r", encoding="utf-8", errors="ignore") as fh:
                    text = fh.read()
            except OSError:
                continue
            am = re.search(r'animId\s*=\s*"([^"]+)"', text)
            if not am:
                continue
            ar = re.search(r'archetype\s*=\s*"([^"]+)"', text)
            out.append((am.group(1), ar.group(1) if ar else "magazine"))
    return out


def preseed(mod_root, reloads, pz_install=None, build=None, force=False, dry_run=False, clean_base=True):
    """Write a stub node .xml + stub .x per stage for each (animId, archetype) in `reloads`, plus (when
    clean_base) the shared despiked clean base clips each archetype defaults to.

    Skips (never clobbers) an existing REAL node/clip unless force=True; refreshes our own stubs.
    Returns a report dict; never raises for a per-reload problem (collected in `warnings`)."""
    mod_root = os.path.abspath(mod_root)
    build = paths.resolve_build(mod_root, explicit=build)
    pz_install = pz_install or paths.default_pz_install()

    nodes_dir = os.path.join(mod_root, build, "media", "AnimSets", "player", "actions")
    anims_dir = os.path.join(mod_root, "common", "media", "anims_X", "Bob")

    report = {"ok": True, "mod_root": mod_root, "build": build, "reloads": [], "warnings": []}

    stub_src_text = None
    if not dry_run:
        try:
            stub_src_text = gunworks._load_clip_text(pz_install, _STUB_CLIP_SOURCE)
        except SystemExit as e:
            report["ok"] = False
            report["warnings"].append("cannot read stub clip source %s: %s" % (_STUB_CLIP_SOURCE, e))
            return report
        os.makedirs(nodes_dir, exist_ok=True)
        os.makedirs(anims_dir, exist_ok=True)

    for anim_id, archetype in reloads:
        arch = _ARCH_ALIAS.get(archetype, archetype)
        stages = ARCHETYPE_STAGES.get(arch)
        entry = {"animId": anim_id, "archetype": arch, "nodes": [], "clips": [], "skipped": []}
        if not stages:
            report["warnings"].append("unknown archetype %r for %s; skipped" % (archetype, anim_id))
            report["reloads"].append(entry)
            continue

        for stage in stages:
            spec = gunworks.STAGE_SPEC[stage]
            node_name = "%s_%s" % (anim_id, spec["nodeSuffix"])
            anim_name = "Bob_%s_%s" % (anim_id, spec["clipSuffix"])
            node_path = os.path.join(nodes_dir, node_name + ".xml")
            clip_path = os.path.join(anims_dir, anim_name + ".x")

            # Node: keep a real node; (re)write only a missing one or one of our own stubs.
            if os.path.exists(node_path) and not force and not _is_own_stub(node_path):
                entry["skipped"].append(node_name + ".xml (real node kept)")
            elif dry_run:
                entry["nodes"].append(node_path)
            else:
                with open(node_path, "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(_stub_node_xml(node_name, anim_name))
                entry["nodes"].append(node_path)

            # Clip: keep any existing clip (real posed clip or a prior stub both serve); create if none.
            if os.path.exists(clip_path) and not force:
                entry["skipped"].append(anim_name + ".x (kept)")
            elif dry_run:
                entry["clips"].append(clip_path)
            else:
                try:
                    text, _ = x_edit.rename_set(stub_src_text, _STUB_CLIP_SOURCE, anim_name)
                except Exception as e:
                    report["warnings"].append("stub clip %s failed: %s" % (anim_name, e))
                    continue
                with open(clip_path, "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(text)
                entry["clips"].append(clip_path)

        report["reloads"].append(entry)

    # Pre-generate the shared clean base clips for every archetype we stubbed, so the editor's clean-base
    # preview is present AT BOOT (a brand-new clip only loads at boot). Uses the SAME bake as the editor's
    # "Clean base clips", so the <clip>_afclean names match what the project retargets its stages to.
    if clean_base:
        base_clips = set()
        for _anim_id, archetype in reloads:
            base_clips.update(ARCHETYPE_BASE_CLIPS.get(archetype, ()))
        if base_clips:
            if dry_run:
                report["cleanBase"] = sorted(gunworks.clean_clip_name(c) for c in base_clips)
            else:
                try:
                    cb = gunworks.bake_clean_base_clips(mod_root, pz_install, sorted(base_clips))
                    report["cleanBase"] = [c.get("clean") for c in cb.get("clips", []) if c.get("clean")]
                except Exception as e:
                    report["warnings"].append("clean base clips: %s" % e)

    return report
