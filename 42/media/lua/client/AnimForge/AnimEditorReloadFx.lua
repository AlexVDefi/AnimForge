-- Anim Forge editor: the reload attachment-marker editor (marker bar + windows).
require "AnimForge/AnimEditorCore"
require "ISUI/ISUIElement"
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISComboBox"
require "ISUI/ISTickBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISUI3DModel"
require "RadioCom/ISUIRadio/ISSliderPanel"
require "AnimForge/AnimForgeTheme"
require "AnimForge/AnimForgeWidgets"
require "AnimForge/AnimForgePropPicker"
require "AnimForge/AnimEditorPanel"

local applyBone = AnimForge.EditCore.applyBone
local ensureDelta = AnimForge.EditCore.ensureDelta
local forceClip = AnimForge.EditCore.forceClip
local getClipLen = AnimForge.EditCore.getClipLen
local getClipTime = AnimForge.EditCore.getClipTime
local getReloadAnim = AnimForge.EditCore.getReloadAnim
local markerFrac = AnimForge.EditCore.markerFrac
local readJsonFile = AnimForge.EditCore.readJsonFile
local recordKf = AnimForge.EditCore.recordKf
local loadModClipsFromCache = AnimForge.EditCore.loadModClipsFromCache
local rfxClipHasPropSocket = AnimForge.EditCore.rfxClipHasPropSocket
local rfxClearPropOverrides = AnimForge.EditCore.rfxClearPropOverrides
local rfxNeededPropBones = AnimForge.EditCore.rfxNeededPropBones
local rfxSetLivePropFix = AnimForge.EditCore.rfxSetLivePropFix
local rfxWritePropFixRequest = AnimForge.EditCore.rfxWritePropFixRequest
local rfxMarkPropFixed = AnimForge.EditCore.rfxMarkPropFixed
local rfxApplyStateAt = AnimForge.EditCore.rfxApplyStateAt
local rfxCombinedStages = AnimForge.EditCore.rfxCombinedStages
local rfxFocusStage = AnimForge.EditCore.rfxFocusStage
local rfxGlobalFrac = AnimForge.EditCore.rfxGlobalFrac
local rfxGlobalToStage = AnimForge.EditCore.rfxGlobalToStage
local rfxHasBothLoadVariants = AnimForge.EditCore.rfxHasBothLoadVariants
local rfxStageDisplay = AnimForge.EditCore.rfxStageDisplay
local rfxGun = AnimForge.EditCore.rfxGun
local rfxLoad = AnimForge.EditCore.rfxLoad
local rfxParsePartSwap = AnimForge.EditCore.rfxParsePartSwap
local rfxSave = AnimForge.EditCore.rfxSave
local rfxStopPreview = AnimForge.EditCore.rfxStopPreview
local rfxUpdateCachedMarkers = AnimForge.EditCore.rfxUpdateCachedMarkers
local saveJson = AnimForge.EditCore.saveJson
local saveProject = AnimForge.EditCore.saveProject
local setClipDone = AnimForge.EditCore.setClipDone
local setClipPaused = AnimForge.EditCore.setClipPaused
local setClipTime = AnimForge.EditCore.setClipTime
local TIMELINE_POP_W = AnimForge.EditPanel.TIMELINE_POP_W
local AE = AnimForge.AnimEdit
local T = AnimForge.AnimForgeTheme

-- ===================== project binding (project owns the markers) ============================
-- The reload's attachment markers live canonically in its gunworks PROJECT (AE.gw.stages[key].markers)
-- so the reload-set editor and this attachments editor read/write the SAME table with no drift. When a
-- reload has an owning AnimForge project we bind to it: seed this editor from the project's markers on
-- open, and flush edits back to the project (+ persist) on every save. Foreign reloads with no project
-- stay node-only (unchanged behaviour): the markers still bake into the node, there is just no project
-- to mirror them into.

-- Map an RFX stage label (Load/LoadShort/Rack/Unload, from the node file name) to a project stage key.
local RFX_STAGE_TO_KEY = { load = "load", loadshort = "loadShort", rack = "rack", unload = "unload" }
local function rfxStageKey(stageLabel)
    local low = (stageLabel or ""):lower()
    return RFX_STAGE_TO_KEY[low] or low
end

local function rfxCopyMarkers(src)
    local out = {}
    for i = 1, #(src or {}) do
        out[i] = { event = src[i].event, timePc = src[i].timePc or 0, value = src[i].value or "" }
    end
    return out
end

-- Find a saved gunworks project whose reload matches this mod+animId, loaded full. Lets a standalone
-- attachment edit (opened from the scan picker) flow into the SAME project the reload-set editor uses.
local function rfxFindProject(mod, animId)
    local AP = AnimForge.AnimProjects
    if not AP or not animId or animId == "" then return nil end
    local rows = AP.list()
    for i = 1, #rows do
        if rows[i].type == "gunworks" then
            local p = AP.load(rows[i].slug)
            local gw = p and p.gunworks
            if gw and gw.animId == animId and (not mod or mod == "" or gw.mod == mod) then return p end
        end
    end
    return nil
end

-- Bind this editor to the reload's owning project (if any). Ensures that project is the one loaded in
-- AE.gw, so both editors share one live table. Sets AE.rfx.boundToProject; foreign reloads stay false.
local function rfxBindProject(group)
    AE.rfx.boundToProject = false
    local animId = group and group.animId
    local mod = group and group.mod
    if not animId or animId == "" then return end
    local cur = AE.project
    local cfg = AE.gw and AE.gw.config
    -- already editing this reload's project in the set editor? then AE.gw is it - just flag bound.
    if cur and cur.type == "gunworks" and cfg and cfg.animId == animId
        and (not mod or mod == "" or cfg.mod == mod) then
        AE.rfx.boundToProject = true
        return
    end
    local proj = rfxFindProject(mod, animId)
    if proj and AE.GW and AE.GW.applyProject then
        AE.GW.applyProject(proj)   -- load into AE.gw so both editors share one table
        AE.rfx.boundToProject = true
    end
end

-- Seed each group stage's markers from its project stage (project canonical). On the first open of a
-- reload whose project has no markers yet, import the baked-node markers INTO the project instead, so
-- pre-existing reloads adopt their current timing without loss.
local function rfxSeedGroupFromProject(group)
    if not AE.rfx.boundToProject or not AE.gw or not AE.gw.stages then return end
    for i = 1, #group.stages do
        local gs = group.stages[i]
        local ps = AE.gw.stages[rfxStageKey(gs.stage)]
        if ps then
            if ps.markers and #ps.markers > 0 then
                gs.markers = rfxCopyMarkers(ps.markers)          -- project wins
            elseif gs.markers and #gs.markers > 0 then
                ps.markers = rfxCopyMarkers(gs.markers)          -- first-open import from the node
            end
        end
    end
end

-- Shown on the stage picker + the combined "Load / Short load" selector, so it is always clear what
-- the Short load stage is for.
local SHORT_LOAD_TIP =
    "Short load = the quicker mag insert used when the chamber is empty, because a Rack follows to " ..
    "chamber the first round. The full Load plays instead when the chamber already has a round " ..
    "(no rack needed). A reload uses one or the other, never both."

-- ================================ reload attachment-marker bar + editor window ===============
-- A colour-coded timeline of the reload's gwSetProp/gwPartToHand/gwPartToGun markers. Drag a tick
-- to retime it, right-click to delete, click empty space to scrub. The live character shows the
-- resulting off-hand prop + ramrod state at the playhead (rfxApplyStateAt).
local RFX_EVENTS = { "gwSetProp", "gwSetHandProp", "gwPartToHand", "gwPartToGun", "gwSetPart" }
local RFX_EVENT_LABEL = {
    gwSetProp = "Set off-hand prop",
    gwSetHandProp = "Set right-hand prop",
    gwPartToHand = "Part: gun -> hand",
    gwPartToGun = "Part: hand -> gun",
    gwSetPart = "Swap gun part",
}

