"""Generate the AnimSet XML + Lua that make a specific gun USE the edited anims.

`bake-set` writes renamed `.x` clips (`<prefix>_<clip>`) into a mod, but they are
inert until an AnimSet node references them and something gates that node to a
gun. This module produces both:

  1. For every vanilla node that plays one of the edited clips, a SELF-CONTAINED
     (flattened, no `x_extends`) clone whose edited `<m_AnimName>`s point at the
     renamed clips, gated at `m_ConditionPriority` 100 on a custom STRING anim
     variable (in addition to the node's own `Weapon` condition).
  2. A client Lua hook that sets that variable to "true" while a matching gun is
     in the primary hand (by item TAG and/or explicit fullType), so the gated
     clones win for that gun only; every other gun of the same type stays vanilla.

Why a custom variable and not `WeaponReloadType`: held poses (idle/aim/attack)
never set `WeaponReloadType`, so a STRING condition on it would only ever match
"" (AnimCondition.check L123-124). A Lua-set variable is valid in every state.

Why flatten: a mod node that keeps `x_extends` is resolved relative to the MOD
folder and silently dropped (see pzanimforge/flatten.py). See also the handoff
doc tools/pz-anim-forge/XML-WIRING-HANDOFF.md.
"""
from __future__ import annotations

import json
import os
import copy
import xml.etree.ElementTree as ET

from . import flatten as flat
from . import paths

ANIMSETS_REL = ("media", "AnimSets", "player")


def out_name(prefix, clip):
    """<prefix>_<clip-without-leading-Bob_>. MUST match cli.py `_out_name`
    (that is the name `bake-set` writes the renamed .x under)."""
    base = clip[4:] if clip.startswith("Bob_") else clip
    return "%s_%s" % (prefix, base)


def edited_clip_map(clips, prefix):
    """vanilla clip name -> renamed clip name, e.g.
    Bob_IdleAimRifle -> MyRifle_IdleAimRifle."""
    return {c: out_name(prefix, c) for c in clips if c}


# ---- finding the vanilla nodes that play an edited clip ---------------------

def _animsets_root(pz_install):
    return os.path.join(pz_install, *ANIMSETS_REL)


def iter_node_files(pz_install):
    root = _animsets_root(pz_install)
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            if f.lower().endswith(".xml"):
                yield os.path.join(dirpath, f)


def _state_rel(pz_install, path):
    """The node file's directory relative to player/ (e.g. 'idle',
    'ranged/handgun'). The engine keys a state on the TOP segment but scans
    recursively, so preserving the full relative path lands the clone in the
    correct state and keeps vanilla's folder layout."""
    rel = os.path.relpath(os.path.dirname(path), _animsets_root(pz_install))
    return rel.replace(os.sep, "/")


def _primary_anim_names(elem):
    """The node's POSE anim names: its top-level <m_AnimName> plus every
    <m_2DBlends> anim (the held pose / aim blend tree). Deliberately EXCLUDES
    <m_Transitions> anims - a node that merely blends THROUGH an edited clip on
    its way to another state is not the node the edit is about, and including
    them clones hundreds of unrelated action/rack nodes."""
    names = []
    for child in list(elem):
        if child.tag == "m_AnimName" and child.text:
            names.append(child.text.strip())
        elif child.tag == "m_2DBlends":
            for an in child.iter("m_AnimName"):
                if an.text:
                    names.append(an.text.strip())
    return names


def _all_anim_names(elem):
    return [(e.text or "").strip() for e in elem.iter("m_AnimName")]


def find_nodes(pz_install, edited_clips, scope="pose"):
    """Return (found, errors). `found` = one dict per vanilla node selected for
    cloning: {path, state, node_name, refs, flat}.

    scope='pose' (default) selects a node only when an edited clip is its PRIMARY
    pose (top m_AnimName / m_2DBlends). scope='all' selects on ANY m_AnimName
    (incl. transitions) - the broad behaviour, rarely wanted."""
    edited = set(edited_clips)
    pick = _all_anim_names if scope == "all" else _primary_anim_names
    found, errors = [], []
    for path in iter_node_files(pz_install):
        try:
            fe = flat.flatten_file(path)
        except Exception as e:  # a node we can't flatten can't be a candidate
            errors.append({"path": path, "error": str(e)})
            continue
        refs = sorted(edited.intersection(pick(fe)))
        if not refs:
            continue
        name_el = fe.find("m_Name")
        node_name = (name_el.text or "").strip() if name_el is not None else None
        if not node_name:
            node_name = os.path.splitext(os.path.basename(path))[0]
        found.append({"path": path, "state": _state_rel(pz_install, path),
                      "node_name": node_name, "refs": refs, "flat": fe})
    return found, errors


