-- In-game animation editor for Project Zomboid. Entry point: pulls in the editor modules
-- (core state, pose panel, reload editor, overlay, browser, hub, headless ops) and wires the
-- "Toggle Anim Forge" keybind (default DELETE) to open/close the hub.
require "AnimForge/AnimEditorCore"
require "AnimForge/AnimEditorPanel"
require "AnimForge/AnimEditorReloadFx"
require "AnimForge/AnimEditorOverlay"
require "AnimForge/AnimEditorBrowser"
require "AnimForge/AnimEditorHub"
require "AnimForge/AnimEditorHeadlessOps"

local closePanel = AnimForge.Hub.closePanel
local openPanel = AnimForge.Hub.openPanel
local AE = AnimForge.AnimEdit

-- Rebindable keybind (Options > Key Bindings > Anim Forge). Default DELETE.
local KEYBIND = "Toggle Anim Forge"
local function registerKeybind()
    for _, kb in ipairs(keyBinding) do
        if kb.value == KEYBIND then return end   -- already registered (reload-safe)
    end
    table.insert(keyBinding, { value = "[Anim Forge]" })
    table.insert(keyBinding, { value = KEYBIND, key = Keyboard.KEY_DELETE })
end
registerKeybind()

-- True while the user is typing in any hub/browser text field, so the R/Space
-- shortcuts don't fire (and eat) keystrokes meant for the field.
local function typingInField()
    if AE.hub and AE.hub:isTyping() then return true end
    local b = AE.browser
    if b and b.searchEntry and b.searchEntry:isFocused() then return true end
    return false
end

Events.OnKeyPressed.Add(function(key)
    if key == getCore():getKey(KEYBIND) then
        if AE.hub then closePanel() else openPanel() end
        return
    end
    if not AE.hub or typingInField() then return end
    if key == Keyboard.KEY_R then
        -- R toggles the gizmo between rotate and translate while the editor is open
        AE.gizmoMode = (AE.gizmoMode == "rot") and "pos" or "rot"
        if AE.panel and AE.panel.gizmoBtn then
            AE.panel.gizmoBtn:setTitle("Gizmo: " .. (AE.gizmoMode == "rot" and "Rotate" or "Translate"))
        end
    elseif key == Keyboard.KEY_SPACE then
        if AE.panel then AE.panel:onPlayPause() end   -- play / pause the loaded clip
    end
end)

