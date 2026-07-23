"""Generate Gunworks-framework reload files from the in-game editor's save.

The in-game Gunworks-reload editor writes its per-stage clip edits + config to a
`gunworks` block in ~/Zomboid/Lua/AnimForge/anim_edit.json. `wire-gunworks`
turns that into a complete, drop-in reload pack for a gun mod that requires the
Gunworks framework:

  1. one renamed .x per reload stage, baked from a chosen vanilla base clip
     (deltas applied, AnimationSet renamed) -> <mod>/common/media/anims_X/Bob/
  2. one self-contained AnimSet node per stage, gated on
     GunworksReloadAnim=<animId> + PerformingAction=Reload + the stage's state
     bool at m_ConditionPriority 10 -> <mod>/<build>/media/AnimSets/player/actions/
  3. a ready-to-run RegisterReloadAnims.lua calling ReloadAnim.RegisterWeapon
     -> <mod>/<build>/media/lua/shared/<luaNamespace>/

Unlike the grip `wire-set`, this emits NO equip Lua hook: the Gunworks Sync.lua
already derives GunworksReloadAnim every tick from PerformingAction=="Reload" +
the held registered gun, for mag-fed AND non-mag guns alike.

The `gunworks` block schema (the editor produces it; can be hand-authored):

    "gunworks": {
        "animId": "PumpShotgun",          # required; the GunworksReloadAnim value
        "fullTypes": ["Base.Shotgun"],    # gun fullType(s) sharing this profile (Always rule)
        "assignments": [                  # optional; supersedes fullTypes. "which guns, when":
            { "guns": ["Base.Shotgun"] },                                  #   Always
            { "guns": ["Base.Shotgun"],                                    #   only when a part is on
              "when": { "attach": "Base.x2Scope", "present": True } }      #   attach = item fullType OR partType slot
        ],
        "archetype": "shotgun",           # magazine|shotgun|revolver|boltactionnomag|doublebarrel|lever
        "style": "none",                  # none|sprite|attachment (model swap during reload)
        "shortRackAfterInsert": false,    # mag-fed only
        "prop": { "item": "Base.X" },     # optional off-hand prop
        "sprite": { "loaded": "...", "unloaded": "..." },   # style=sprite
        "attachments": { ... },           # style=attachment
        "build": "42",                    # optional; default: the mod's build folder, else "42"
        "luaNamespace": "MyMod",          # lua require dir (default = mod dir name)
        "order": "XYZ", "mode": "post",   # euler order/mode (top-level also accepted)
        "stages": {
            "load":  { "baseClip": "Bob_Reload_Shotgun_Load", "duration": 0.83,
                       "deltas": { "Bip01_R_UpperArm": { "rot": [0,0,10] } },
                       "blendTime": 0.20,
                       "events": [ { "event": "changeWeaponSprite", "timePc": 0.5, "value": "Mod.X" } ] },
            "rack":  { "baseClip": "Bob_Reload_Shotgun_Rack", "duration": 0.5 },
            "unload":{ "baseClip": "Bob_Reload_Shotgun_Load", "duration": 0.6 }
        }
    }

Stage keys are canonical: load / loadShort / rack / unload. loadShort is mag-fed only.
"""

import json
import os

from . import x_edit
from . import paths


# Per-stage wiring: the engine state bool the node gates on, the completion event the
# vanilla action waits for, the clip-name suffix, the node-name suffix, and the default
# mid-clip reload sound parameter.
STAGE_SPEC = {
    "load": {
        "stateVar": "isLoading",
        "finish": "loadFinished",
        "clipSuffix": "Load",
        "nodeSuffix": "Load",
        "sound": "load",
        "startSound": "insertAmmoStart",
        "blendTime": "0.20",
    },
    "loadShort": {
        "stateVar": "isLoadingShort",
        "finish": "loadFinished",
        "clipSuffix": "LoadShort",
        "nodeSuffix": "LoadShort",
        "sound": "load",
        "startSound": "insertAmmoStart",
        "blendTime": "0.50",
    },
    "rack": {
        "stateVar": "isRacking",
        "finish": "rackingFinished",
        "clipSuffix": "Rack",
        "nodeSuffix": "Rack",
        "sound": "rack",
        "startSound": "rack",
        "blendTime": "0.60",
    },
    "unload": {
        "stateVar": "isUnloading",
        "finish": "unloadFinished",
        "clipSuffix": "Unload",
        "nodeSuffix": "Unload",
        "sound": "unload",
        "startSound": "ejectAmmoStart",
        "blendTime": "0.20",
    },
}