# ---- cloning one node ------------------------------------------------------

def _set_priority(clone, priority):
    for child in list(clone):
        if child.tag == "m_ConditionPriority":
            child.text = str(priority)
            return
    pe = ET.Element("m_ConditionPriority")
    pe.text = str(priority)
    insert_at = 1
    for i, c in enumerate(list(clone)):
        if c.tag in ("m_Name", "m_AnimName", "m_BlendTime"):
            insert_at = i + 1
    clone.insert(insert_at, pe)


def _add_gate(clone, gate_var, gate_value):
    """Insert the gate STRING condition (gate_var == gate_value) as the FIRST direct
    m_Conditions, so it is ANDed ahead of any node selection conditions. Returns True
    if the node's direct conditions contain an OR group (the AND insertion is then only
    approximate and a human should review - rare for held-pose nodes)."""
    cond = ET.Element("m_Conditions")
    ET.SubElement(cond, "m_Name").text = gate_var
    ET.SubElement(cond, "m_Type").text = "STRING"
    ET.SubElement(cond, "m_StringValue").text = gate_value

    first_cond, prio_idx, has_or = None, None, False
    for i, c in enumerate(list(clone)):
        if c.tag == "m_ConditionPriority":
            prio_idx = i
        elif c.tag == "m_Conditions":
            if first_cond is None:
                first_cond = i
            t = c.find("m_Type")
            if t is not None and (t.text or "").strip() == "OR":
                has_or = True
    if first_cond is not None:
        clone.insert(first_cond, cond)
    elif prio_idx is not None:
        clone.insert(prio_idx + 1, cond)
    else:
        clone.append(cond)
    return has_or


def make_clone(node, edited_map, gate_var, gate_value, prefix, priority=100):
    """Clone a found node: remap edited anim names, set a unique m_Name, force
    priority, add the gate condition (gate_var == gate_value). Returns
    (clone_element, cloned_name, remapped_pairs, has_or)."""
    clone = copy.deepcopy(node["flat"])

    remapped = []
    for an in clone.iter("m_AnimName"):
        t = (an.text or "").strip()
        if t in edited_map:
            an.text = edited_map[t]
            remapped.append((t, edited_map[t]))

    cloned_name = "%s_%s" % (node["node_name"], prefix)
    name_el = clone.find("m_Name")
    if name_el is None:
        name_el = ET.Element("m_Name")
        clone.insert(0, name_el)
    name_el.text = cloned_name

    _set_priority(clone, priority)
    has_or = _add_gate(clone, gate_var, gate_value)
    return clone, cloned_name, remapped, has_or


# ---- top-level orchestration ----------------------------------------------

def _load_spec(save_json):
    with open(save_json, "r", encoding="utf-8") as fh:
        return json.load(fh)


# The character anim variable the framework's GripAnim derivation sets while a registered gun
# is held; the generated node clones gate on `GunworksGripAnim == <animId>`.
GRIP_VARIABLE = "GunworksGripAnim"


def _q(s):
    return '"%s"' % s


def _sanitize(s):
    return "".join(c if c.isalnum() else "_" for c in str(s))


def _grip_assignments(s, fulltypes):
    """Which guns (and attachment conditions) this grip set applies to. Prefers the save's
    `set.assignments` (each { guns:[...], when:{attach,present}|nil }); falls back to a flat
    --fulltypes list as one unconditional (Always) rule."""
    assignments = s.get("assignments")
    if assignments:
        return assignments
    return [{"guns": list(fulltypes)}] if fulltypes else []


