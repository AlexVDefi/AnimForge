# Anim Forge

An in-game animation editor for Project Zomboid (Build 42). Pose character bones live, retime the
attachment markers on weapon reload animations, and export/bake custom reload animations.

Open it in-game with the **Toggle Anim Forge** keybind (default **Home**), rebindable under
Options > Key Bindings.

## What it does

- Force-holds a chosen animation clip on your character and lets you pose bones live (rotate / translate)
  with on-screen gizmos.
- Edits the `<m_Events>` attachment-marker timing on a reload AnimSet node (which prop attaches to the
  hand / off-hand, and when) on a color-coded timeline, with live preview.
- Exports the dialed changes so the companion **pz-anim-forge** tooling can bake them into game-ready
  files, with an optional save -> bake -> live-reload loop (no game restart).

## Standalone vs. with AgentBridge

Anim Forge runs on its own: everything above is driven through its UI. It has **no hard dependency** on
any other mod.

When the **AgentBridge** test-harness mod is also loaded, Anim Forge additionally registers a set of
headless bridge ops so an external agent / MCP can drive the editor programmatically. If AgentBridge is
absent, those ops are simply never registered and nothing else changes.

## Baking pipeline

The editor writes its export files to `~/Zomboid/Lua/AgentBridge/` (a plain folder name kept for
compatibility with the tooling). The `pz-anim-forge` Python package turns them into the final animation
files and can nudge the game to hot-reload the result. See that tool's own README for setup, including
the double-click `watch-reload-bake` watcher that runs the save -> bake -> reload loop with no agent
attached.
