"""Scan the vanilla Bob anims and emit a Lua category map for the in-game editor.

For each weapon keyword we produce two lists:
  grip - the grip-relevant held poses (idle/aim/attack/reload/move/equip), the
         set a modder actually wants to walk through to fix a gun's hold.
  all  - every clip whose filename contains the weapon keyword.

Output: the Anim Forge mod's AnimForge/AnimCategories.lua, setting
AnimForge.AnimCategories. Re-run after a game update to refresh.
"""
import os
import re
import sys

PZ = os.environ.get("PZ_INSTALL_DIR",
                    r"D:\Games\Steam\steamapps\common\ProjectZomboid")
ANIMS = os.path.join(PZ, "media", "anims_X", "Bob")
_MOD_CATS = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "..", "42", "media", "lua", "client", "AnimForge", "AnimCategories.lua"))
OUT = sys.argv[1] if len(sys.argv) > 1 else _MOD_CATS

# Display name -> filename keyword.
WEAPONS = [
    ("Handgun", "Handgun"), ("Rifle", "Rifle"), ("Shotgun", "Shotgun"),
    ("Revolver", "Revolver"),
    ("Spear", "Spear"), ("Bat (2H blunt)", "Bat"), ("Heavy (2H)", "Heavy"),
    ("Knife", "Knife"),
]

# Gunworks-reload archetypes. Each archetype maps to its ordered reload stages and the
# DEFAULT vanilla base clip the editor seeds for each stage (see GUNWORKS-RELOAD-PIPELINE.md
# and pzanimforge/gunworks.py STAGE_SPEC for the consuming contract). Canonical stage keys:
# load / loadShort / rack / unload. loadShort is magazine-fed only - the shell/round-by-round
# archetypes have no short-load. These feed the in-game "Gunworks reload" project type's
# archetype picker + per-stage base-clip pickers. archetype key -> ordered stages + base clip
# per stage. The order list is the display/seed order; `stages[stage].baseClip` is the default
# vanilla clip baked for that stage (the user can still pick a different one in the editor).
RELOAD_ARCHETYPES = [
    ("magazine", "Magazine (rifle/SMG/LMG)", [
        ("load", "Bob_Reload_Rifle_Load"),
        ("loadShort", "Bob_Reload_Rifle_Load"),
        ("rack", "Bob_Reload_Rifle_Rack"),
        ("unload", "Bob_Reload_Rifle_Load"),
    ]),
    ("magazinehandgun", "Magazine handgun", [
        ("load", "Bob_Reload_Handgun_Load"),
        ("loadShort", "Bob_Reload_Handgun_Load"),
        ("rack", "Bob_Reload_Handgun_Rack"),
        ("unload", "Bob_Reload_Handgun_Load"),
    ]),
    ("shotgun", "Shotgun (pump/semi)", [
        ("load", "Bob_Reload_Shotgun_Load"),
        ("rack", "Bob_Reload_Shotgun_Rack"),
        ("unload", "Bob_Reload_Shotgun_Load"),
    ]),
    ("revolver", "Revolver", [
        ("load", "Bob_Reload_Revolver_Load"),
        ("rack", "Bob_Reload_Revolver_Rack"),
        ("unload", "Bob_Reload_Revolver_Load"),
    ]),
    ("boltactionnomag", "Bolt-action (no mag)", [
        ("load", "Bob_Reload_Shotgun_Load"),
        ("rack", "Bob_Reload_Bolt_Rack"),
        ("unload", "Bob_Reload_Shotgun_Load"),
    ]),
    ("doublebarrel", "Double-barrel", [
        ("load", "Bob_Reload_DBShotgun_Load"),
        ("rack", "Bob_Reload_DBShotgun_Rack"),
        ("unload", "Bob_Reload_DBShotgun_Load"),
    ]),
    ("lever", "Lever-action", [
        ("load", "Bob_Reload_Lever_Load"),
        ("rack", "Bob_Reload_Lever_Rack"),
        ("unload", "Bob_Reload_Lever_Load"),
    ]),
]
# The archetype key emitted in the Gunworks save-block `archetype` field is "magazine" for
# both rifle and handgun mag guns (the editor distinguishes them only by base-clip defaults).
# Keep `magazinehandgun` as an editor-only profile alias that resolves to "magazine" on save.
ARCHETYPE_SAVE_KEY = {"magazinehandgun": "magazine"}

# Some weapon categories reuse another's animations and only ship a few of their
# own. A shotgun has NO dedicated aim/idle/walk/run anims - the vanilla AnimSets
# (aim_rifle.xml, sneakidleRifle.xml, ...) fold it in via the shared `firearm`
# Weapon condition - it only differs in reload/rack. So we list a shotgun's clips
# as its base's (rifle's) clips with the shotgun's own clips swapped in by role,
# so the editor shows the FULL set a shotgun actually animates with.
# child display name -> base display name.
INHERIT = {
    "Shotgun": "Rifle",
}


