"""Path resolution for pz-anim-forge (PZ install, Blender exe, tool dirs)."""

import os
import glob
import re


def tool_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def headless_runner():
    return os.path.join(tool_root(), "blender", "headless_runner.py")


def find_blender():
    """Prefer Blender 5.0 (the version HorseMod's working glbs were exported
    with), then 5.1, then PATH. Override with PZAF_BLENDER."""
    candidates = []
    env = os.environ.get("PZAF_BLENDER")
    if env:
        candidates.append(env)
    candidates += [
        r"C:\Program Files\Blender Foundation\Blender 5.0\blender.exe",
        r"C:\Program Files\Blender Foundation\Blender 5.1\blender.exe",
    ]
    for c in candidates:
        if os.path.isfile(c):
            return c
    for p in sorted(glob.glob(r"C:\Program Files\Blender Foundation\*\blender.exe")):
        return p
    return "blender"


def default_channel_dir():
    """The channel dir the in-game Anim Forge editor reads/writes: ~/Zomboid/Lua/AnimForge.
    Override with PZ_CHANNEL_DIR."""
    env = os.environ.get("PZ_CHANNEL_DIR")
    if env:
        return env
    return os.path.join(os.path.expanduser("~"), "Zomboid", "Lua", "AnimForge")


def _has_pz(d):
    return bool(d) and os.path.isfile(os.path.join(d, "media", "AnimSets", "Defaults.xml"))


def _steam_libraries():
    """Steam library roots, discovered read-only (registry SteamPath, then libraryfolders.vdf).
    Best-effort; returns [] if Steam isn't found."""
    roots, seen = [], set()

    def add(p):
        if p and os.path.isdir(p) and p not in seen:
            seen.add(p)
            roots.append(p)

    steam = None
    try:
        import winreg  # Windows only; ignored elsewhere
        for hive, key, name in (
            (winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam", "SteamPath"),
            (winreg.HKEY_LOCAL_MACHINE, r"Software\WOW6432Node\Valve\Steam", "InstallPath"),
        ):
            try:
                with winreg.OpenKey(hive, key) as k:
                    v, _ = winreg.QueryValueEx(k, name)
                    if v and os.path.isdir(v):
                        steam = v
                        break
            except OSError:
                continue
    except Exception:
        steam = None
    for p in (steam, r"C:\Program Files (x86)\Steam", r"C:\Program Files\Steam"):
        add(p)
    for base in list(roots):
        vdf = os.path.join(base, "steamapps", "libraryfolders.vdf")
        try:
            import re
            with open(vdf, "r", encoding="utf-8", errors="ignore") as fh:
                for m in re.finditer(r'"path"\s*"([^"]+)"', fh.read()):
                    add(m.group(1).replace("\\\\", "\\"))
        except Exception:
            pass
    return roots


def default_pz_install():
    """Locate the ProjectZomboid install (read-only). Order: PZ_INSTALL_DIR env, common paths,
    then Steam libraries. Returns the install root or None (the live-reload nudge is skipped when
    it can't be found; the bake itself still works)."""
    env = os.environ.get("PZ_INSTALL_DIR")
    if _has_pz(env):
        return env
    for c in (
        r"D:\Games\Steam\steamapps\common\ProjectZomboid",
        r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid",
    ):
        if _has_pz(c):
            return c
    for lib in _steam_libraries():
        cand = os.path.join(lib, "steamapps", "common", "ProjectZomboid")
        if _has_pz(cand):
            return cand
    return None


def resolve_build(mod_root, explicit=None, from_json=None):
    """Pick the mod build subdir that generated files (AnimSet XML, Lua) go into.

    Precedence: an explicit --build flag, then a `build` set in the editor save,
    then the mod's existing build folder, then "42". Anim Forge assumes plain
    "42" and only uses a versioned "42.x" folder when the mod actually has one
    (or the modder asks for it), so a mod's generated anims land next to its
    scripts instead of in a stray 42.13 folder. common/ content is unaffected.
    """
    if explicit:
        return str(explicit)
    if from_json:
        return str(from_json)
    found = []
    try:
        for name in sorted(os.listdir(mod_root)):
            if re.fullmatch(r"42(\.\d+)*", name) and os.path.isdir(os.path.join(mod_root, name)):
                found.append(name)
    except OSError:
        pass
    if "42" in found:
        return "42"
    if len(found) == 1:
        return found[0]
    return "42"