# Stage emit order (deterministic output).
STAGE_ORDER = ["unload", "load", "loadShort", "rack"]

_NON_MAG_ARCHETYPES = {"shotgun", "revolver", "boltactionnomag", "doublebarrel", "lever"}


def _nonzero(v):
    return v and any(abs(float(c)) > 1e-9 for c in v)


def _load_clip_text(pz, clip, mod_root=None):
    """Read a base reload clip's .x text. A project's baseClip can be an AnimForge clean-base copy
    shipped inside the mod (Bob_*_afclean), so resolve the mod's anims_X/Bob FIRST, then fall back
    to the vanilla install."""
    candidates = []
    if mod_root:
        candidates.append(os.path.join(mod_root, "common", "media", "anims_X", "Bob", clip + ".x"))
    if pz:
        candidates.append(os.path.join(pz, "media", "anims_X", "Bob", clip + ".x"))
    for src in candidates:
        if os.path.isfile(src):
            with open(src, "r", encoding="utf-8", errors="replace", newline="") as fh:
                return fh.read()
    if not candidates:
        raise SystemExit("PZ install not found; pass --pz-install")
    raise SystemExit("base clip not found in mod or vanilla: %s" % clip)


# ---- clean base clips (despiked shared copies of stock reload clips) --------

# Suffix marking an AnimForge-generated despiked copy of a stock reload clip. Distinct so it never
# collides with a modder's own clip name and reads clearly in the base-clip picker.
CLEAN_SUFFIX = "_afclean"

# The two weapon-socket bones a reload's props ride. Their vanilla tracks carry the isolated spike
# keyframes that jitter an attached prop; both are despiked in a clean copy so either socket follows
# the hand smoothly.
_PROP_BONES = ("Bip01_Prop1", "Bip01_Prop2")


def clean_clip_name(base_clip):
    """The despiked-copy clip name for a stock base clip. Idempotent: an already-clean clip stays."""
    if not base_clip or base_clip.endswith(CLEAN_SUFFIX):
        return base_clip
    return base_clip + CLEAN_SUFFIX


def bake_clean_base_clips(mod_root, pz_install, base_clips, dry_run=False):
    """Write a deduped, despiked copy of each stock reload base clip into the mod.

    For each DISTINCT stock clip in `base_clips`, load it from the vanilla install, despike the prop
    sockets (Bip01_Prop1/Prop2) so an attached prop follows the hand without the vanilla spike
    jitter, rename its AnimationSet to <clip>_afclean, and write it under the mod's anims_X/Bob. The
    caller retargets its project stages' baseClip to the returned {stockClip: cleanClip} map, so BOTH
    the editor preview and the shipped reload bake from the clean copy. Idempotent: an empty or
    already-clean input clip is skipped (never self-copied). A clip missing from the install is
    recorded with an `error` rather than aborting the batch. Returns a report dict."""
    mod_root = os.path.abspath(mod_root)
    anims_dir = os.path.join(mod_root, "common", "media", "anims_X", "Bob")
    if not dry_run:
        os.makedirs(anims_dir, exist_ok=True)
    written, mapping, seen = [], {}, set()
    for base_clip in (base_clips or []):
        if not base_clip or base_clip.endswith(CLEAN_SUFFIX) or base_clip in seen:
            continue
        seen.add(base_clip)
        clean = clean_clip_name(base_clip)
        try:
            text = _load_clip_text(pz_install, base_clip)   # stock source: vanilla install only
        except SystemExit as e:
            written.append({"baseClip": base_clip, "error": str(e)})
            continue
        despiked = 0
        for bone in _PROP_BONES:
            try:
                text, fixed = x_edit.despike_bone(text, bone, anim_set=base_clip)
                despiked += fixed
            except ValueError:
                pass   # this clip does not animate that socket; nothing to clean there
        text, _ = x_edit.rename_set(text, base_clip, clean)
        path = os.path.join(anims_dir, clean + ".x")
        if not dry_run:
            with open(path, "w", encoding="utf-8", newline="") as fh:
                fh.write(text)
        mapping[base_clip] = clean
        written.append({"baseClip": base_clip, "clean": clean, "path": path, "despiked": despiked})
    return {"ok": True, "mod_root": mod_root, "clips": written, "mapping": mapping}


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