def role_key(name, kw):
    """Strip the weapon keyword so e.g. Bob_Reload_Rifle and Bob_Reload_Shotgun
    share the role 'Bob_Reload_' and one can override the other. Case-insensitive."""
    return re.sub(re.escape(kw), "", name, flags=re.I)


def merge_inherited(child_list, child_kw, base_list, base_kw):
    """Base order is kept. A child clip whose role matches a base clip REPLACES it
    in place (shotgun reload swaps in for rifle reload); child clips with no base
    counterpart are appended. Inherited base clips show through unchanged."""
    base_roles = [role_key(n, base_kw) for n in base_list]
    out = list(base_list)
    used = set()
    for c in child_list:
        rk = role_key(c, child_kw)
        replaced = False
        for i, br in enumerate(base_roles):
            if br == rk and i not in used:
                out[i], replaced = c, True
                used.add(i)
                break
        if not replaced and c not in out:
            out.append(c)
    return out

# The curated grip set is a tight allow-list of the CORE held poses, matched
# anchored (^Bob_...$) so micro-variants (_Small, recoil, directional bumps,
# IdleExt) are excluded. {W} = the weapon keyword; _? allows naming drift.
CORE_TEMPLATES = [
    r"Idle{W}",
    r"IdleAim{W}", r"IdleAim{W}_Up45", r"IdleAim{W}_Up75",
    r"IdleAim{W}_Down", r"IdleAim{W}_Down75",
    r"IdleToAim_?{W}", r"AimToIdle_?{W}",
    r"Attack{W}", r"Attack_?{W}_?Up45", r"Attack_?{W}_?Up75",
    r"Attack_?{W}_?Down45", r"Attack_?{W}_?Down75",
    r"Reload_?{W}", r"Reload_?{W}_Load", r"Reload_?{W}_Rack",
    r"Run{W}", r"Walk{W}", r"Sprint{W}",
    r"Equip_?{W}", r"Equip_?{W}_Back",
]


# Coarse thematic buckets so EVERY vanilla Bob clip (not just weapon ones) is
# browsable + categorized. Ordered: first keyword hit wins, so distinctive actions
# (attack/reload/...) claim a clip before the generic locomotion/idle catch-alls.
# Anything unmatched lands in "Other". Buckets overlap the weapon sets on purpose
# (Bob_AttackRifle is in both Combat and the Rifle tab) - they are just views.
THEME_RULES = [
    ("Reload", ["reload", "rack", "unload", "equip", "chamber", "insertshell",
                "openweapon", "closeweapon"]),
    ("Combat", ["attack", "shove", "push", "suicide", "chainsaw", "smother",
                "stomp", "charge", "stab", "swing", "throw", "spearcharge"]),
    ("React",  ["bite", "hitreact", "hit", "fall", "scramble", "getup", "get_",
                "stagger", "trip", "knock", "defend", "death", "dead", "stun"]),
    ("Rest",   ["sitground", "sit", "seated", "sat", "chair", "sleep", "squat",
                "kneel", "milking", "pet"]),
    ("Move",   ["walk", "run", "sprint", "strafe", "sneak", "stealth", "turn",
                "bump", "crawl", "move", "trees", "vault", "valult", "climb",
                "window", "fence", "rope", "ledge"]),
    ("Emote",  ["emote", "signal", "look", "wave", "shrug", "shiver", "salute",
                "clap", "dance", "surrender", "yawn", "sneeze", "point", "nod",
                "beckon", "smoke"]),
    ("Idle",   ["idle", "aim"]),
]
# Display order of the vanilla theme tabs ("All" = every clip; "Other" = unmatched).
THEME_ORDER = ["All", "Idle", "Move", "Combat", "Reload", "React", "Rest",
               "Emote", "Other"]


def classify_theme(name):
    low = name.lower().replace("bob_", "", 1)
    for theme, kws in THEME_RULES:
        for kw in kws:
            if kw in low:
                return theme
    return "Other"


def verify_archetype_clips():
    """Warn (to stderr) for any archetype base clip with no matching .x on disk. Returns
    the set of base clip names found, for the report line. Does not abort: a missing clip
    is a content problem to flag, not a generation failure."""
    found = set()
    for _key, _disp, stages in RELOAD_ARCHETYPES:
        for _stage, clip in stages:
            path = os.path.join(ANIMS, clip + ".x")
            if os.path.isfile(path):
                found.add(clip)
            else:
                sys.stderr.write(
                    "WARNING: archetype base clip not found: %s.x (%s)\n" % (clip, path))
    return found


