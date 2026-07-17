"""Ingest a PZ DirectX .x animation into a correct glTF via assimp.

This replaces the old hand-rolled .x parser. Approach (mirrors aoqia194's
ZomboidAssetConverter): PZ's text .x files contain malformed lone-';' lines that
break assimp's parser - strip them ("fix") - then assimp's own .x importer does
the skeleton + coordinate math correctly. We drive assimp's stable C API through
ctypes (the pyassimp Python wrapper is ABI-incompatible with assimp 6), so no
build tools are needed - just the vendored assimp DLL.

The output glTF is a standard Y-up scene in cm (GlobalScale 100, so bone offsets
match HorseMod, e.g. Bip01_R_Hand = 13.7). A Blender round-trip then converts it
into the game's convention (a +90 X root) - see pzaf_core.
"""

import os
import re
import ctypes
import glob

# assimp postprocess flags (stable values from postprocess.h)
AI_VALIDATE_DATA_STRUCTURE = 0x400
AI_SORT_BY_PTYPE = 0x8000
AI_FIND_INVALID_DATA = 0x20000
AI_GLOBAL_SCALE = 0x8000000

_BROKEN_LINE = re.compile(r"^\s*;\s*$")
_dll = None


def _tool_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def find_assimp_dll():
    env = os.environ.get("PZAF_ASSIMP_DLL")
    if env and os.path.isfile(env):
        return env
    pats = [
        os.path.join(_tool_root(), "vendor", "**", "assimp*.dll"),
    ]
    for pat in pats:
        for p in glob.glob(pat, recursive=True):
            return p
    return None


def _load_dll():
    global _dll
    if _dll is not None:
        return _dll
    path = find_assimp_dll()
    if not path:
        raise RuntimeError(
            "assimp DLL not found. Put assimp*.dll under vendor/ or set "
            "PZAF_ASSIMP_DLL. Download the windows-x64 release zip from "
            "github.com/assimp/assimp/releases.")
    d = os.path.dirname(path)
    os.add_dll_directory(d)
    dll = ctypes.CDLL(path)
    dll.aiImportFileExWithProperties.restype = ctypes.c_void_p
    dll.aiImportFileExWithProperties.argtypes = [
        ctypes.c_char_p, ctypes.c_uint, ctypes.c_void_p, ctypes.c_void_p]
    dll.aiCreatePropertyStore.restype = ctypes.c_void_p
    dll.aiReleasePropertyStore.argtypes = [ctypes.c_void_p]
    dll.aiSetImportPropertyFloat.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_float]
    dll.aiExportScene.restype = ctypes.c_int
    dll.aiExportScene.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    dll.aiReleaseImport.argtypes = [ctypes.c_void_p]
    dll.aiGetErrorString.restype = ctypes.c_char_p
    _dll = dll
    return dll


def fix_x(src, dst):
    """Strip the malformed lone-';' lines that break assimp's .x parser.
    Returns the number of lines removed. Binary .x files are copied verbatim."""
    with open(src, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    lines = text.splitlines()
    if not lines:
        raise ValueError("empty .x file: %s" % src)
    header = lines[0]
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if header[8:11].lower() == "bin":
        with open(dst, "w", encoding="utf-8", errors="replace") as fh:
            fh.write(text)
        return 0
    kept = [header] + [ln for ln in lines[1:] if not _BROKEN_LINE.match(ln)]
    with open(dst, "w", encoding="utf-8") as fh:
        fh.write("\n".join(kept) + "\n")
    return len(lines) - len(kept)


def x_to_glb(src_x, out_glb, fixed_dir, global_scale=100.0):
    """Fix `src_x`, convert to a standard Y-up glb (cm) via assimp.
    Returns the glb path."""
    dll = _load_dll()
    fixed = os.path.join(fixed_dir, os.path.basename(src_x))
    fix_x(src_x, fixed)

    store = dll.aiCreatePropertyStore()
    dll.aiSetImportPropertyFloat(store, b"GLOBAL_SCALE_FACTOR",
                                 ctypes.c_float(global_scale))
    flags = (AI_VALIDATE_DATA_STRUCTURE | AI_FIND_INVALID_DATA
             | AI_SORT_BY_PTYPE | AI_GLOBAL_SCALE)
    scene = dll.aiImportFileExWithProperties(
        os.path.abspath(fixed).encode("utf-8"), flags, None, store)
    dll.aiReleasePropertyStore(store)
    if not scene:
        raise RuntimeError("assimp import failed for %s: %s"
                           % (src_x, dll.aiGetErrorString().decode("utf-8", "replace")))
    os.makedirs(os.path.dirname(out_glb), exist_ok=True)
    rc = dll.aiExportScene(scene, b"glb2",
                           os.path.abspath(out_glb).encode("utf-8"),
                           AI_VALIDATE_DATA_STRUCTURE)
    dll.aiReleaseImport(scene)
    if rc != 0:
        raise RuntimeError("assimp export failed for %s: %s"
                           % (out_glb, dll.aiGetErrorString().decode("utf-8", "replace")))
    return out_glb


if __name__ == "__main__":
    import sys
    src, out = sys.argv[1], sys.argv[2]
    fixed_dir = os.path.join(_tool_root(), "work", "fixed")
    print(x_to_glb(src, out, fixed_dir))
