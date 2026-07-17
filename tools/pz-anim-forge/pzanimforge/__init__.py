"""pz-anim-forge: edit Project Zomboid vanilla .x animations and re-export game-ready .glb.

Pure-python helpers (no bpy): assimp_ingest (fix + .x -> intermediate glTF via
the assimp C API), manifest, paths, wire. The Blender-side code (import the
intermediate, apply a bone delta, export the game .glb) lives in
../blender/pzaf_core.py.
"""