def main():
    names = sorted(os.path.splitext(f)[0] for f in os.listdir(ANIMS)
                   if f.lower().endswith(".x"))
    raw = {}   # display name -> (kw, grip, all), the clips scanned for that keyword
    for disp, kw in WEAPONS:
        allc = [n for n in names if kw.lower() in n.lower()]
        grip = []
        for tmpl in CORE_TEMPLATES:
            rx = re.compile(r"^Bob_" + tmpl.format(W=re.escape(kw)) + r"$", re.I)
            for n in allc:
                if rx.match(n) and n not in grip:
                    grip.append(n)
        if grip:
            raw[disp] = (kw, grip, allc)

    # Resolve inheritance: a child folds in its base's clips (see INHERIT/merge).
    cats = []
    for disp, _kw in WEAPONS:
        if disp not in raw:
            continue
        kw, grip, allc = raw[disp]
        base = INHERIT.get(disp)
        if base and base in raw:
            base_kw, base_grip, base_all = raw[base]
            grip = merge_inherited(grip, kw, base_grip, base_kw)
            allc = merge_inherited(allc, kw, base_all, base_kw)
            print("%-16s grip=%-3d all=%-3d (inherits %s)" %
                  (disp, len(grip), len(allc), base))
        else:
            print("%-16s grip=%-3d all=%d" % (disp, len(grip), len(allc)))
        cats.append((disp, grip, allc))

    # Thematic buckets over EVERY vanilla clip (for the all-anims browse tabs).
    themes = {t: [] for t in THEME_ORDER if t != "All"}
    for n in names:
        themes[classify_theme(n)].append(n)
    for t in THEME_ORDER:
        if t == "All":
            print("%-16s all=%d" % ("All (vanilla)", len(names)))
        else:
            print("%-16s all=%d" % (t, len(themes[t])))

    # Gunworks-reload archetypes: verify each default base clip exists, then report.
    found_clips = verify_archetype_clips()
    for key, disp, stages in RELOAD_ARCHETYPES:
        order = ", ".join(s for s, _c in stages)
        miss = sum(1 for _s, c in stages if c not in found_clips)
        suffix = "" if miss == 0 else "  (%d MISSING)" % miss
        print("archetype %-16s order=[%s]%s" % (key, order, suffix))

    def lua_list(items):
        return "{ " + ", ".join('"%s"' % i for i in items) + " }"

    lines = [
        "-- AUTO-GENERATED by tools/pz-anim-forge/gen_categories.py - do not hand-edit.",
        "-- Weapon sets -> { grip = <curated held poses>, all = <every matching clip> }.",
        "-- Theme buckets + All -> { all = <clips> } cover every vanilla Bob clip.",
        "-- reloadArchetypes -> Gunworks-reload project seed data: per-archetype ordered",
        "-- stage list + the default base clip for each stage (load/loadShort/rack/unload).",
        "AnimForge = AnimForge or {}",
        "AnimForge.AnimCategories = {",
        "    order = " + lua_list([c[0] for c in cats]) + ",",
        "    themeOrder = " + lua_list(THEME_ORDER) + ",",
    ]
    for disp, grip, allc in cats:
        lines.append('    ["%s"] = {' % disp)
        lines.append("        grip = " + lua_list(grip) + ",")
        lines.append("        all = " + lua_list(allc) + ",")
        lines.append("    },")
    # "All" = every vanilla clip; the rest = their theme bucket.
    lines.append('    ["All"] = { all = ' + lua_list(names) + " },")
    for t in THEME_ORDER:
        if t == "All":
            continue
        lines.append('    ["%s"] = { all = %s },' % (t, lua_list(themes[t])))

    # Gunworks-reload archetype seed table. `reloadArchetypeOrder` is the picker order;
    # each entry has display, the save-block archetype key, the ordered stage list, and
    # per-stage { baseClip = <default vanilla clip> } the editor pre-loads for tweaking.
    lines.append("    reloadArchetypeOrder = "
                 + lua_list([k for k, _d, _s in RELOAD_ARCHETYPES]) + ",")
    lines.append("    reloadArchetypes = {")
    for key, disp, stages in RELOAD_ARCHETYPES:
        save_key = ARCHETYPE_SAVE_KEY.get(key, key)
        lines.append('        ["%s"] = {' % key)
        lines.append('            display = "%s",' % disp)
        lines.append('            archetype = "%s",' % save_key)
        lines.append("            order = " + lua_list([s for s, _c in stages]) + ",")
        lines.append("            stages = {")
        for stage, clip in stages:
            lines.append('                %s = { baseClip = "%s" },' % (stage, clip))
        lines.append("            },")
        lines.append("        },")
    lines.append("    },")
    lines.append("}")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    print("wrote", OUT)


if __name__ == "__main__":
    main()