def _render_event(event):
    """One <m_Events> block. event = {event, timePc|time, value}."""
    name = event["event"]
    value = event.get("value", "")
    if "time" in event and event["time"]:
        when = "    <m_Time>%s</m_Time>" % event["time"]
    else:
        when = "    <m_TimePc>%s</m_TimePc>" % _fmt_num(event.get("timePc", 0.0))
    return (
        "  <m_Events>\n"
        "    <m_EventName>%s</m_EventName>\n"
        "%s\n"
        "    <m_ParameterValue>%s</m_ParameterValue>\n"
        "  </m_Events>"
    ) % (name, when, value)


def _fmt_num(v):
    s = "%.4f" % float(v)
    return s


def _render_condition(name, ctype, value):
    tag = "m_StringValue" if ctype == "STRING" else "m_BoolValue"
    return (
        "  <m_Conditions>\n"
        "    <m_Name>%s</m_Name>\n"
        "    <m_Type>%s</m_Type>\n"
        "    <%s>%s</%s>\n"
        "  </m_Conditions>"
    ) % (name, ctype, tag, value, tag)


def _build_node_xml(anim_id, stage_key, spec, anim_name, blend_time, archetype, extra_events):
    """Self-contained Gunworks reload AnimSet node for one stage."""
    conditions = [
        _render_condition("PerformingAction", "STRING", "Reload"),
        _render_condition("GunworksReloadAnim", "STRING", anim_id),
        _render_condition(spec["stateVar"], "BOOL", "true"),
    ]
    # Magazine guns also distinguish the short load/rack variants; pin the non-short
    # node off the short flag so the two never both match. Non-mag guns never set the
    # short vars, so they omit these.
    if archetype == "magazine":
        if stage_key == "load":
            conditions.append(_render_condition("isLoadingShort", "BOOL", "false"))
        elif stage_key == "rack":
            conditions.append(_render_condition("isRackingShort", "BOOL", "false"))

    events = [
        # Completion event the vanilla action waits on (must fire at clip end).
        "  <m_Events>\n"
        "    <m_EventName>%s</m_EventName>\n"
        "    <m_Time>End</m_Time>\n"
        "    <m_ParameterValue></m_ParameterValue>\n"
        "  </m_Events>" % spec["finish"],
        # Mid-clip reload sound + start sound, matching vanilla node conventions.
        _render_event({"event": "playReloadSound", "timePc": 0.3, "value": spec["sound"]}),
        _render_event({"event": "playReloadSound", "time": "Start", "value": spec["startSound"]}),
    ]
    for ev in (extra_events or []):
        events.append(_render_event(ev))

    node_name = "%s_%s" % (anim_id, spec["nodeSuffix"])
    # Magazine unload is the load motion played in reverse (the mag eject), matching vanilla
    # UnloadRifle (x_extends loadRifle + m_AnimReverse). Without this the unload plays the load
    # clip forward and looks identical to loading.
    reverse_line = ""
    if archetype == "magazine" and stage_key == "unload":
        reverse_line = "  <m_AnimReverse>true</m_AnimReverse>\n"
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<animNode>\n"
        "  <m_Name>%s</m_Name>\n"
        "  <m_AnimName>%s</m_AnimName>\n"
        "%s"
        "  <m_deferredBoneAxis>Y</m_deferredBoneAxis>\n"
        "  <m_Looped>false</m_Looped>\n"
        "  <m_SyncTrackingEnabled>false</m_SyncTrackingEnabled>\n"
        "  <m_EarlyTransitionOut>true</m_EarlyTransitionOut>\n"
        "  <m_SpeedScale>ReloadSpeed</m_SpeedScale>\n"
        "  <m_ConditionPriority>10</m_ConditionPriority>\n"
        "  <m_BlendTime>%s</m_BlendTime>\n"
        "%s\n"
        "%s\n"
        "</animNode>\n"
    ) % (node_name, anim_name, reverse_line, blend_time, "\n".join(conditions), "\n".join(events))