def grip_register_lua(anim_id, assignments):
    """Unified Gunworks.RegisterWeapon(gun, { grip = ... }) registration for a grip set.
    Declarative data only: the facade translates a variant's `when` into a matches(gun)
    predicate. While a listed gun is held the framework sets GunworksGripAnim = anim_id, and
    the generated node clones (gated on that value) win for that gun."""
    has_conditional = any(a.get("when") for a in assignments)
    helper = ""
    if has_conditional:
        helper = (
            "-- A grip block tagged with an attachment condition; the Gunworks facade turns\n"
            "-- `when` into a matches(gun) predicate that wins while the part is attached.\n"
            "local function gripWhen(attach, present)\n"
            '    return { animId = "%s", when = { attach = attach, present = present } }\n'
            "end\n"
            "\n"
        ) % anim_id
    lines = []
    for a in assignments:
        guns = a.get("guns") or []
        when = a.get("when")
        if when:
            present = "true" if when.get("present", True) else "false"
            grip_expr = "gripWhen(%s, %s)" % (_q(when.get("attach")), present)
        else:
            grip_expr = "GRIP"
        for g in guns:
            lines.append("    Gunworks.RegisterWeapon(%s, { grip = %s })" % (_q(g), grip_expr))
    body = "\n".join(lines) if lines else "    -- no target guns (list them in set.assignments)"
    return (
        "-- AUTO-GENERATED by tools/pz-anim-forge (wire-set) - do not hand-edit.\n"
        "-- Registers the %s grip animation with Gunworks (id SWMG) through the unified\n"
        "-- Gunworks.RegisterWeapon facade. While a listed gun is held the framework sets\n"
        "-- GunworksGripAnim = %s and the generated held/aim node clones win for that gun.\n"
        "\n"
        'local Gunworks = require("WeaponSystems/Gunworks")\n'
        "\n"
        'local GRIP = { animId = "%s" }\n'
        "\n"
        "%s"
        "local function registerGripAnimations()\n"
        "%s\n"
        "end\n"
        "\n"
        "Events.OnGameBoot.Add(registerGripAnimations)\n"
    ) % (anim_id, anim_id, anim_id, helper, body)


def wire_set(save_json, mod_root, pz_install, prefix=None, tag_id=None,
             fulltypes=None, var_name=None, priority=100, scope="pose",
             dry_run=False, build=None):
    """Read the editor save, generate gated clones + the Lua hook into mod_root.

    tag_id default: '<prefixlower>anims' (base namespace). fulltypes: optional
    list of exact gun fullTypes to also gate on. var_name default:
    '<prefix>Equipped'. scope: 'pose' (held-pose nodes) or 'all'.
    """
    spec = _load_spec(save_json)
    s = spec.get("set") or {}
    mod_root = os.path.abspath(mod_root)
    build = paths.resolve_build(mod_root, explicit=build, from_json=s.get("build"))
    clips = s.get("clips") or ([spec["clip"]] if spec.get("clip") else [])
    if not clips:
        raise SystemExit("save has no clip set to wire (need set.clips or clip)")
    prefix = prefix or s.get("namePrefix") or "Edited"
    anim_id = s.get("animId") or prefix
    lua_namespace = s.get("luaNamespace") or os.path.basename(mod_root)
    assignments = _grip_assignments(s, fulltypes or [])

    edited_map = edited_clip_map(clips, prefix)
    found, errors = find_nodes(pz_install, set(edited_map.keys()), scope=scope)

    written, warnings, names = [], [], set()
    for node in found:
        clone, cloned_name, remapped, has_or = make_clone(
            node, edited_map, GRIP_VARIABLE, anim_id, prefix, priority)
        key = (node["state"], cloned_name)
        if key in names:
            warnings.append("duplicate cloned node '%s' in state '%s' (from %s)"
                            % (cloned_name, node["state"], node["path"]))
        names.add(key)
        if has_or:
            warnings.append("node '%s' has an OR in its selection conditions; "
                            "review the gate AND-ing in %s"
                            % (node["node_name"], cloned_name))
        out_dir = os.path.join(mod_root, build, "media", "AnimSets", "player",
                               *node["state"].split("/"))
        dst = os.path.join(out_dir, cloned_name + ".xml")
        if not dry_run:
            os.makedirs(out_dir, exist_ok=True)
            with open(dst, "w", encoding="utf-8", newline="\r\n") as fh:
                fh.write(flat.to_pretty_xml(clone))
        written.append({"state": node["state"], "node": cloned_name,
                        "from": node["node_name"], "dst": dst,
                        "remapped": [{"from": a, "to": b} for a, b in remapped]})

    lua_dir = os.path.join(mod_root, build, "media", "lua", "shared", lua_namespace)
    lua_path = os.path.join(lua_dir, "RegisterGrip_%s.lua" % _sanitize(anim_id))
    if not dry_run:
        os.makedirs(lua_dir, exist_ok=True)
        with open(lua_path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(grip_register_lua(anim_id, assignments))

    if not any(a.get("guns") for a in assignments):
        warnings.append("no target guns: add gun fullType(s) to set.assignments (or pass "
                        "--fulltypes); the grip registers nothing without them")

    return {"ok": True, "prefix": prefix, "animId": anim_id, "variable": GRIP_VARIABLE,
            "assignments": assignments, "clips": len(clips),
            "nodes_written": len(written), "lua": lua_path,
            "written": written, "warnings": warnings, "flatten_errors": errors}