---@return number, number, number
local function rfxColor(m)
    if m.event == "gwPartToHand" then return 1.0, 0.6, 0.15       -- orange: part off gun
    elseif m.event == "gwPartToGun" then return 0.4, 0.9, 0.45    -- green: part back on gun
    elseif m.event == "gwSetHandProp" then return 0.85, 0.5, 1.0  -- purple: right-hand prop
    elseif m.event == "gwSetPart" then return 1.0, 0.85, 0.2      -- yellow: gun-part swap
    else return 0.35, 0.8, 1.0 end                                -- cyan: off-hand prop
end

---@nodiscard
---@return string
local function rfxShortLabel(m)
    local v = m.value or ""
    if m.event == "gwPartToHand" then return "-> hand"
    elseif m.event == "gwPartToGun" then return "-> gun"
    elseif m.event == "gwSetPart" then
        local pt, ft = rfxParsePartSwap(v)
        if not pt then return "part?" end
        if ft == "" then return "detach" end
        return (ft:gsub("^.-%.", ""))
    elseif v == "" then return "clear"
    else return (v:gsub("^.-%.", "")) .. (m.event == "gwSetHandProp" and " (hand)" or "") end
end

-- Combined mode is on AND the reload actually has more than one stage to lay out.
local function barCombined()
    local g = AE.rfx.group
    return (AE.rfx.combined and g and g.stages and #g.stages > 1) and true or false
end

MarkerBar = ISUIElement:derive("MarkerBar")

function MarkerBar:new(x, y, w, h)
    local o = ISUIElement:new(x, y, w, h)
    setmetatable(o, self); self.__index = self
    o.dragM = nil
    o.dragStage = nil
    return o
end

-- Closest marker to bar-x within tolerance. Returns a hit descriptor { marker, stage } (stage is the
-- owning stage index in combined mode, else the focused stage), or nil. Unified so the caller code is
-- the same in both modes.
function MarkerBar:hitMarker(x)
    local best, hit = 8, nil
    if barCombined() then
        local cs = rfxCombinedStages()
        local n = #cs
        for pos = 1, n do
            local si = cs[pos]
            local ms = AE.rfx.group.stages[si].markers or {}
            for j = 1, #ms do
                local mx = ((pos - 1 + (ms[j].timePc or 0)) / n) * self.width
                local d = math.abs(x - mx)
                if d < best then best, hit = d, { marker = ms[j], stage = si } end
            end
        end
    else
        for i = 1, #AE.rfx.markers do
            local mx = (AE.rfx.markers[i].timePc or 0) * self.width
            local d = math.abs(x - mx)
            if d < best then best, hit = d, { marker = AE.rfx.markers[i], stage = AE.rfx.stageIndex } end
        end
    end
    return hit
end

function MarkerBar:reapply()
    AE.rfx.appliedProp = nil
    AE.rfx.appliedHandProp = nil
    AE.rfx.appliedParts = {}
    AE.rfx.appliedGunParts = {}
    if AE.rfx.active then rfxApplyStateAt(markerFrac()) end
end

-- Seek to a bar fraction and preview. Combined: the fraction is GLOBAL; focus the owning stage's clip
-- and set its local time. Single: the fraction is the clip's own local fraction.
function MarkerBar:seekAndPreview(frac)
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    AE.playing = false
    setClipPaused(true)
    if barCombined() then
        local s, lf = rfxGlobalToStage(frac)
        if s ~= AE.rfx.stageIndex then rfxFocusStage(s) end
        setClipTime(lf * getClipLen())
    else
        setClipTime(frac * getClipLen())
    end
    self:reapply()
end

function MarkerBar:prerender()
    local W, H = self.width, self.height
    local combined = barCombined()
    self:drawRect(0, H / 2 - 1, W, 2, 0.5, 0.5, 0.5, 0.55)
    -- playhead (global in combined, local otherwise)
    local now
    if combined then
        now = rfxGlobalFrac()
    else
        local len = getClipLen()
        now = (len > 0) and (getClipTime() / len) or 0
    end
    self:drawRect(now * W - 1, 0, 2, H, 0.9, 1, 1, 0.35)
    -- markers (drawn first so the stage dividers + labels sit on top and stay readable)
    local hoverX = self:isMouseOver() and self:getMouseX() or -999
    local hotLabel, hotX
    local function drawMarker(m, mx)
        local r, g, b = rfxColor(m)
        local hot = (self.dragM == m) or (math.abs(hoverX - mx) <= 8)
        local sz = hot and 9 or 7
        self:drawRect(mx - sz / 2, 0, sz, H, hot and 1.0 or 0.85, r, g, b)
        self:drawRectBorder(mx - sz / 2, 0, sz, H, 0.8, 0, 0, 0)
        if hot then
            hotLabel = rfxShortLabel(m) .. "  " .. string.format("%d%%", math.floor((m.timePc or 0) * 100 + 0.5))
            hotX = mx
        end
    end
    if combined then
        local cs = rfxCombinedStages()
        local n = #cs
        for pos = 1, n do
            local ms = AE.rfx.group.stages[cs[pos]].markers or {}
            for j = 1, #ms do drawMarker(ms[j], ((pos - 1 + (ms[j].timePc or 0)) / n) * W) end
        end
        -- stage boundary lines + friendly labels (Unload / Load or Short load / Rack)
        local segW = W / n
        for pos = 1, n do
            local x0 = (pos - 1) * segW
            if pos > 1 then self:drawRect(x0, 0, 1, H, 0.9, 0.55, 0.78, 1.0) end   -- boundary between clips
            local lbl = rfxStageDisplay(AE.rfx.group.stages[cs[pos]].stage)
            local lw = getTextManager():MeasureStringX(UIFont.Small, lbl)
            local lx = x0 + (segW - lw) / 2
            self:drawRect(lx - 3, 0, lw + 6, 12, 0.7, 0.06, 0.07, 0.10)            -- readable backing
            self:drawText(lbl, lx, 0, 0.78, 0.82, 0.92, 1, UIFont.Small)
        end
    else
        for i = 1, #AE.rfx.markers do drawMarker(AE.rfx.markers[i], (AE.rfx.markers[i].timePc or 0) * W) end
    end
    if hotLabel then self:drawTextCentre(hotLabel, hotX, H + 1, 1, 1, 0.85, 1, UIFont.Small) end
end

function MarkerBar:onMouseDown(x, y)
    local hit = self:hitMarker(x)
    if hit then
        self.dragM = hit.marker
        self.dragStage = hit.stage
        AE.rfx.marker = hit.marker
        self:setCapture(true)
    else
        self:seekAndPreview(x / self.width)
    end
    return true
end

function MarkerBar:onMouseMove(dx, dy)
    if not self.dragM then return end
    local frac = self:getMouseX() / self.width
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    if barCombined() then
        local s, lf = rfxGlobalToStage(frac)
        if s ~= self.dragStage then
            -- dragged across a boundary: relink the marker to the stage it now sits in
            local stages = AE.rfx.group.stages
            local old = stages[self.dragStage].markers or {}
            for k = #old, 1, -1 do if old[k] == self.dragM then table.remove(old, k); break end end
            stages[s].markers = stages[s].markers or {}
            stages[s].markers[#stages[s].markers + 1] = self.dragM
            self.dragStage = s
        end
        self.dragM.timePc = lf
        self:seekAndPreview(frac)
    else
        self.dragM.timePc = frac
        self:seekAndPreview(frac)
    end
end

function MarkerBar:onMouseUp(x, y)
    self.dragM = nil
    self.dragStage = nil
    self:setCapture(false)
end
MarkerBar.onMouseUpOutside = MarkerBar.onMouseUp
MarkerBar.onMouseMoveOutside = MarkerBar.onMouseMove

function MarkerBar:onRightMouseDown(x, y)
    local hit = self:hitMarker(x)
    if hit then
        local list = barCombined() and (AE.rfx.group.stages[hit.stage].markers or {}) or AE.rfx.markers
        for i = #list, 1, -1 do
            if list[i] == hit.marker then table.remove(list, i); break end
        end
        self:reapply()
    end
    return true
end

-- The self-contained "Reload Attachments" editor: transport + the marker bar + an add row + save.
-- Opened when a reload is picked from the hub task; closing it ends the preview (restores the gun).
ReloadFxWindow = ISCollapsableWindow:derive("ReloadFxWindow")

function ReloadFxWindow:new(x, y)
    local o = ISCollapsableWindow.new(self, x or 200, y or 110, 470, 316)
    o.title = "Reload Attachments"
    o.resizable = false
    o.uiCollapsed = false
    return o
end

function ReloadFxWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    self:setResizable(false)
    local T = AnimForge.AnimForgeTheme
    local pad = 12
    local w = self.width
    local y = self:titleBarHeight() + 8

    -- Minimize toggle: collapse to the title bar so the character stays visible while scrubbing.
    self.pin = true
    local mbh = self:titleBarHeight() - 2
    self.minBtn = ISButton:new(1 + mbh + 3, 1, mbh, mbh, "-", self, ReloadFxWindow.onToggleCollapse)
    self.minBtn:initialise()
    self.minBtn.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    self.minBtn.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    self.minBtn.backgroundColorMouseOver = { r = 1, g = 1, b = 1, a = 0.2 }
    self.minBtn.tooltip = "Minimize / restore the panel"
    self:addChild(self.minBtn)

    -- Play sits at the top-right of the info row so the scrubber + marker bar below can both span
    -- the full content width (x = pad, width = barW) and line up tick-for-handle exactly.
    local barW = w - 2 * pad
    self.infoLbl = ISLabel:new(pad, y, 16, tostring(AE.rfx.animId), 0.85, 0.9, 1, 1, UIFont.Small, true)
    self.infoLbl:initialise(); self:addChild(self.infoLbl)
    -- stage switcher: multi-stage gunworks reloads (Load/LoadShort/Rack/Unload) share one picker row;
    -- switching here swaps which stage node is loaded + previewed. Hidden for single-node reloads and
    -- in combined mode (the combined bar shows every stage at once).
    self.stageCombo = ISComboBox:new(pad + 116, y - 2, 128, 22, self, ReloadFxWindow.onStageChange)
    self.stageCombo:initialise(); self:addChild(self.stageCombo)
    self.stageCombo.tooltip = SHORT_LOAD_TIP
    -- combined-timeline toggle: lay all stages end to end on one bar. Only shown for multi-stage reloads.
    self.combinedTick = ISTickBox:new(pad + 250, y - 1, 16, 16, "", self, ReloadFxWindow.onCombinedToggle)
    self.combinedTick:initialise(); self:addChild(self.combinedTick)
    self.combinedTick:addOption("All clips")
    self.combinedTick.tooltip = "Show the whole reload cycle on one timeline: Unload, then the chosen Load, then Rack. Markers stay linked to their clip."
    -- which Load variant the combined bar shows in its middle slot (a reload plays one, never both).
    -- Sits where the stage combo does; shown in combined mode only when the reload has both variants.
    self.loadVariantCombo = ISComboBox:new(pad + 116, y - 2, 128, 22, self, ReloadFxWindow.onLoadVariantChange)
    self.loadVariantCombo:initialise(); self:addChild(self.loadVariantCombo)
    self.loadVariantCombo:addOptionWithData("Load", "load")
    self.loadVariantCombo:addOptionWithData("Short load", "loadshort")
    self.loadVariantCombo.tooltip = SHORT_LOAD_TIP
    self.loadVariantCombo:setVisible(false)
    self.playBtn = ISButton:new(w - pad - 64, y - 2, 64, 22, "Play", self, ReloadFxWindow.onPlayPause)
    self.playBtn:initialise(); self:addChild(self.playBtn); if T then T.styleGhost(self.playBtn) end
    self:refreshStageCombo()
    y = y + 26

    self.scrub = ISSliderPanel:new(pad, y, barW, 18, self, ReloadFxWindow.onScrub)
    self.scrub:initialise(); self:addChild(self.scrub)
    self.scrub:setDoButtons(false); self.scrub:setValues(0, 1, 0.001, 0.05, true); self.scrub:setCurrentValue(0, true)
    y = y + 22

    self.bar = MarkerBar:new(pad, y, barW, 28)
    self.bar:initialise(); self:addChild(self.bar)
    AE.rfx.bar = self.bar
    y = y + 40

    self.nowLbl = ISLabel:new(pad, y, 16, "", 0.7, 0.95, 0.75, 1, UIFont.Small, true)
    self.nowLbl:initialise(); self:addChild(self.nowLbl)
    y = y + 24

    -- ---- marker editor: pick an event + its value, then drop a marker at the playhead ----
    -- Row 1 (value): the event and the prop/part it applies. gwSetPart swaps a gun part (parts combo);
    -- every other event sets a prop, chosen through the tabbed "Props..." picker. updatePropControls
    -- toggles which value control shows. Props... is right-aligned and the prop name is clipped to the
    -- gap before it, so a long name (e.g. STANAG_MAG_ATTACHMENT) never slides under the button.
    self.evCombo = ISComboBox:new(pad, y, 150, 22, self, nil)
    self.evCombo:initialise(); self:addChild(self.evCombo)
    for i = 1, #RFX_EVENTS do self.evCombo:addOptionWithData(RFX_EVENT_LABEL[RFX_EVENTS[i]], RFX_EVENTS[i]) end
    self.evCombo.tooltip = "What this marker does at the playhead: set the off-hand prop, move a part hand<->gun, or swap a gun part."
    local propsW = 72
    local valX = pad + 156
    self.propsBtn = ISButton:new(w - pad - propsW, y, propsW, 22, "Props...", self, ReloadFxWindow.onOpenProps)
    self.propsBtn:initialise(); self:addChild(self.propsBtn); if T then T.styleGhost(self.propsBtn) end
    self.propsBtn.tooltip = "Pick the prop this marker applies - the weapon's attachments, your mod's items, any base item, or your favourites."
    self.rfxPropLabelW = (w - pad - propsW - 8) - valX
    self.itemCombo = ISComboBox:new(valX, y, (w - pad) - valX, 22, self, nil)
    self.itemCombo:initialise(); self:addChild(self.itemCombo)
    self.chosenProp = ""
    self.propLbl = ISLabel:new(valX + 2, y + 4, 16, "(none - pick a prop)", 0.85, 0.9, 1, 1, UIFont.Small, true)
    self.propLbl:initialise(); self:addChild(self.propLbl)
    self:rfxPopulateItemCombo()
    self.rfxLastEv = self.evCombo:getOptionData(self.evCombo.selected)
    self:updatePropControls(self.rfxLastEv)
    y = y + 28

    -- Row 2 (action): the primary marker-adder - accent-styled + explicit so it reads as THE button to press.
    self.addBtn = ISButton:new(pad, y, 210, 24, "+ Add marker at playhead", self, ReloadFxWindow.onAdd)
    self.addBtn:initialise(); self:addChild(self.addBtn); if T then T.stylePrimary(self.addBtn) end
    self.addBtn.tooltip = "Drop the chosen event onto the timeline at the current playhead. Then drag its tick to retime, or right-click it to delete."
    y = y + 30

    -- Row 3 (save): bake everything - these markers plus any set-editor bone pose - into the mod.
    self.saveBtn = ISButton:new(pad, y, 150, 24, "Save changes", self, ReloadFxWindow.onSave)
    self.saveBtn:initialise(); self:addChild(self.saveBtn); if T then T.styleGhost(self.saveBtn) end
    self.saveBtn.tooltip = "Save all your changes and bake them into the mod - the marker timing here, "
        .. "plus any bone pose you set in the set editor. Same 'Save changes' as the set editor, so you "
        .. "never have to pick which save."
    self.hintLbl = ISLabel:new(pad + 158, y + 5, 16, "drag ticks to retime - right-click deletes",
        0.7, 0.72, 0.82, 1, UIFont.Small, true)
    self.hintLbl:initialise(); self:addChild(self.hintLbl)
    y = y + 32

    -- Ramrod / prop-socket rotation fix: tick to live-preview the -90X correction on the off-hand
    -- (and gun) socket, "Bake fix" to write it into the mod .glb so it survives a restart. Hidden for
    -- reloads whose clip has no prop socket (nothing to correct).
    self.rotFixTick = ISTickBox:new(pad, y, 16, 16, "", self, ReloadFxWindow.onRotFixToggle)
    self.rotFixTick:initialise(); self:addChild(self.rotFixTick)
    self.rotFixTick:addOption("Correct ramrod rotation")
    self.rotFixTick.tooltip = "Live-preview the -90 deg X fix on the off-hand / gun prop socket so the " ..
        "ramrod sits right. 'Bake fix' writes it into the mod's .glb so it survives a restart (idempotent)."
    self.rotAllTick = ISTickBox:new(pad + 190, y, 16, 16, "", self, nil)
    self.rotAllTick:initialise(); self:addChild(self.rotAllTick)
    self.rotAllTick:addOption("whole mod")
    self.rotAllTick.tooltip = "Bake the fix into EVERY reload .glb in this mod that still needs it, not just this clip."
    self.bakeFixBtn = ISButton:new(w - pad - 92, y - 2, 92, 22, "Bake fix", self, ReloadFxWindow.onBakeFix)
    self.bakeFixBtn:initialise(); self:addChild(self.bakeFixBtn); if T then T.styleGhost(self.bakeFixBtn) end
    self:refreshRotFix()
end

function ReloadFxWindow:onToggleCollapse()
    self:setCollapsed(not self.uiCollapsed)
end

-- Collapse to just the title bar so the reloading character stays fully visible while retiming.
function ReloadFxWindow:setCollapsed(c)
    if c == self.uiCollapsed then return end
    self.uiCollapsed = c
    local th = self:titleBarHeight()
    local kids = { self.infoLbl, self.stageCombo, self.loadVariantCombo, self.combinedTick, self.playBtn,
                   self.scrub, self.bar, self.nowLbl, self.evCombo, self.itemCombo, self.propLbl,
                   self.propsBtn, self.addBtn, self.saveBtn, self.hintLbl,
                   self.rotFixTick, self.rotAllTick, self.bakeFixBtn }
    if c then
        self.fullHeight = self.height
        for i = 1, #kids do if kids[i] then kids[i]:setVisible(false) end end
        self:setHeight(th)
        if self.minBtn then self.minBtn:setTitle("+") end
    else
        self:setHeight(self.fullHeight or 316)
        for i = 1, #kids do if kids[i] then kids[i]:setVisible(true) end end
        self:refreshStageCombo()   -- re-hide the stage combo / toggle for single-stage or combined
        self:updatePropControls(self.rfxLastEv)   -- re-hide the parts combo vs prop picker per event
        self:refreshRotFix()       -- re-hide the rotation-fix row for clips with no prop socket
        if self.minBtn then self.minBtn:setTitle("-") end
    end
end

function ReloadFxWindow:onScrub(value)
    if self.bar then self.bar:seekAndPreview(value) end
end

-- Populate the stage switcher from the loaded group. Multi-stage only. In per-stage mode this lists
-- every stage (friendly names); in combined mode it hides, and the "Load / Short load" variant picker
-- shows in its place when the reload has both load variants.
function ReloadFxWindow:refreshStageCombo()
    if not self.stageCombo then return end
    local g = AE.rfx.group
    local stages = (g and g.stages) or {}
    local multi = #stages > 1
    if self.combinedTick then
        self.combinedTick:setVisible(multi)
        self.combinedTick:setSelected(1, AE.rfx.combined == true)
    end
    -- variant picker: combined mode, and only when both a full Load and a Short load exist
    if self.loadVariantCombo then
        local showVariant = multi and AE.rfx.combined and rfxHasBothLoadVariants()
        self.loadVariantCombo:setVisible(showVariant)
        if showVariant then
            self.loadVariantCombo.selected = (AE.rfx.loadVariant == "loadshort") and 2 or 1
        end
    end
    self.stageCombo:clear()
    if not multi or AE.rfx.combined then
        self.stageCombo:setVisible(false)
        return
    end
    self.stageCombo:setVisible(true)
    for i = 1, #stages do
        local nmk = (stages[i].markers and #stages[i].markers) or 0
        self.stageCombo:addOptionWithData(rfxStageDisplay(stages[i].stage)
            .. (nmk > 0 and ("  (" .. nmk .. ")") or ""), i)
    end
    self.stageCombo.selected = AE.rfx.stageIndex or 1
end

-- Toggle the combined all-stages timeline. Entering it focuses the first cycle stage (Unload) at t=0
-- so the whole bar previews from the start; leaving it drops back to per-stage editing.
function ReloadFxWindow:onCombinedToggle()
    AE.rfx.combined = (self.combinedTick and self.combinedTick:isSelected(1)) and true or false
    if AE.rfx.combined then
        if AE.rfx.loadVariant ~= "loadshort" then AE.rfx.loadVariant = "load" end
        local cs = rfxCombinedStages()
        if cs[1] then rfxFocusStage(cs[1]) end
        setClipTime(0)
    end
    self:refreshStageCombo()
    self:rfxPopulateItemCombo()
    if self.bar then self.bar:reapply() end
end

-- Choose which Load variant the combined bar shows in its middle slot. If the focused clip is the one
-- being hidden, jump the playhead to the first shown stage so the preview stays valid.
function ReloadFxWindow:onLoadVariantChange()
    local v = self.loadVariantCombo and self.loadVariantCombo:getOptionData(self.loadVariantCombo.selected)
    AE.rfx.loadVariant = v or "load"
    local cs = rfxCombinedStages()
    local inView = false
    for i = 1, #cs do if cs[i] == AE.rfx.stageIndex then inView = true; break end end
    if not inView and cs[1] then rfxFocusStage(cs[1]); setClipTime(0) end
    self:rfxPopulateItemCombo()
    if self.bar then self.bar:reapply() end
end

function ReloadFxWindow:onStageChange()
    local idx = self.stageCombo and self.stageCombo:getOptionData(self.stageCombo.selected)
    if idx then self:switchStage(idx) end
end

-- Switch which stage node is loaded. The current stage's in-progress marker edits are copied back
-- into the group first (so flipping between stages keeps unsaved work); each stage still Saves to its
-- own node.
function ReloadFxWindow:switchStage(index)
    local g = AE.rfx.group
    if not g or not g.stages[index] then return end
    local cur = AE.rfx.stageIndex and g.stages[AE.rfx.stageIndex]
    if cur then
        local copy = {}
        for i = 1, #AE.rfx.markers do
            local m = AE.rfx.markers[i]
            copy[i] = { event = m.event, timePc = m.timePc or 0, value = m.value or "" }
        end
        cur.markers = copy
    end
    AE.rfx.stageIndex = index
    rfxLoad(g.stages[index])
    if self.infoLbl then self.infoLbl:setName(tostring(AE.rfx.animId)) end
    if self.stageCombo then self.stageCombo.selected = index end
    self:rfxPopulateItemCombo()
    self:refreshRotFix()   -- the new stage is a different clip -> re-evaluate its socket-fix state
    if self.bar then self.bar:reapply() end
end

function ReloadFxWindow:onPlayPause()
    AE.playing = not AE.playing
    if AE.playing and barCombined() then
        -- restart the cycle from the first stage (Unload) if we're paused at the end of the last one
        local cs = rfxCombinedStages()
        local isLast = #cs > 0 and cs[#cs] == AE.rfx.stageIndex
        local len = getClipLen()
        if isLast and len > 0 and getClipTime() >= len - 0.02 then
            if cs[1] then rfxFocusStage(cs[1]) end
            setClipTime(0)
        end
        self.prevClipTime = getClipTime()
    end
    setClipPaused(not AE.playing)
    self.playBtn:setTitle(AE.playing and "Pause" or "Play")
end

-- Fill the value combo for the selected event. For gwSetPart it lists the equipped gun's swappable
-- parts grouped by location ("TrapDoor: Open", each option's data is "PartType=fullType", plus a
-- per-location detach); for every other event it is the prop/item whitelist.
function ReloadFxWindow:rfxPopulateItemCombo()
    if not self.itemCombo then return end
    self.itemCombo:clear()
    local ev = (self.evCombo and self.evCombo:getOptionData(self.evCombo.selected)) or RFX_EVENTS[1]
    if ev == "gwSetPart" then
        local gun = rfxGun()
        local gunType = gun and gun:getFullType() or nil
        local byGun = gunType and AE.rfx.partsByGun[gunType] or nil
        local any = false
        if byGun then
            local locs = {}
            for pt in pairs(byGun) do locs[#locs + 1] = pt end
            table.sort(locs)
            for li = 1, #locs do
                local pt = locs[li]
                local shortLoc = pt:gsub("^Gunsmithing", "")
                local parts = byGun[pt]
                for pi = 1, #parts do
                    self.itemCombo:addOptionWithData(shortLoc .. ": " .. (parts[pi]:gsub("^.-%.", "")), pt .. "=" .. parts[pi])
                    any = true
                end
                self.itemCombo:addOptionWithData(shortLoc .. ": (detach)", pt .. "=")
                any = true
            end
        end
        if not any then self.itemCombo:addOptionWithData("(no swappable parts)", "") end
    else
        self.itemCombo:addOptionWithData("(empty / clear hand)", "")
        for i = 1, #AE.rfx.propItems do
            self.itemCombo:addOptionWithData((AE.rfx.propItems[i]:gsub("^.-%.", "")), AE.rfx.propItems[i])
        end
    end
    self.itemCombo.selected = 1
end

-- gwSetPart uses the parts combo; every other event uses the prop label + Props... picker button.
function ReloadFxWindow:updatePropControls(ev)
    local isPart = (ev == "gwSetPart")
    if self.itemCombo then self.itemCombo:setVisible(isPart) end
    if self.propLbl then self.propLbl:setVisible(not isPart) end
    if self.propsBtn then self.propsBtn:setVisible(not isPart) end
    if not isPart and self.propWin and self.propWin.getIsVisible and self.propWin:getIsVisible() then
        self.propWin:refreshContext()
    end
end

-- Open (or focus) the tabbed prop picker window: pick from the weapon's attachments, the mod's items,
-- any base-game item, or your favourites. Selecting a row sets the value the next "Add here" uses.
function ReloadFxWindow:onOpenProps()
    if self.propWin and self.propWin.getIsVisible and self.propWin:getIsVisible() then
        self.propWin:refreshContext()
        self.propWin:bringToTop()
        return
    end
    self.propWin = PropPickerWindow:new(self:getRight() + 8, self:getY(), {
        target = self,
        onPick = ReloadFxWindow.onPropPicked,
        includeClear = true,
        contextFn = function()
            local g = rfxGun()
            return AE.rfx.mod, g and g:getFullType() or nil
        end,
    })
    self.propWin:initialise(); self.propWin:instantiate(); self.propWin:addToUIManager()
end

-- Truncate `text` with an ellipsis so it fits `maxPx` at the label font - keeps a long prop name from
-- sliding under the right-aligned Props... button.
function ReloadFxWindow:fitLabel(text, maxPx)
    if not maxPx or maxPx <= 0 then return text end
    local tm = getTextManager()
    if tm:MeasureStringX(UIFont.Small, text) <= maxPx then return text end
    while #text > 1 and tm:MeasureStringX(UIFont.Small, text .. "...") > maxPx do
        text = text:sub(1, #text - 1)
    end
    return text .. "..."
end

function ReloadFxWindow:onPropPicked(ft)
    self.chosenProp = ft or ""
    if self.propLbl then
        local name = (ft == nil or ft == "") and "(none - pick a prop)" or (tostring(ft):gsub("^.-%.", ""))
        self.propLbl:setName(self:fitLabel(name, self.rfxPropLabelW))
    end
end

function ReloadFxWindow:onAdd()
    local ev = self.evCombo:getOptionData(self.evCombo.selected) or "gwSetProp"
    local val
    if ev == "gwSetPart" then
        val = self.itemCombo:getOptionData(self.itemCombo.selected) or ""
        if val == "" then return end   -- no swappable parts discovered for this gun
    else
        val = self.chosenProp or ""    -- prop events: the item chosen in the tabbed picker ("" = clear)
    end
    if barCombined() then
        -- add at the global playhead -> the clip it lands in owns the new marker, at its local time
        local s, lf = rfxGlobalToStage(rfxGlobalFrac())
        local stages = AE.rfx.group.stages
        stages[s].markers = stages[s].markers or {}
        stages[s].markers[#stages[s].markers + 1] = { event = ev, timePc = lf, value = val }
    else
        AE.rfx.markers[#AE.rfx.markers + 1] = { event = ev, timePc = markerFrac(), value = val }
    end
    if self.bar then self.bar:reapply() end
end

-- Write the currently-pointed node's markers into the mod: the reloadMarkers spec (anim_edit.json)
-- plus a small bake request the Anim Forge watcher picks up, writing back a result we poll for below.
-- No manual bake step. Refreshes the scan cache too so reopening the editor shows the saved state
-- (the bake edits the mod XML but does NOT rewrite reload_markers.json, which the picker reads).
-- Flush the current stage's edited markers back into its project stage (+ persist), so the reload-set
-- editor and a later reopen read the same markers. No-op for foreign reloads with no owning project.
function ReloadFxWindow:flushMarkersToProject()
    if not AE.rfx.boundToProject or not AE.gw or not AE.gw.stages then return end
    local gs = AE.rfx.group and AE.rfx.stageIndex and AE.rfx.group.stages[AE.rfx.stageIndex]
    local key = gs and rfxStageKey(gs.stage)
    local ps = key and AE.gw.stages[key]
    if not ps then return end
    ps.markers = rfxCopyMarkers(AE.rfx.markers)
    -- Persist without wiping pose deltas: saveProject -> buildProject captures AE.deltas onto the
    -- active stage, but the pose editor is not the active surface here (AE.deltas is stale), so nil the
    -- active stage across the save to skip that capture. Only markers changed; poses stay intact.
    local savedActive = AE.gw.activeStage
    AE.gw.activeStage = nil
    pcall(saveProject)   -- type-aware: rebuilds + persists the gunworks project
    AE.gw.activeStage = savedActive
end

-- Copy EVERY stage's current markers into the project (in memory, no bake, no persist), so the unified
-- "Save changes" (which bakes the whole pack) picks up all your marker edits, not just the focused stage.
function ReloadFxWindow:captureMarkersToProject()
    if not AE.rfx.boundToProject or not AE.gw or not AE.gw.stages or not AE.rfx.group then return end
    -- fold the focused stage's live edits into its group stage first
    local cur = AE.rfx.stageIndex and AE.rfx.group.stages[AE.rfx.stageIndex]
    if cur then cur.markers = rfxCopyMarkers(AE.rfx.markers) end
    for i = 1, #AE.rfx.group.stages do
        local gs = AE.rfx.group.stages[i]
        local ps = AE.gw.stages[rfxStageKey(gs.stage)]
        if ps then ps.markers = rfxCopyMarkers(gs.markers or {}) end
    end
end

function ReloadFxWindow:writeBakeRequestForCurrent()
    if not rfxSave("") then return false end
    rfxUpdateCachedMarkers()
    self:flushMarkersToProject()
    local ts = getTimestampMs()
    local writer = getFileWriter("AnimForge/rfx_bake_request.json", true, false)
    if writer then
        writer:write(AnimForge.JSON.encode({ ts = ts, nodeFile = AE.rfx.nodeFile, animId = AE.rfx.animId }))
        writer:close()
        self.bakeTs = ts
        self.bakePoll = 0
        self.hintLbl:setName("Saving into the mod (auto-baking)...")
    else
        self.hintLbl:setName("saved -> run the Anim Forge watcher, then restart to see it")
    end
    return true
end

-- Point the working state at stage `idx`'s node/markers (no clip force -- this is a headless save
-- step, not a preview) and bake it. The prerender poll advances the queue as each result lands.
function ReloadFxWindow:saveNextStage()
    if not self.saveQueue or #self.saveQueue == 0 then
        self.saveQueue = nil
        if self.saveResumeStage then rfxFocusStage(self.saveResumeStage); self.saveResumeStage = nil end
        self.hintLbl:setName("All stages baked into the mod.")
        return
    end
    local idx = table.remove(self.saveQueue, 1)
    local st = AE.rfx.group.stages[idx]
    AE.rfx.stageIndex = idx
    AE.rfx.nodeFile = st.nodeFile
    AE.rfx.clip = st.clip
    AE.rfx.animId = st.animId
    AE.rfx.markers = st.markers or {}
    self:writeBakeRequestForCurrent()
end

-- Save. When this reload has an owning project (the normal case), route to the hub's one unified
-- "Save changes": it folds these markers + any bone pose into the project and bakes the whole pack, so
-- the set editor and this editor never disagree about what's saved. A foreign reload with no project
-- falls back to baking just its node markers (combined mode bakes every stage one at a time).
function ReloadFxWindow:onSave()
    if AE.rfx.boundToProject and AE.hub and AE.hub.saveChanges then
        self.hintLbl:setName("Saving all changes into the mod...")
        AE.hub:saveChanges()   -- captures these markers (+ any pose) into the project, then full bake
        return
    end
    if barCombined() then
        self.saveResumeStage = AE.rfx.stageIndex
        self.saveQueue = {}
        for i = 1, #AE.rfx.group.stages do self.saveQueue[i] = i end
        self:saveNextStage()
    else
        self:writeBakeRequestForCurrent()
    end
end

-- Reflect the loaded clip's prop-socket state on the rotation-fix row: hidden when the clip has no
-- prop socket, ticked (no live override) when the .glb is already baked-correct, unticked otherwise.
-- Always clears any override carried over from a previously-loaded clip.
function ReloadFxWindow:refreshRotFix()
    if not self.rotFixTick then return end
    local has = rfxClipHasPropSocket()
    self.rotFixTick:setVisible(has)
    self.rotAllTick:setVisible(has)
    self.bakeFixBtn:setVisible(has)
    rfxClearPropOverrides()
    if not has then return end
    local fullyFixed = (#rfxNeededPropBones() == 0)
    self.rotFixTick:setSelected(1, fullyFixed)
    self.bakeFixBtn:setEnable(not fullyFixed)
    self.bakeFixBtn:setTitle(fullyFixed and "Fixed" or "Bake fix")
end

-- Tick: live-preview the -90X socket fix (or clear it). Purely visual until "Bake fix".
function ReloadFxWindow:onRotFixToggle()
    local on = self.rotFixTick and self.rotFixTick:isSelected(1)
    rfxSetLivePropFix(on)
    if self.hintLbl then
        self.hintLbl:setName(on and "Previewing rotation fix - click 'Bake fix' to keep it after restart."
            or "Live rotation fix off.")
    end
end

-- Bake: persist the -90X into the mod .glb (this clip, or the whole mod). Marker-guarded + polled
-- via the watcher's result file. Captures the needed sockets first so the live preview can stay
-- correct this session (the loaded .glb is still cached uncorrected until a restart).
function ReloadFxWindow:onBakeFix()
    local scope = (self.rotAllTick and self.rotAllTick:isSelected(1)) and "mod" or "clip"
    self.propFixBones = rfxNeededPropBones()
    local ts = rfxWritePropFixRequest(scope)
    if not ts then
        if self.hintLbl then
            self.hintLbl:setName(scope == "mod" and "no mod to fix for this reload"
                or "this clip is already fixed (nothing to bake)")
        end
        return
    end
    self.propFixTs = ts
    self.propFixScope = scope
    self.propFixPoll = 0
    if self.hintLbl then
        self.hintLbl:setName("Baking rotation fix" .. (scope == "mod" and " (whole mod)" or "") .. "...")
    end
end

function ReloadFxWindow:prerender()
    ISCollapsableWindow.prerender(self)
    if self.uiCollapsed then return end   -- minimized: only the title bar draws
    -- Repopulate the value combo when the event type changes (robust, no combo-callback dependency).
    local ev = self.evCombo and self.evCombo:getOptionData(self.evCombo.selected)
    if ev ~= self.rfxLastEv then
        self.rfxLastEv = ev
        self:rfxPopulateItemCombo()
        self:updatePropControls(ev)
    end
    -- poll for the host auto-bake result (written by the Anim Forge watcher after Save to mod)
    if self.bakeTs then
        self.bakePoll = (self.bakePoll or 0) + 1
        if self.bakePoll >= 15 then
            self.bakePoll = 0
            local ok, r = pcall(readJsonFile, "AnimForge/rfx_bake_result.json")
            if ok and r and r.ts == self.bakeTs then
                self.bakeTs = nil
                if r.ok and r.liveReload then
                    self.hintLbl:setName("Baked + hot-reloaded live -- do another reload to see the new timing.")
                elseif r.ok then
                    self.hintLbl:setName("Baked into the mod. Restart the game to see the new timing.")
                else
                    self.hintLbl:setName("Bake FAILED: " .. tostring(r.error or "unknown"))
                    self.saveQueue = nil   -- stop the multi-stage save on a failure
                end
                if self.saveQueue then self:saveNextStage() end   -- combined save: bake the next stage
            end
        end
    end
    -- poll for the prop-rotation-fix result (written by the watcher after "Bake fix")
    if self.propFixTs then
        self.propFixPoll = (self.propFixPoll or 0) + 1
        if self.propFixPoll >= 15 then
            self.propFixPoll = 0
            local ok, r = pcall(readJsonFile, "AnimForge/glb_prop_fix_result.json")
            if ok and r and r.ts == self.propFixTs then
                local scope = self.propFixScope
                self.propFixTs = nil
                if r.ok then
                    rfxMarkPropFixed(scope)
                    -- keep the just-baked sockets overridden this session (the loaded .glb is still
                    -- cached uncorrected); a restart loads the fixed file with no override needed.
                    if self.propFixBones and #self.propFixBones > 0 then
                        rfxSetLivePropFix(true, self.propFixBones)
                        if self.rotFixTick then self.rotFixTick:setSelected(1, true) end
                    end
                    if self.bakeFixBtn then self.bakeFixBtn:setEnable(false); self.bakeFixBtn:setTitle("Fixed") end
                    self.hintLbl:setName("Baked into the .glb - survives restart (preview shows it now).")
                else
                    self.hintLbl:setName("Rotation fix FAILED: " .. tostring(r.error or "unknown"))
                end
            end
        end
    end
    -- combined playback: run the cycle in order (Unload -> chosen Load -> Rack), advancing through the
    -- combined stage list -- NOT raw group indices, so the unselected Load variant is skipped. A large
    -- jump in the forced-clip time = the clip wrapped (played to its end); abs handles reversed clips
    -- (the unload plays backwards) as well as forward ones.
    if AE.playing and barCombined() then
        local len = getClipLen()
        local t = getClipTime()
        if self.prevClipTime and len > 0 and math.abs(t - self.prevClipTime) > len * 0.5 then
            local cs = rfxCombinedStages()
            local pos = 1
            for i = 1, #cs do if cs[i] == AE.rfx.stageIndex then pos = i; break end end
            if pos >= #cs then
                AE.playing = false
                setClipPaused(true)
                if self.playBtn then self.playBtn:setTitle("Play") end
                if cs[1] then rfxFocusStage(cs[1]) end
                setClipTime(0)
            else
                rfxFocusStage(cs[pos + 1]); setClipTime(0); setClipPaused(false)
            end
            t = getClipTime()
            if self.bar then self.bar:reapply() end
        end
        self.prevClipTime = t
    else
        self.prevClipTime = nil
    end
    -- Follow the playhead during Play: apply the folded prop/part state every frame so the hand /
    -- off-hand props appear as the clip plays. rfxApplyStateAt only mutates when the folded state
    -- crosses a marker, so this is cheap. Without it, Play left the props at their last-scrubbed
    -- state (hand/off-hand read "empty" until you dragged the scrubber).
    if AE.playing and AE.rfx.active then
        rfxApplyStateAt(markerFrac())
    end
    -- reflect the playhead on the scrub thumb (global position in combined mode)
    if self.scrub and not (self.bar and self.bar.dragM) then
        local v
        if barCombined() then
            v = rfxGlobalFrac()
        else
            local len = getClipLen()
            v = (len > 0) and (getClipTime() / len) or nil
        end
        if v then self.scrub:setCurrentValue(v, true) end
    end
    if self.nowLbl then
        local RA = getReloadAnim()
        local p = getPlayer()
        local function slotName(loc)
            if not (RA and p and loc) then return "empty" end
            local item = p:getAttachedItem(loc)
            return item and (item:getFullType():gsub("^.-%.", "")) or "empty"
        end
        self.nowLbl:setName("hand: " .. slotName(RA and RA.RELOAD_HAND_ATTACH_LOCATION)
            .. "    off-hand: " .. slotName(RA and RA.RELOAD_MAGAZINE_ATTACH_LOCATION))
    end
end

function ReloadFxWindow:close()
    AE.rfx.bar = nil
    AE.rfx.window = nil
    AE.rfx.group = nil
    AE.rfx.stageIndex = nil
    AE.rfx.combined = false
    AE.rfx.boundToProject = false
    if self.propWin then self.propWin:removeFromUIManager(); self.propWin = nil end
    rfxClearPropOverrides()   -- never leave a -90X socket override on the player after closing
    rfxStopPreview()
    self:removeFromUIManager()
end

-- Open the reload attachment editor for a picker row. A row is a grouped reload (carries .stages);
-- older callers may still pass a bare single-node reload. Either way we normalise to a group and load
-- a default stage (the first with markers, else the first), then the stage switcher drives the rest.
local function openReloadFx(reload)
    if AE.rfx.window then AE.rfx.window:close() end
    -- Ensure the mod-clip cache is loaded so the rotation-fix tick can resolve the reload's clip ->
    -- its .glb + prop-socket state, even if the "Mods" tab was never opened this session.
    -- (#AE.modClipNames, not next(): Kahlua drops a trailing-nil arg so next(t,nil) still crashes)
    if loadModClipsFromCache and not (AE.modClipNames and #AE.modClipNames > 0) then
        pcall(loadModClipsFromCache)
    end
    local group
    if reload and reload.stages then
        group = reload
    elseif reload then
        group = { mod = reload.mod, animId = reload.animId, propItems = reload.propItems, stages = { reload } }
    end
    if not group then return false end
    -- Bind to the reload's owning project + seed this editor's markers from it (project canonical), so
    -- edits mirror the reload-set editor. Done before the default-stage pick so the pick sees project markers.
    rfxBindProject(group)
    rfxSeedGroupFromProject(group)
    local stage = group.stages[1]
    for i = 1, #group.stages do
        if group.stages[i].markers and #group.stages[i].markers > 0 then stage = group.stages[i]; break end
    end
    if not stage then return false end
    AE.rfx.group = group
    AE.rfx.combined = false   -- start in per-stage mode; the "All clips" toggle opts into combined
    AE.rfx.stageIndex = 1
    for i = 1, #group.stages do if group.stages[i] == stage then AE.rfx.stageIndex = i end end
    if not rfxLoad(stage) then return false end
    local px = (AE.hub and AE.hub:getRight() + 8) or 200
    local py = (AE.hub and AE.hub:getY()) or 110
    AE.rfx.window = ReloadFxWindow:new(px, py)
    AE.rfx.window:initialise(); AE.rfx.window:addToUIManager()
    return true
end

-- A small draggable window the timeline pops out into. It hosts the editor's
-- timeHost (re-parented in, not duplicated); closing it docks the timeline back.
TimelineWindow = ISCollapsableWindow:derive("TimelineWindow")

function TimelineWindow:new(x, y)
    local o = ISCollapsableWindow.new(self, x or 120, y or 120, TIMELINE_POP_W, 132)
    o.title = "Timeline"
    o.resizable = false
    return o
end

function TimelineWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    self:setResizable(false)
end

-- Close button docks the timeline back into the editor (so it is never orphaned).
function TimelineWindow:close()
    if AE.panel then
        AE.panel:dockTimeline()
    elseif AE.timelineWin then
        AE.timelineWin:removeFromUIManager(); AE.timelineWin = nil
    end
end

local function fmt(kind, v)
    if kind == "rot" then return tostring(math.floor(v + 0.5)) end
    return string.format("%.2f", v)
end

function AnimEditorPanel:syncSliders()
    local d = ensureDelta(AE.bone)
    for i = 1, 3 do
        self.sliders.rot[i]:setCurrentValue(d.rot[i], true)
        self.valLabels.rot[i]:setName(fmt("rot", d.rot[i]))
        self.sliders.pos[i]:setCurrentValue(d.pos[i], true)
        self.valLabels.pos[i]:setName(fmt("pos", d.pos[i]))
    end
end

-- A new clip resets the forced time to 0 (setForcedEditClip clears it on name change);
-- mirror that on the scrub bar + time label.
function AnimEditorPanel:resetScrubDisplay()
    if self.scrub then self.scrub:setCurrentValue(0, true) end
    self:updateTimeLabel(0, getClipLen())
end

-- Force the editor's currently loaded clip onto the player + name it in the status
-- line. Clip/weapon selection now happens in the Browse window; this is the shared
-- apply path (also used by the load-weapon headless op).
function AnimEditorPanel:applyLoadedClip()
    forceClip(AE.clip)
    self:resetScrubDisplay()
    self.status:setName("clip: " .. AE.clip)
end

function AnimEditorPanel:onBone(combo)
    AE.bone = self.boneCombo:getOptionText(self.boneCombo.selected)
    self:syncSliders()
    self.status:setName("bone: " .. AE.bone)
end

function AnimEditorPanel:onSlider(value, slider)
    local d = ensureDelta(AE.bone)
    d[slider.kind][slider.axisIndex] = value
    recordKf(AE.bone)   -- auto-record a keyframe at the current time, same as the gizmo
    applyBone(AE.bone)
    self.valLabels[slider.kind][slider.axisIndex]:setName(fmt(slider.kind, value))
end

function AnimEditorPanel:onSave()
    saveJson(false)
    local meta = AE.modClips and AE.modClips[AE.clip]
    if meta and meta.format == "glb" then
        -- Mod .glb clip: saveJson wrote a glb bake block; the watcher rewrites the clip's bone keys
        -- in place (non-cumulative, from a pristine copy). The live pose already shows it; a restart
        -- loads the baked file.
        self.status:setName("saved -> baking " .. (meta.stem or AE.clip) .. ".glb")
    else
        self.status:setName("saved (single .x)")
    end
end

-- Export the active grip set as separate renamed anims into AE.mod. The hub's
-- mode screen owns the name/mod/tag fields and writes them to AE.* before calling
-- this, so it reads the single source of truth (AE.namePrefix / AE.mod / AE.tag).
function AnimEditorPanel:onSaveSet()
    if not AE.mod or AE.mod == "" then
        self.status:setName("enter a mod name first")
        return false
    end
    saveProject()    -- keep the on-disk project in sync with the bake export
    saveJson(true)
    self.status:setName("saved set '" .. AE.namePrefix .. "' -> " .. AE.mod)
    return true
end

function AnimEditorPanel:onReset()
    local byClip = AE.keyframes[AE.clip]
    if byClip then byClip[AE.bone] = nil end   -- drop this bone's keyframes for the clip
    AE.deltas[AE.bone] = { rot = { 0, 0, 0 }, pos = { 0, 0, 0 } }
    applyBone(AE.bone)
    self:syncSliders()
    self.status:setName("reset " .. AE.bone)
end

-- True (+ the stage key) when the pose editor is editing a reload stage, so the
-- shared Mark-done / done badge target the STAGE flag, not a grip clip.
local function editingReloadStage()
    local hub = AE.hub
    if hub and hub.mode == "reload" and hub.reloadEditing then return hub.reloadEditing end
    return nil
end

-- Reflect the current clip's (or reload stage's) done state on the Mark-done title.
function AnimEditorPanel:refreshDoneBtn()
    if not self.doneBtn then return end
    local stageKey = editingReloadStage()
    if stageKey then
        local s = AE.gw.stages[stageKey]
        self.doneBtn:setTitle((s and s.done) and "Undo done" or "Mark done")
        return
    end
    local title = "Mark done"
    if AE.project and AE.done[AE.clip] == true then title = "Undo done" end
    self.doneBtn:setTitle(title)
end

function AnimEditorPanel:onMarkDone()
    -- Reload stage: there is no grip "project"; toggle the stage's own done flag.
    local stageKey = editingReloadStage()
    if stageKey then
        local s = AE.gw.stages[stageKey]
        if s then
            s.done = not (s.done == true)
            self:refreshDoneBtn()
            self.status:setName((s.done and "stage done: " or "stage todo: ") .. stageKey)
            if AE.project and AE.project.type == "gunworks" then saveProject() end   -- persist now, like grip
        end
        return
    end
    if not AE.project then
        self.status:setName("no set yet - click Create (grip) or Export (reload) to start one")
        return
    end
    local nowDone = not (AE.done[AE.clip] == true)
    setClipDone(AE.clip, nowDone)
    self:refreshDoneBtn()
    local label = "todo: "
    if nowDone then label = "done: " end
    self.status:setName(label .. AE.clip)
    if AE.browser then AE.browser:relayout() end
end

function AnimEditorPanel:onNodesTick(index, selected)
    AE.showNodes = selected and true or false
end

function AnimEditorPanel:onGizmoMode()
    AE.gizmoMode = (AE.gizmoMode == "rot") and "pos" or "rot"
    self.gizmoBtn:setTitle("Gizmo: " .. (AE.gizmoMode == "rot" and "Rotate" or "Translate"))
end

function AnimEditorPanel:onThick(value) AE.gizmoThick = value end
function AnimEditorPanel:onAlpha(value) AE.gizmoAlpha = value end

function AnimEditorPanel:updateTimeLabel(t, len)
    if not self.timeLbl then return end
    local byClip = AE.keyframes[AE.clip]
    local list = byClip and byClip[AE.bone]
    self.timeLbl:setName(string.format("%.2f / %.2fs  (%d kf)", t, len, list and #list or 0))
end

function AnimEditorPanel:onClearKf()
    local byClip = AE.keyframes[AE.clip]
    if byClip then byClip[AE.bone] = nil end
    AE.deltas[AE.bone] = { rot = { 0, 0, 0 }, pos = { 0, 0, 0 } }
    applyBone(AE.bone)
    self:syncSliders()
    self:updateTimeLabel(getClipTime(), getClipLen())
    self.status:setName("cleared keyframes: " .. AE.bone)
end

function AnimEditorPanel:onPlayPause()
    AE.playing = not AE.playing
    setClipPaused(not AE.playing)
    self.playBtn:setTitle(AE.playing and "Pause" or "Play")
end

function AnimEditorPanel:onScrub(value, slider)
    AE.playing = false
    setClipPaused(true)
    local len = getClipLen()
    setClipTime(value * len)
    self.playBtn:setTitle("Play")
    self:updateTimeLabel(value * len, len)
end

-- Draw the active tab's section headers, then reflect the live clip time on the
-- scrub bar + time label each frame. (Keyframe ticks are drawn + handled by the
-- KeyframeBar child strip above the scrub.)
function AnimEditorPanel:prerender()
    ISPanel.prerender(self)
    local T = AnimForge.AnimForgeTheme
    local pad = T.sp.m
    local W = self.width
    if self.activeTab == "gizmo" then
        T.sectionHeader(self, pad, self.yGizmo, W - pad * 2, "GIZMO SETTINGS")
    else
        T.text(self, "Rotation (deg)", pad, self.yRot, T.col.text2)
        T.text(self, "Translation", pad, self.yTrans, T.col.text2)
        if AE.timelineWin then
            T.text(self, "Timeline popped out -> see the Timeline window.", pad, self.yTime + 4, T.col.muted)
        else
            T.sectionHeader(self, pad, self.yTime, W - pad * 2, "TIMELINE")
        end
    end

    if not self.scrub then return end
    local len = getClipLen()
    local t = getClipTime()
    if len > 0 then
        -- reflect the clip time on the thumb: playback, manual scrub, and keyframe drag all move it
        self.scrub:setCurrentValue(t / len, true)
    end
    self:updateTimeLabel(t, len)   -- every frame, so the (N kf) count refreshes live
    self:refreshDoneBtn()
    -- If posing a reload stage that has markers, fold + paint its attached props at this frame, so the
    -- mag appears in the off-hand and moves with a Bip01_Prop2 pose tweak.
    AnimForge.EditCore.rfxApplyPosePreview()
end


AnimForge.ReloadFx = {
    RFX_EVENTS = RFX_EVENTS,
    openReloadFx = openReloadFx
}