# ---- RegisterReloadAnims.lua generation -----------------------------------

def _lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def _lua_value(v, indent):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        # keep ints clean, floats with up to 4 dp
        if isinstance(v, float) and not v.is_integer():
            return ("%.4f" % v).rstrip("0").rstrip(".")
        return str(int(v))
    if isinstance(v, str):
        return _lua_str(v)
    if isinstance(v, list):
        return "{ " + ", ".join(_lua_value(x, indent) for x in v) + " }"
    if isinstance(v, dict):
        return _lua_table(v, indent)
    return "nil"


def _lua_table(d, indent):
    pad = "    " * (indent + 1)
    close = "    " * indent
    lines = ["{"]
    for k, val in d.items():
        key = k if str(k).isidentifier() else "[%s]" % _lua_str(k)
        lines.append("%s%s = %s," % (pad, key, _lua_value(val, indent + 1)))
    lines.append(close + "}")
    return "\n".join(lines)


def _build_profile(gw):
    """The Lua profile table passed to RegisterWeapon (animation-derived + author config)."""
    profile = {"animId": gw["animId"]}
    archetype = gw.get("archetype", "magazine")
    if archetype and archetype != "magazine":
        profile["archetype"] = archetype
    style = gw.get("style")
    if style and style != "none":
        profile["style"] = style
    if gw.get("magItem"):
        profile["magItem"] = gw["magItem"]
    elif isinstance(gw.get("prop"), dict) and gw["prop"].get("item"):
        profile["prop"] = {"item": gw["prop"]["item"]}
    if isinstance(gw.get("sprite"), dict):
        profile["sprite"] = gw["sprite"]
    if isinstance(gw.get("attachments"), dict):
        profile["attachments"] = gw["attachments"]
    if gw.get("shortRackAfterInsert"):
        profile["shortRackAfterInsert"] = True

    durations = {}
    for stage_key, stage in (gw.get("stages") or {}).items():
        if stage_key in STAGE_SPEC and isinstance(stage.get("duration"), (int, float)):
            dkey = {"load": "load", "loadShort": "loadShort",
                    "rack": "rack", "unload": "unload"}[stage_key]
            durations[dkey] = stage["duration"]
    if durations:
        profile["durations"] = durations
    return profile


def _sanitize_id(s):
    return "".join(c if c.isalnum() else "_" for c in str(s))


def _assignments_from(gw):
    """Normalize a gunworks block's targets into an assignment list. Prefers the
    explicit `assignments` array (each { guns:[...], when:{attach,present}|nil });
    falls back to the flat fullTypes/fullType (an Always rule) for back-compat."""
    assignments = gw.get("assignments")
    if assignments:
        return assignments
    full_types = gw.get("fullTypes") or ([gw["fullType"]] if gw.get("fullType") else [])
    return [{"guns": full_types}] if full_types else []


def _build_register_lua(gw):
    anim_id = gw["animId"]
    profile = _build_profile(gw)
    profile_lua = _lua_table(profile, 0)
    assignments = _assignments_from(gw)
    has_conditional = any(a.get("when") for a in assignments)

    helper = ""
    if has_conditional:
        helper = (
            "-- A copy of PROFILE tagged with an attachment condition; the Gunworks facade turns\n"
            "-- `when` into a matches(gun) predicate that wins while the part is attached.\n"
            "local function reloadWhen(attach, present)\n"
            "    local p = {}\n"
            "    for k, v in pairs(PROFILE) do p[k] = v end\n"
            "    p.when = { attach = attach, present = present }\n"
            "    return p\n"
            "end\n"
            "\n"
        )

    lines = []
    for a in assignments:
        guns = a.get("guns") or []
        when = a.get("when")
        if when:
            present = "true" if when.get("present", True) else "false"
            reload_expr = "reloadWhen(%s, %s)" % (_lua_str(when.get("attach")), present)
        else:
            reload_expr = "PROFILE"
        for g in guns:
            lines.append("    Gunworks.RegisterWeapon(%s, { reload = %s })" % (_lua_str(g), reload_expr))
    body = "\n".join(lines) if lines else "    -- no assignments"

    return (
        "-- AUTO-GENERATED by tools/pz-anim-forge (wire-gunworks) - do not hand-edit.\n"
        "-- Registers the %s reload animation with the Gunworks framework (id SWMG) through the\n"
        "-- unified Gunworks.RegisterWeapon facade. The gun's item script must still declare a real\n"
        "-- engine WeaponReloadType; Gunworks only swaps the animation. The AnimSet nodes under\n"
        "-- media/AnimSets/player/actions/ gate on GunworksReloadAnim = %s.\n"
        "\n"
        'local Gunworks = require("WeaponSystems/Gunworks")\n'
        "\n"
        "local PROFILE = %s\n"
        "\n"
        "%s"
        "local function registerReloadAnimations()\n"
        "%s\n"
        "end\n"
        "\n"
        "Events.OnGameBoot.Add(registerReloadAnimations)\n"
    ) % (anim_id, anim_id, profile_lua, helper, body)


# ---- top-level driver ------------------------------------------------------

def wire_gunworks(save_json, mod_root, pz_install, build=None, lua_namespace=None,
                  dry_run=False):
    with open(save_json, "r", encoding="utf-8") as fh:
        spec = json.load(fh)

    gw = spec.get("gunworks")
    if not gw:
        raise SystemExit("editor save has no 'gunworks' block")
    if not gw.get("animId"):
        raise SystemExit("gunworks.animId is required")
    stages = gw.get("stages") or {}
    if not stages:
        raise SystemExit("gunworks.stages is empty")

    anim_id = gw["animId"]
    archetype = gw.get("archetype", "magazine")
    order = gw.get("order", spec.get("order", "XYZ"))
    mode = gw.get("mode", spec.get("mode", "post"))
    mod_root = os.path.abspath(mod_root)
    build = paths.resolve_build(mod_root, explicit=build, from_json=gw.get("build"))
    lua_namespace = lua_namespace or gw.get("luaNamespace") or os.path.basename(mod_root)

    anims_dir = os.path.join(mod_root, "common", "media", "anims_X", "Bob")
    nodes_dir = os.path.join(mod_root, build, "media", "AnimSets", "player", "actions")
    lua_dir = os.path.join(mod_root, build, "media", "lua", "shared", lua_namespace)

    report = {
        "ok": True, "animId": anim_id, "archetype": archetype,
        "mod_root": mod_root, "build": build, "luaNamespace": lua_namespace,
        "clips": [], "nodes": [], "newNodes": [], "lua": None, "warnings": [],
    }

    # Magazine guns reload through a model swap, so Gunworks routes them to the sprite (or
    # attachments) validator: a magazine profile with no sprite/magItem is SILENTLY dropped
    # (RegisterWeapon returns without registering). Flag it here instead of shipping a dud.
    if archetype not in ("shotgun", "revolver", "boltactionnomag", "doublebarrel", "lever"):
        sprite = gw.get("sprite") if isinstance(gw.get("sprite"), dict) else {}
        if gw.get("style") == "attachments":
            if not gw.get("magItem") or not isinstance(gw.get("attachments"), dict):
                report["warnings"].append(
                    "magazine style=attachments needs magItem + attachments, "
                    "or Gunworks silently drops this profile")
        else:
            missing = [f for f, ok in (("sprite.loaded", sprite.get("loaded")),
                                       ("sprite.unloaded", sprite.get("unloaded")),
                                       ("magItem", gw.get("magItem"))) if not ok]
            if missing:
                report["warnings"].append(
                    "magazine gun needs style=sprite with %s (or style=attachments); "
                    "Gunworks silently drops this profile without them" % ", ".join(missing))

    if not dry_run:
        os.makedirs(anims_dir, exist_ok=True)
        os.makedirs(nodes_dir, exist_ok=True)
        os.makedirs(lua_dir, exist_ok=True)

    for stage_key in STAGE_ORDER:
        stage = stages.get(stage_key)
        if not stage:
            continue
        spec_s = STAGE_SPEC[stage_key]
        base_clip = stage.get("baseClip")
        if not base_clip:
            report["warnings"].append("stage '%s' has no baseClip; skipped" % stage_key)
            continue

        anim_name = "Bob_%s_%s" % (anim_id, spec_s["clipSuffix"])

        # 1. bake the renamed .x clip (baseClip may be an AnimForge clean copy shipped in the mod)
        text = _load_clip_text(pz_install, base_clip, mod_root=mod_root)
        text, applied = _apply_deltas(text, base_clip, stage.get("deltas"), order, mode)
        # Guard despike: with clean base clips (Bob_*_afclean) the prop sockets are already despiked,
        # so this is a no-op. It still runs in case a project bakes straight from a raw vanilla base
        # (no clean-base step yet) - the off-hand prop bone Bip01_Prop2 carries a few outlier vanilla
        # keyframes that jump off and back; removing just those spikes keeps the prop following the
        # hand cleanly. Idempotent, so it never double-touches an already-clean clip.
        text, _despiked = x_edit.despike_bone(text, "Bip01_Prop2", anim_set=base_clip)
        text, _ = x_edit.rename_set(text, base_clip, anim_name)
        clip_path = os.path.join(anims_dir, anim_name + ".x")
        if not dry_run:
            with open(clip_path, "w", encoding="utf-8", newline="") as fh:
                fh.write(text)
        report["clips"].append({"stage": stage_key, "baseClip": base_clip,
                                "anim": anim_name, "path": clip_path, "applied": applied})

        # 2. write the gated AnimSet node
        blend_time = stage.get("blendTime") or spec_s["blendTime"]
        node_xml = _build_node_xml(anim_id, stage_key, spec_s, anim_name, blend_time,
                                   archetype, stage.get("events"))
        node_name = "%s_%s" % (anim_id, spec_s["nodeSuffix"])
        node_path = os.path.join(nodes_dir, node_name + ".xml")
        # A node whose .xml did not exist before this build was never in the engine's boot activeFileMap,
        # so it cannot hot-load - the game must restart once to pick it up. A preseed stub (or a prior
        # build) leaves the file in place, so it hot-loads. The editor turns this into a clear restart hint.
        if not os.path.exists(node_path):
            report["newNodes"].append(node_name)
        if not dry_run:
            with open(node_path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(node_xml)
        report["nodes"].append({"stage": stage_key, "node": node_name, "path": node_path})

    # 3. write RegisterReloadAnims.lua
    lua_text = _build_register_lua(gw)
    lua_path = os.path.join(lua_dir, "RegisterReloadAnims_%s.lua" % _sanitize_id(anim_id))
    if not dry_run:
        with open(lua_path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(lua_text)
    report["lua"] = lua_path

    return report
