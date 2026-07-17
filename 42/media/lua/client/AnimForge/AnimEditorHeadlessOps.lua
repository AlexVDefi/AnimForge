-- Anim Forge editor: optional headless automation ops (all no-ops standalone).
require "AnimForge/AnimEditorCore"
require "AnimForge/AnimEditorHub"
require "AnimForge/AnimEditorBrowser"
require "AnimForge/AnimEditorReloadFx"
require "AnimForge/JSON"

-- Optional headless op surface. Registered through AnimForge.registerOp (a no-op unless an
-- automation layer replaces it), so standalone nothing here runs or is required.
local D = { register = function(name, side, fn) AnimForge.registerOp(name, side, fn) end }
local GW = AnimForge.Browser.GW
local closeBrowser = AnimForge.Browser.closeBrowser
local openBrowser = AnimForge.Browser.openBrowser
local animPlayer = AnimForge.EditCore.animPlayer
local applyModClips = AnimForge.EditCore.applyModClips
local ensureDelta = AnimForge.EditCore.ensureDelta
local forceClip = AnimForge.EditCore.forceClip
local getClipLen = AnimForge.EditCore.getClipLen
local getClipTime = AnimForge.EditCore.getClipTime
local getReloadAnim = AnimForge.EditCore.getReloadAnim
local loadModClipsFromCache = AnimForge.EditCore.loadModClipsFromCache
local loadProject = AnimForge.EditCore.loadProject
local loadReloadsFromCache = AnimForge.EditCore.loadReloadsFromCache
local loadWeapon = AnimForge.EditCore.loadWeapon
local markerFrac = AnimForge.EditCore.markerFrac
local newProject = AnimForge.EditCore.newProject
local projectProgress = AnimForge.EditCore.projectProgress
local rfxApplyStateAt = AnimForge.EditCore.rfxApplyStateAt
local rfxGroupedReloads = AnimForge.EditCore.rfxGroupedReloads
local rfxGlobalToStage = AnimForge.EditCore.rfxGlobalToStage
local rfxStageCount = AnimForge.EditCore.rfxStageCount
local rfxCombinedStages = AnimForge.EditCore.rfxCombinedStages
local rfxStageDisplay = AnimForge.EditCore.rfxStageDisplay
local rfxFindReload = AnimForge.EditCore.rfxFindReload
local rfxFirstEditable = AnimForge.EditCore.rfxFirstEditable
local rfxGun = AnimForge.EditCore.rfxGun
local rfxLoad = AnimForge.EditCore.rfxLoad
local rfxSave = AnimForge.EditCore.rfxSave
local rfxStartPreview = AnimForge.EditCore.rfxStartPreview
local rfxStopPreview = AnimForge.EditCore.rfxStopPreview
local saveJson = AnimForge.EditCore.saveJson
local saveProject = AnimForge.EditCore.saveProject
local setClipDone = AnimForge.EditCore.setClipDone
local setClipPaused = AnimForge.EditCore.setClipPaused
local setClipTime = AnimForge.EditCore.setClipTime
local setPos = AnimForge.EditCore.setPos
local setRot = AnimForge.EditCore.setRot
local closePanel = AnimForge.Hub.closePanel
local openPanel = AnimForge.Hub.openPanel
local RFX_EVENTS = AnimForge.ReloadFx.RFX_EVENTS
local openReloadFx = AnimForge.ReloadFx.openReloadFx
local AE = AnimForge.AnimEdit
local AP = AnimForge.AnimProjects

-- --------------------------------------------- headless ops (optional automation) ---
D.register("open_anim_editor", "client", function(args)
    if args.clip then AE.clip = args.clip end
    if args.bone then AE.bone = args.bone end
    loadModClipsFromCache()
    openPanel()
    return { open = true, clip = AE.clip, bone = AE.bone, modClips = #AE.modClipNames }
end)

D.register("close_anim_editor", "client", function(args)
    closePanel()
    return { closed = true }
end)

D.register("anim_editor_force_clip", "client", function(args)
    local clip = args.clip
    if not clip or clip == "" then
        forceClip(nil)
        if AE.panel then AE.panel.status:setName("clip: (free)") end
        return { cleared = true }
    end
    AE.clip = clip
    local ok = forceClip(clip)
    if AE.panel then AE.panel.status:setName("clip: " .. clip) end
    return { ok = ok, forced = clip }
end)

-- Load a weapon's clip set into the editor (grip set, or all with all=true).
D.register("anim_editor_load_weapon", "client", function(args)
    if not loadWeapon(args.weapon or AE.weapon, args.all == true) then
        return { error = "unknown weapon: " .. tostring(args.weapon) }
    end
    if AE.panel then AE.panel:applyLoadedClip() end
    return { ok = true, weapon = AE.weapon, useAll = AE.useAll, count = #AE.clips, clips = AE.clips }
end)

-- Programmatic slider drive (for automation). Rotation via ex/ey/ez, translation via tx/ty/tz.
D.register("anim_editor_set", "client", function(args)
    local bone = args.bone or AE.bone
    AE.bone = bone
    if args.ex or args.ey or args.ez then
        setRot(bone, args.ex or 0, args.ey or 0, args.ez or 0)
    end
    if args.tx or args.ty or args.tz then
        setPos(bone, args.tx or 0, args.ty or 0, args.tz or 0)
    end
    if AE.panel then AE.panel.boneCombo:select(bone); AE.panel:syncSliders() end
    local d = ensureDelta(bone)
    return { ok = true, bone = bone, rot = d.rot, pos = d.pos }
end)

-- Attach a registered model to the prop bone to preview a non-equippable gun.
D.register("anim_editor_attach_model", "client", function(args)
    local p = getPlayer(); if not p then return { error = "no player" } end
    local ap = p:getAnimationPlayer(); if not ap then return { error = "no animPlayer" } end
    local model = args.model
    local secondary = args.secondary == true
    local ok, err = pcall(function() ap:setCharacterOverrideHandModel(model or "", secondary) end)
    return { ok = ok, model = model, secondary = secondary, err = (not ok) and tostring(err) or nil }
end)

D.register("anim_editor_save", "client", function(args)
    if args.clip then AE.clip = args.clip end
    saveJson(false)
    return { saved = true, clip = AE.clip, deltas = AE.deltas }
end)

-- Push a discovered clip list into the editor so mod clips appear in the "Mods"
-- browser tab. Each entry: { mod, stem, name, format, srcPath, animsSubdir }. Keyed by stem
-- (the force-play name the AnimSet nodes use); the editor tries that first in-game.
D.register("anim_mod_clips_set", "client", function(args)
    applyModClips(args and args.clips)
    if AE.browser then AE.browser:refilter() end
    return { ok = true, count = #AE.modClipNames }
end)

-- Save the current (mod .glb) clip's edits, choosing the output file. dst = "" or nil saves in
-- place (overwrites the source .glb); a non-empty dst writes a new .glb. The baker applies the
-- -90X convention compensation so the live-authored pose reproduces in-game.
D.register("anim_editor_save_glb", "client", function(args)
    local meta = AE.modClips[AE.clip]
    if not meta or meta.format ~= "glb" then
        return { error = "current clip is not a mod .glb clip: " .. tostring(AE.clip) }
    end
    AE.glbDst = (args and args.dst) or ""
    saveJson(false)
    return {
        saved = true, clip = AE.clip, srcGlb = meta.srcPath,
        dst = (AE.glbDst ~= "") and AE.glbDst or meta.srcPath,
        inPlace = AE.glbDst == "",
    }
end)

-- ----------------------------------------- reload attachment-marker editor headless ops ----
-- Re-apply the live preview after the marker set changed (force a full repaint of the folded state).
local function rfxRefresh()
    AE.rfx.appliedProp = nil
    AE.rfx.appliedHandProp = nil
    AE.rfx.appliedParts = {}
    if AE.rfx.active then rfxApplyStateAt(markerFrac()) end
end

---@nodiscard
---@return string[]
local function rfxGunParts()
    local gun = rfxGun()
    local out = {}
    if gun then
        local all = gun:getAllWeaponParts()
        if all and all.size then
            for i = 0, all:size() - 1 do
                local part = all:get(i)
                if part then out[#out + 1] = part:getFullType() end
            end
        end
    end
    return out
end

---@nodiscard
---@return string
local function rfxCurrentProp()
    local RA = getReloadAnim()
    local p = getPlayer()
    if not RA or not p then return "" end
    local item = p:getAttachedItem(RA.RELOAD_MAGAZINE_ATTACH_LOCATION)
    return item and item:getFullType() or ""
end

-- Nearest marker index to a timePc, or nil.
---@nodiscard
---@return number|nil
local function rfxNearest(frac)
    local best, bi = 999, nil
    for i = 1, #AE.rfx.markers do
        local d = math.abs((AE.rfx.markers[i].timePc or 0) - frac)
        if d < best then best, bi = d, i end
    end
    return bi
end

D.register("anim_rfx_reloads", "client", function(args)
    loadReloadsFromCache()
    -- `groups` is what the picker actually lists: one row per (mod, animId) whose mod is enabled on
    -- this save, each carrying its stages (the raw cache also holds installed-but-disabled mods'
    -- per-stage nodes). `count` is the raw per-node cache size.
    local groups = rfxGroupedReloads()
    local slim = {}
    for i = 1, #groups do
        local g = groups[i]
        local stages = {}
        for j = 1, #g.stages do stages[j] = { stage = g.stages[j].stage, clip = g.stages[j].clip,
            markers = #(g.stages[j].markers or {}) } end
        slim[i] = { mod = g.mod, animId = g.animId, stages = stages,
                    markerCount = g.markerCount, propItems = #(g.propItems or {}) }
    end
    return { ok = true, count = #AE.rfx.reloads, shownCount = #groups, shown = slim }
end)

D.register("anim_rfx_load", "client", function(args)
    loadReloadsFromCache()
    local key = args and (args.animId or args.nodeFile)
    local reload = rfxFindReload(key)
    if not reload and not key then reload = rfxFirstEditable() end
    if not reload then return { error = "reload not found; run 'pz-anim-forge scan' first" } end
    if not rfxLoad(reload) then return { error = "could not load (Gunworks missing / no attach location / no gun)" } end
    return { ok = true, animId = AE.rfx.animId, clip = AE.rfx.clip, nodeFile = AE.rfx.nodeFile,
             markers = AE.rfx.markers, propItems = AE.rfx.propItems, active = AE.rfx.active,
             gunParts = rfxGunParts() }
end)

D.register("anim_rfx_list", "client", function(args)
    return { animId = AE.rfx.animId, clip = AE.rfx.clip, nodeFile = AE.rfx.nodeFile,
             markers = AE.rfx.markers, propItems = AE.rfx.propItems,
             active = AE.rfx.active, frac = markerFrac() }
end)

D.register("anim_rfx_preview", "client", function(args)
    if not AE.rfx.nodeFile then return { error = "no reload loaded" } end
    if not AE.rfx.active then rfxStartPreview() end
    if args and args.t ~= nil then
        local len = getClipLen()
        setClipPaused(true); AE.playing = false
        local f = tonumber(args.t) or 0
        if f < 0 then f = 0 elseif f > 1 then f = 1 end
        setClipTime(f * len)
    end
    rfxApplyStateAt(markerFrac())
    return { frac = markerFrac(), prop = rfxCurrentProp(), parts = rfxGunParts() }
end)

D.register("anim_rfx_marker_add", "client", function(args)
    if not AE.rfx.nodeFile then return { error = "no reload loaded" } end
    local event = args and args.event
    local validEvent = false
    for i = 1, #RFX_EVENTS do if RFX_EVENTS[i] == event then validEvent = true; break end end
    if not validEvent then
        return { error = "event must be one of gwSetProp / gwSetHandProp / gwPartToHand / gwPartToGun / gwSetPart" }
    end
    local timePc = tonumber(args and args.timePc)
    if timePc == nil then timePc = markerFrac() end
    if timePc < 0 then timePc = 0 elseif timePc > 1 then timePc = 1 end
    local m = { event = event, timePc = timePc, value = (args and args.value) or "" }
    AE.rfx.markers[#AE.rfx.markers + 1] = m
    AE.rfx.marker = m
    rfxRefresh()
    return { ok = true, added = m, markers = AE.rfx.markers }
end)

D.register("anim_rfx_marker_move", "client", function(args)
    if not AE.rfx.nodeFile then return { error = "no reload loaded" } end
    local idx = tonumber(args and args.index)
    if not idx and args and args.from ~= nil then idx = rfxNearest(tonumber(args.from) or 0) end
    if not idx or not AE.rfx.markers[idx] then return { error = "marker index/from not found" } end
    local to = tonumber(args and args.to) or 0
    if to < 0 then to = 0 elseif to > 1 then to = 1 end
    AE.rfx.markers[idx].timePc = to
    AE.rfx.marker = AE.rfx.markers[idx]
    rfxRefresh()
    return { ok = true, index = idx, timePc = to, markers = AE.rfx.markers }
end)

D.register("anim_rfx_marker_set", "client", function(args)
    local idx = tonumber(args and args.index)
    if not idx or not AE.rfx.markers[idx] then return { error = "marker index not found" } end
    local m = AE.rfx.markers[idx]
    if args.event then m.event = args.event end
    if args.value ~= nil then m.value = args.value end
    if args.timePc ~= nil then m.timePc = tonumber(args.timePc) or m.timePc end
    AE.rfx.marker = m
    rfxRefresh()
    return { ok = true, index = idx, marker = m }
end)

D.register("anim_rfx_marker_delete", "client", function(args)
    if not AE.rfx.nodeFile then return { error = "no reload loaded" } end
    local idx = tonumber(args and args.index)
    if not idx and args and args.t ~= nil then idx = rfxNearest(tonumber(args.t) or 0) end
    if not idx or not AE.rfx.markers[idx] then return { error = "marker not found" } end
    table.remove(AE.rfx.markers, idx)
    AE.rfx.marker = AE.rfx.markers[1]
    rfxRefresh()
    return { ok = true, markers = AE.rfx.markers }
end)

D.register("anim_rfx_save", "client", function(args)
    if not rfxSave(args and args.dst) then return { error = "no reload loaded" } end
    return { saved = true, nodeFile = AE.rfx.nodeFile,
             dst = (args and args.dst and args.dst ~= "") and args.dst or AE.rfx.nodeFile,
             markers = AE.rfx.markers }
end)

-- Trigger the "Save to mod" button (writes the reloadMarkers spec + the host auto-bake request),
-- exactly as clicking it does. Returns the request timestamp so a test can poll the bake result.
D.register("anim_rfx_click_save", "client", function(args)
    local w = AE.rfx and AE.rfx.window
    if not w or not w.onSave then return { error = "reload editor window not open" } end
    w:onSave()
    return { ok = true, bakeTs = w.bakeTs, nodeFile = AE.rfx.nodeFile }
end)

D.register("anim_rfx_stop", "client", function(args)
    rfxStopPreview()
    return { ok = true }
end)

-- Drive the "Correct ramrod rotation" controls on the open reload editor: report the loaded clip's
-- prop-socket state, optionally flip the live preview tick, pick the whole-mod scope, and/or click
-- "Bake fix". Mirrors the tick + button; returns the bake ts so a test can poll the fix result.
D.register("anim_rfx_prop_fix", "client", function(args)
    local w = AE.rfx and AE.rfx.window
    if not w or not w.onBakeFix then return { error = "reload editor window not open" } end
    if args and args.preview ~= nil and w.rotFixTick then
        w.rotFixTick:setSelected(1, args.preview and true or false)
        w:onRotFixToggle()
    end
    if args and args.whole ~= nil and w.rotAllTick then
        w.rotAllTick:setSelected(1, args.whole and true or false)
    end
    local ts
    if args and args.bake then
        w:onBakeFix()
        ts = w.propFixTs
    end
    return { ok = true, clip = AE.rfx.clip,
             needed = AnimForge.EditCore.rfxNeededPropBones(),
             hasSocket = AnimForge.EditCore.rfxClipHasPropSocket(),
             livePropFix = AE.rfx.livePropFix == true, bakeTs = ts }
end)

-- Create a reload set (if needed) + report each stage's base-animation selector (option count +
-- selected clip), optionally changing one stage's clip. Verifies the per-stage clip selectors.
D.register("anim_reload_stage_clips", "client", function(args)
    local h = AE.hub
    if not h then return { error = "hub not open" } end
    h:switchMode("reload")
    if not (AE.project and AE.project.type == "gunworks") then
        h.rAnimId:setText((args and args.animId) or "ClipTest")
        if h.rMod.options and #h.rMod.options > 0 then h.rMod.selected = 1 end
        h.rArch.selected = 1
        h:onReloadCreate()
    end
    if args and args.setStage and args.setClip then
        for i = 1, 4 do
            local combo = h.rStageRows[i].clip
            if combo.stageKey == args.setStage then
                for j = 1, #(combo.options or {}) do
                    if combo:getOptionData(j) == args.setClip then
                        combo.selected = j; h:onReloadStageClip(combo); break
                    end
                end
            end
        end
    end
    local stages = {}
    for i = 1, 4 do
        local combo = h.rStageRows[i].clip
        local key = combo.stageKey
        if key then
            stages[#stages + 1] = { stage = key, options = #(combo.options or {}),
                selected = combo:getOptionData(combo.selected),
                baseClip = AE.gw.stages[key] and AE.gw.stages[key].baseClip }
        end
    end
    return { ok = true, created = (AE.project ~= nil and AE.project.type == "gunworks"),
             modClips = #(AE.modClipNames or {}), stages = stages }
end)

-- Toggle the "All clips" combined timeline on the open editor, exactly as ticking the box does.
D.register("anim_rfx_set_combined", "client", function(args)
    local w = AE.rfx and AE.rfx.window
    if not w or not w.onCombinedToggle then return { error = "reload editor window not open" } end
    if w.combinedTick then w.combinedTick:setSelected(1, (args and args.on) and true or false) end
    w:onCombinedToggle()
    return { ok = true, combined = AE.rfx.combined, stages = rfxStageCount() }
end)

-- Add a marker at a bar fraction. In combined mode the fraction is GLOBAL and the return says which
-- stage (clip) it linked to -- the check that markers know their owning clip. Per-stage: local frac.
D.register("anim_rfx_add_marker_at", "client", function(args)
    if not (AE.rfx and AE.rfx.window) then return { error = "reload editor window not open" } end
    local ev = (args and args.event) or "gwSetProp"
    local val = (args and args.value) or ""
    local frac = (args and args.atFrac) or 0
    if AE.rfx.combined and rfxStageCount() > 1 then
        local s, lf = rfxGlobalToStage(frac)
        local st = AE.rfx.group.stages[s]
        st.markers = st.markers or {}
        st.markers[#st.markers + 1] = { event = ev, timePc = lf, value = val }
        return { ok = true, atFrac = frac, stage = s, stageName = st.stage, localFrac = lf }
    end
    AE.rfx.markers[#AE.rfx.markers + 1] = { event = ev, timePc = frac, value = val }
    return { ok = true, atFrac = frac, stage = AE.rfx.stageIndex }
end)

-- Open the tabbed prop picker window from the reload editor + report its state (row count per tab).
D.register("anim_rfx_open_props", "client", function(args)
    local w = AE.rfx and AE.rfx.window
    if not w or not w.onOpenProps then return { error = "reload editor window not open" } end
    w:onOpenProps()
    local pk = w.propWin and w.propWin.picker
    if pk and args and args.tab then
        for i = 1, #pk.tabBtns do
            if pk.tabBtns[i].internal == args.tab then pk:onTab(pk.tabBtns[i]); break end
        end
    end
    if pk and args and args.search then pk.filter:setText(args.search); pk._lastFilter = nil; pk:refilter() end
    -- _rows is the tab's source set (synchronous); list.items only fills on the next prerender.
    local vs = pk and pk.list and pk.list.vscroll
    local scrollH = pk and pk.list and pk.list:getScrollHeight()
    return { ok = true, hasWindow = pk ~= nil, tab = pk and pk.tab,
             rows = (pk and pk._rows and #pk._rows) or 0,
             listRows = (pk and pk.list and #pk.list.items) or 0, chosenProp = w.chosenProp,
             listH = pk and pk.list and pk.list:getHeight(), scrollH = scrollH,
             vscrollH = vs and vs:getHeight(),
             sbarShowing = (vs ~= nil and scrollH ~= nil and vs:getHeight() < scrollH) }
end)

-- Pop the two-column test rig into its own window + report the weapon list size (source count).
D.register("anim_rig_popout", "client", function(args)
    local h = AE.hub
    if not h or not h.onRigPopOut then return { error = "hub not open" } end
    h:onRigPopOut()
    local rig = h.rigWin and h.rigWin.rig
    return { ok = true, hasWindow = rig ~= nil, modId = rig and rig:modId(),
             guns = (rig and rig.gunPicker and #rig.gunPicker.items) or 0 }
end)

-- Simulate a real mouse click on a row's favourite star (drives the list's actual onMouseDown handler
-- at the star coordinates), then report the Favourites-tab count -- verifies the click reaches the
-- star zone + toggles, not just that toggleFavorite works when called directly.
D.register("anim_prop_click_star", "client", function(args)
    local w = AE.rfx and AE.rfx.window
    local pk = w and w.propWin and w.propWin.picker
    if not pk then return { error = "prop picker not open" } end
    local row = (args and args.row) or 2
    local lb = pk.list
    if not (lb.items and lb.items[row]) then return { error = "no row " .. tostring(row) } end
    local data = lb.items[row].item
    local x = lb:getWidth() - 10                                   -- inside the star gutter
    local y = (row - 1) * lb.itemheight + math.floor(lb.itemheight / 2)
    lb.onMouseDown(lb, x, y)                                       -- the real handler (star-zone override)
    for i = 1, #pk.tabBtns do
        if pk.tabBtns[i].internal == "fav" then pk:onTab(pk.tabBtns[i]); break end
    end
    return { ok = true, clicked = data and data.fullType, favRows = #pk._rows }
end)

-- Toggle a favourite in the open prop picker, then switch to the Favourites tab + report its count
-- (verifies favouriting + the fav tab + persistence to prop_favorites.json).
D.register("anim_prop_favorite", "client", function(args)
    local w = AE.rfx and AE.rfx.window
    local pk = w and w.propWin and w.propWin.picker
    if not pk then return { error = "prop picker not open" } end
    if args and args.fullType then pk:toggleFavorite(args.fullType) end
    for i = 1, #pk.tabBtns do
        if pk.tabBtns[i].internal == "fav" then pk:onTab(pk.tabBtns[i]); break end
    end
    return { ok = true, favRows = #pk._rows }
end)

-- Probe the live test rig (popout if open, else the embedded panel): mod, weapon + attachment counts.
D.register("anim_rig_state", "client", function(args)
    local rig = (AE.hub and AE.hub.rigWin and AE.hub.rigWin.rig) or (AE.hub and AE.hub.rigPanel)
    if not rig then return { error = "no test rig" } end
    if args and args.selectGun then rig:onGunSelect(args.selectGun) end
    return { ok = true, modId = rig:modId(), selectedGun = rig.selectedGun,
             sourceGuns = (rig.gunPicker and #rig.gunPicker.items) or 0,
             attachments = (rig.attachPicker and #rig.attachPicker.items) or 0 }
end)

-- Dump the grouped reload's per-stage marker counts + the ordered combined-bar view (verifies the
-- cycle order Unload -> chosen Load -> Rack, and that only the selected load variant is shown).
D.register("anim_rfx_group_state", "client", function(args)
    local g = AE.rfx and AE.rfx.group
    if not g then return { error = "no grouped reload loaded" } end
    local stages = {}
    for i = 1, #g.stages do
        stages[i] = { stage = g.stages[i].stage, markers = #(g.stages[i].markers or {}) }
    end
    local cs = rfxCombinedStages()
    local view = {}
    for i = 1, #cs do view[i] = rfxStageDisplay(g.stages[cs[i]].stage) end
    return { ok = true, combined = AE.rfx.combined, loadVariant = AE.rfx.loadVariant,
             stageIndex = AE.rfx.stageIndex, stages = stages, combinedView = view }
end)

-- Switch which Load variant the combined bar shows, exactly as the "Load / Short load" combo does.
D.register("anim_rfx_set_load_variant", "client", function(args)
    local w = AE.rfx and AE.rfx.window
    if not w or not w.onLoadVariantChange then return { error = "reload editor window not open" } end
    local v = (args and args.variant) or "load"
    if w.loadVariantCombo then w.loadVariantCombo.selected = (v == "loadshort") and 2 or 1 end
    w:onLoadVariantChange()
    return { ok = true, loadVariant = AE.rfx.loadVariant }
end)

-- Open the "Reload Attachments" editor window for a reload (loads it + live preview). No animId ->
-- the first discovered reload. Opens the grouped reload (all its stages), matching the hub picker.
D.register("anim_rfx_open", "client", function(args)
    loadReloadsFromCache()
    local key = args and (args.animId or args.nodeFile)
    local groups = rfxGroupedReloads()
    local reload
    if key then
        for i = 1, #groups do
            local g = groups[i]
            if g.animId == key then reload = g; break end
            for j = 1, #g.stages do if g.stages[j].nodeFile == key then reload = g; break end end
            if reload then break end
        end
    end
    reload = reload or groups[1]
    if not reload then return { error = "no reload found; run 'pz-anim-forge scan' first" } end
    if not openReloadFx(reload) then return { error = "could not open (Gunworks missing / no gun / no attach location)" } end
    return { ok = true, animId = AE.rfx.animId, clip = AE.rfx.clip,
             stages = (AE.rfx.group and #AE.rfx.group.stages) or 1, stageIndex = AE.rfx.stageIndex,
             markers = AE.rfx.markers }
end)

-- Switch the open editor to another stage of the grouped reload (Load/LoadShort/Rack/Unload), exactly
-- as picking from the stage combo does. Verifies the per-stage load/preview path.
D.register("anim_rfx_switch_stage", "client", function(args)
    local w = AE.rfx and AE.rfx.window
    if not w or not w.switchStage then return { error = "reload editor window not open" } end
    local idx = args and args.index
    if not idx then return { error = "index (1-based stage) required" } end
    w:switchStage(idx)
    return { ok = true, stageIndex = AE.rfx.stageIndex, clip = AE.rfx.clip, nodeFile = AE.rfx.nodeFile }
end)

-- Save the deltas as a SET (separate renamed animations into a mod). Mirrors the
-- "Save Set" button; namePrefix/mod default to the editor's current values.
D.register("anim_editor_save_set", "client", function(args)
    if args.namePrefix then AE.namePrefix = args.namePrefix end
    if args.mod then AE.mod = args.mod end
    if args.tag then AE.tag = args.tag end
    if args.clips then AE.clips = args.clips end
    saveJson(true)
    if AE.panel and AE.panel.nameEntry then
        AE.panel.nameEntry:setText(AE.namePrefix)
        AE.panel.modEntry:setText(AE.mod)
        if AE.panel.tagEntry then AE.panel.tagEntry:setText(AE.tag) end
    end
    return { saved = true, set = { clips = AE.clips, namePrefix = AE.namePrefix, mod = AE.mod, tag = AE.tag } }
end)

-- ----------------------------------------------------- Gunworks reload cmds --
-- Drive a Gunworks-reload project headlessly (the visual panel calls the same GW.* API).
-- start -> seed stages from an archetype; stage -> edit/configure one stage (load its
-- clip); config -> set the RegisterWeapon fields; save -> write the gunworks block to
-- anim_edit.json + persist the project; state -> report.

-- Start a Gunworks-reload project for an archetype (seeds the stage list + base clips).
D.register("anim_editor_gw_start", "client", function(args)
    if not args.archetypeKey then return { error = "archetypeKey required" } end
    if not GW.seedArchetype(args.archetypeKey) then
        return { error = "unknown archetype: " .. tostring(args.archetypeKey) }
    end
    return { ok = true, archetype = AE.gw.archetype, order = AE.gw.order, activeStage = AE.gw.activeStage }
end)

-- Edit / configure one reload stage. With load=true, loads its base clip into the editor.
D.register("anim_editor_gw_stage", "client", function(args)
    local key = args.stage
    if not key then return { error = "stage required" } end
    local stage = AE.gw.stages[key]
    if not stage then return { error = "no such stage: " .. tostring(key) } end
    if args.baseClip then stage.baseClip = args.baseClip end
    if args.duration ~= nil then stage.duration = args.duration end
    if args.blendTime ~= nil then stage.blendTime = args.blendTime end
    if args.done ~= nil then stage.done = args.done and true or false end
    if args.load then GW.loadStage(key) end
    return { ok = true, stage = key, baseClip = stage.baseClip, active = AE.gw.activeStage }
end)

-- Set the RegisterWeapon config fields (only provided keys are changed).
D.register("anim_editor_gw_config", "client", function(args)
    local cfg = AE.gw.config
    local keys = { "animId", "fullTypes", "style", "propItem", "spriteLoaded", "spriteUnloaded", "build", "luaNamespace", "mod" }
    for i = 1, #keys do
        if args[keys[i]] ~= nil then cfg[keys[i]] = args[keys[i]] end
    end
    if args.shortRackAfterInsert ~= nil then cfg.shortRackAfterInsert = args.shortRackAfterInsert and true or false end
    return { ok = true, config = cfg }
end)

-- Save the gunworks block to anim_edit.json + persist the project. `name` optional.
D.register("anim_editor_gw_save", "client", function(args)
    GW.captureActiveStage()
    GW.saveJson()
    local block = GW.buildBlock()
    local name = args.name
    if not name or name == "" then name = (AE.gw.config.animId ~= "" and AE.gw.config.animId) or "gunworks" end
    local slug = AP.save(GW.buildProject(name))
    AE.project = { name = name, slug = slug, weapon = AE.gw.archetypeKey, type = "gunworks" }
    return { saved = true, slug = slug, gunworks = block }
end)

-- Report the live gunworks edit state (for the panel / tests).
D.register("anim_editor_gw_state", "client", function(args)
    local stages = {}
    local order = AE.gw.order or {}
    for i = 1, #order do
        local key = order[i]
        local s = AE.gw.stages[key]
        if s then
            local edited = false
            for _ in pairs(s.deltas or {}) do edited = true; break end
            stages[#stages + 1] = { stage = key, baseClip = s.baseClip, edited = edited, done = s.done == true, duration = s.duration }
        end
    end
    return { archetypeKey = AE.gw.archetypeKey, archetype = AE.gw.archetype, activeStage = AE.gw.activeStage, config = AE.gw.config, stages = stages }
end)

-- Report the current projected bone-node screen positions + the selected bone's
-- gizmo. Lets automation verify projection alignment numerically (no screenshot
-- guesswork) and confirm the overlay is live.
D.register("anim_editor_nodes", "client", function(args)
    if not AE.overlay then return { error = "overlay not open" } end
    AE.overlay:refresh()
    local screenW, screenH = getCore():getScreenWidth(), getCore():getScreenHeight()
    local out = {}
    for _, n in ipairs(AE.overlay.nodes) do
        out[#out + 1] = { bone = n.name, x = n.sx, y = n.sy }
    end
    local giz = nil
    if AE.overlay.gizmo then
        local gz = AE.overlay.gizmo
        giz = { ox = gz.ox, oy = gz.oy,
            x = { gz.tips[1].x, gz.tips[1].y },
            y = { gz.tips[2].x, gz.tips[2].y },
            z = { gz.tips[3].x, gz.tips[3].y } }
    end
    return { ok = true, screen = { w = screenW, h = screenH }, selected = AE.bone, nodes = out, gizmo = giz }
end)

-- Select a bone by name (mirrors clicking its node), so automation can pose it.
D.register("anim_editor_pick_bone", "client", function(args)
    if not args.bone then return { error = "bone required" } end
    AE.bone = args.bone
    if AE.panel then
        AE.panel.boneCombo:select(AE.bone)
        AE.panel:syncSliders()
        AE.panel.status:setName("bone: " .. AE.bone)
    end
    return { ok = true, bone = AE.bone }
end)

-- Tune the overlay/gizmo live: showNodes, gizmoMode ("rot"/"pos"), axisLen, posSens.
D.register("anim_editor_gizmo", "client", function(args)
    if args.showNodes ~= nil then AE.showNodes = args.showNodes == true end
    if args.gizmoMode then AE.gizmoMode = args.gizmoMode end
    if args.axisLen then AE.axisLen = args.axisLen end
    if args.posSens then AE.posSens = args.posSens end
    if args.thick then AE.gizmoThick = args.thick end
    if args.alpha then AE.gizmoAlpha = args.alpha end
    if AE.panel then
        if AE.panel.gizmoBtn then
            AE.panel.gizmoBtn:setTitle("Gizmo: " .. (AE.gizmoMode == "rot" and "Rotate" or "Translate"))
        end
        if AE.panel.thickSlider then AE.panel.thickSlider:setCurrentValue(AE.gizmoThick, true) end
        if AE.panel.alphaSlider then AE.panel.alphaSlider:setCurrentValue(AE.gizmoAlpha, true) end
    end
    return { ok = true, showNodes = AE.showNodes, gizmoMode = AE.gizmoMode, axisLen = AE.axisLen,
        posSens = AE.posSens, thick = AE.gizmoThick, alpha = AE.gizmoAlpha }
end)

-- Exercise the gizmo drag through the REAL overlay handlers (onMouseDown -> N x
-- onMouseMove -> onMouseUp), for automated verification when a physical mouse
-- drag can't be synthesized. Grabs the selected bone's `axis` handle and drags
-- by (dx,dy) px per step.
D.register("anim_editor_drag", "client", function(args)
    local ov = AE.overlay
    if not ov then return { error = "overlay not open" } end
    ov:refresh()
    if not ov.gizmo then return { error = "no gizmo (select a bone first)" } end
    local axis = args.axis or 1
    AE.gizmoMode = args.kind or AE.gizmoMode
    local dx, dy, steps = args.dx or 0, args.dy or 0, args.steps or 10
    local d0 = ensureDelta(AE.bone)
    local before = { rot = { d0.rot[1], d0.rot[2], d0.rot[3] }, pos = { d0.pos[1], d0.pos[2], d0.pos[3] } }
    -- grab point: a ring point (rot) or the axis tip (pos), matching onMouseDown's picker
    local sx, sy
    if AE.gizmoMode == "rot" and ov.gizmo.rings then
        -- grab a mid-arc point (t~45deg), clear of the axis-tip ring intersections
        local ring = ov.gizmo.rings[axis]; local rp = ring[math.floor(#ring / 8) + 1]
        sx, sy = rp.x, rp.y
    else
        local t = ov.gizmo.tips[axis]; sx, sy = t.x, t.y
    end
    ov:onMouseDown(sx, sy)
    for _ = 1, steps do ov:onMouseMove(dx, dy) end
    ov:onMouseUp(sx, sy)
    local d1 = ensureDelta(AE.bone)
    return { ok = true, bone = AE.bone, axis = axis, kind = AE.gizmoMode,
        before = before, after = { rot = { d1.rot[1], d1.rot[2], d1.rot[3] }, pos = { d1.pos[1], d1.pos[2], d1.pos[3] } } }
end)

-- ------------------------------------------------------- clip transport ----
-- Resume playback (the forced clip advances + loops).
D.register("anim_editor_play", "client", function(args)
    AE.playing = true
    setClipPaused(false)
    if AE.panel and AE.panel.playBtn then AE.panel.playBtn:setTitle("Pause") end
    return { ok = true, playing = true, time = getClipTime(), length = getClipLen() }
end)

-- Pause playback (the pose holds at the current time).
D.register("anim_editor_pause", "client", function(args)
    AE.playing = false
    setClipPaused(true)
    if AE.panel and AE.panel.playBtn then AE.panel.playBtn:setTitle("Play") end
    return { ok = true, playing = false, time = getClipTime(), length = getClipLen() }
end)

-- Seek the forced clip. Pass normalized `t` (0..1) or absolute `seconds`. Pauses.
D.register("anim_editor_scrub", "client", function(args)
    AE.playing = false
    setClipPaused(true)
    local len = getClipLen()
    local t = args.seconds or ((args.t or 0) * len)
    setClipTime(t)
    if AE.panel then
        if AE.panel.playBtn then AE.panel.playBtn:setTitle("Play") end
        if AE.panel.scrub and len > 0 then AE.panel.scrub:setCurrentValue(t / len, true) end
        if AE.panel.updateTimeLabel then AE.panel:updateTimeLabel(t, len) end
    end
    return { ok = true, playing = false, time = getClipTime(), length = len }
end)

-- ----------------------------------------------------------- keyframes ----
-- List the keyframes for a clip+bone (defaults to current). For automation/verify.
D.register("anim_editor_keyframes", "client", function(args)
    local clip = args.clip or AE.clip
    local bone = args.bone or AE.bone
    local byClip = AE.keyframes[clip]
    local list = byClip and byClip[bone]
    local out = {}
    if list then
        for i, kf in ipairs(list) do
            out[i] = { t = kf.t, rot = { kf.rot[1], kf.rot[2], kf.rot[3] }, pos = { kf.pos[1], kf.pos[2], kf.pos[3] } }
        end
    end
    return { ok = true, clip = clip, bone = bone, count = #out, keyframes = out,
        time = getClipTime(), length = getClipLen() }
end)

-- Clear keyframes for a bone (or the whole clip if no bone given).
D.register("anim_editor_clear_keyframes", "client", function(args)
    local clip = args.clip or AE.clip
    local byClip = AE.keyframes[clip]
    if byClip then
        if args.bone then byClip[args.bone] = nil else AE.keyframes[clip] = nil end
    end
    return { ok = true, clip = clip, bone = args.bone or "(all)" }
end)

-- Move the keyframe nearest `from` (seconds) to `to` (seconds). Mirrors dragging a tick.
D.register("anim_editor_move_keyframe", "client", function(args)
    local bone = args.bone or AE.bone
    local byClip = AE.keyframes[AE.clip]
    local list = byClip and byClip[bone]
    if not list then return { error = "no keyframes for " .. bone } end
    local from = args.from or 0
    local best, bestKf = 1e9, nil
    for _, kf in ipairs(list) do
        local d = math.abs(kf.t - from)
        if d < best then best, bestKf = d, kf end
    end
    if not bestKf then return { error = "no keyframe near " .. from } end
    bestKf.t = math.max(0, args.to or from)
    table.sort(list, function(a, b) return a.t < b.t end)
    -- seek to the moved keyframe (mirrors the live drag, so the scrub handle follows it)
    AE.playing = false; setClipPaused(true); setClipTime(bestKf.t)
    if AE.panel and AE.panel.playBtn then AE.panel.playBtn:setTitle("Play") end
    return { ok = true, bone = bone, movedTo = bestKf.t, count = #list }
end)

-- Delete the keyframe nearest `t` (seconds, defaults to current time). Mirrors right-click.
D.register("anim_editor_delete_keyframe", "client", function(args)
    local bone = args.bone or AE.bone
    local byClip = AE.keyframes[AE.clip]
    local list = byClip and byClip[bone]
    if not list then return { error = "no keyframes for " .. bone } end
    local t = args.t or getClipTime()
    local bestI, best = nil, 1e9
    for i, kf in ipairs(list) do
        local d = math.abs(kf.t - t)
        if d < best then best, bestI = d, i end
    end
    if bestI then table.remove(list, bestI) end
    if #list == 0 then byClip[bone] = nil end
    return { ok = true, bone = bone, count = #list }
end)

-- --------------------------------------------------------- browser bridge ---
local function browserState()
    local b = AE.browser
    if not b then return { open = false } end
    return {
        open = true, tab = b.tab, useAll = b.useAll, search = b.search,
        count = #b.clips, cols = b.cols, rows = b.rows,
        scrollRow = b.scrollRow, totalRows = b:totalRows(),
        shown = b.shownCount, visible = b:visibleClips(),
    }
end

D.register("anim_browser_open", "client", function(args)
    openBrowser(args.x, args.y)
    if args.tab then AE.browser.tab = args.tab end
    if args.all ~= nil then AE.browser.useAll = args.all == true end
    if args.search then AE.browser.search = args.search; AE.browser.searchEntry:setText(args.search) end
    AE.browser:refilter()
    return browserState()
end)

D.register("anim_browser_close", "client", function(args)
    closeBrowser()
    return { closed = true }
end)

D.register("anim_browser_set", "client", function(args)
    local b = AE.browser
    if not b then return { error = "browser not open" } end
    if args.tab then b.tab = args.tab end
    if args.all ~= nil then b.useAll = args.all == true; b.allTick:setSelected(1, b.useAll) end
    if args.search ~= nil then b.search = args.search; b.searchEntry:setText(args.search) end
    if args.scrollRow ~= nil then b.scrollRow = args.scrollRow end
    b:refilter()
    return browserState()
end)

D.register("anim_browser_scroll", "client", function(args)
    local b = AE.browser
    if not b then return { error = "browser not open" } end
    if args.row ~= nil then b.scrollRow = args.row
    else b.scrollRow = b.scrollRow + (args.delta or 1) end
    b:clampScroll(); b:relayout()
    return browserState()
end)

D.register("anim_browser_pick", "client", function(args)
    local b = AE.browser
    if not b then return { error = "browser not open" } end
    local clip = args.clip
    if not clip and args.index then clip = b.clips[args.index] end
    if not clip then return { error = "no clip (pass clip= or index=)" } end
    b:pick(clip)
    return { ok = true, clip = clip }
end)

D.register("anim_browser_state", "client", function(args)
    return browserState()
end)

-- Tune thumbnail framing live (zoom + facing) without a rebuild.
D.register("anim_browser_config", "client", function(args)
    local b = AE.browser
    if not b then return { error = "browser not open" } end
    if args.zoom ~= nil then b.zoom = args.zoom; AE.browserZoom = args.zoom end
    local dir = nil
    if args.direction then pcall(function() dir = IsoDirections.valueOf(args.direction) end) end
    for _, t in ipairs(b.pool) do
        if t.javaObject and t.bodySet then
            if args.zoom ~= nil then t.javaObject:setZoom(args.zoom) end
            if dir then t.javaObject:setDirection(dir) end
        end
    end
    return { ok = true, zoom = b.zoom, direction = args.direction }
end)

-- ------------------------------------------------------------- projects ---
-- Active-project state (progress + per-clip done/edited bone-count) for replies.
---@return table
local function projectStateTable()
    local done, edited, total = projectProgress()
    local clips, list = {}, AE.clips or {}
    for i = 1, #list do
        local clip = list[i]
        local kf = AE.keyframes[clip]
        local bones = 0
        if kf then
            for _ in pairs(kf) do bones = bones + 1 end
        end
        clips[i] = { clip = clip, done = AE.done[clip] == true, bones = bones }
    end
    local proj = nil
    if AE.project then
        proj = {
            name = AE.project.name, slug = AE.project.slug, weapon = AE.project.weapon,
            namePrefix = AE.namePrefix, mod = AE.mod, tag = AE.tag, useAll = AE.useAll == true,
        }
    end
    return {
        active = AE.project ~= nil, project = proj,
        progress = { done = done, edited = edited, total = total }, clips = clips,
    }
end

-- Land the editor panel + browser on the active project after a New/Load switch.
local function afterProjectSwitch()
    local panel = AE.panel
    if panel then
        if panel.nameEntry then panel.nameEntry:setText(AE.namePrefix or "") end
        if panel.modEntry then panel.modEntry:setText(AE.mod or "") end
        if panel.tagEntry then panel.tagEntry:setText(AE.tag or "") end
        if panel.applyLoadedClip then panel:applyLoadedClip() end
    end
    local b = AE.browser
    if b then
        if AE.weapon then b.tab = AE.weapon end
        b.useAll = AE.useAll == true
        if b.allTick then b.allTick:setSelected(1, b.useAll) end
        b.scrollRow = 0
        b:refilter()
    end
end

-- Start a new project for a weapon category (prefix/mod/tag/all optional).
D.register("anim_project_new", "client", function(args)
    local weapon = args.weapon or AE.weapon
    local prefix = args.prefix or args.name or AE.namePrefix
    local name = args.name or prefix
    if not newProject(name, weapon, prefix, args.mod or AE.mod, args.tag or AE.tag, args.all == true) then
        return { error = "unknown weapon: " .. tostring(weapon) }
    end
    afterProjectSwitch()
    return projectStateTable()
end)

-- Load a saved project by slug (or name, slugified) into the editor.
D.register("anim_project_load", "client", function(args)
    local slug = args.slug
    if not slug and args.name then slug = AnimForge.AnimProjects.slugify(args.name) end
    if not slug then return { error = "slug or name required" } end
    if not loadProject(slug) then return { error = "project not found: " .. tostring(slug) } end
    afterProjectSwitch()
    return projectStateTable()
end)

-- Persist the active project to disk.
D.register("anim_project_save", "client", function(args)
    local slug = saveProject()
    if not slug then return { error = "no active project" } end
    return { ok = true, slug = slug }
end)

-- List saved projects (summaries only).
D.register("anim_project_list", "client", function(args)
    return { ok = true, projects = AnimForge.AnimProjects.list() }
end)

-- Report the active project's full state (progress + per-clip done/edited).
D.register("anim_project_state", "client", function(args)
    return projectStateTable()
end)

-- Toggle/set a clip's done flag (defaults to the current clip; flips if no done given).
D.register("anim_project_mark", "client", function(args)
    if not AE.project then return { error = "no active project" } end
    local clip = args.clip or AE.clip
    local done = args.done
    if done == nil then done = not (AE.done[clip] == true) end
    setClipDone(clip, done == true)
    if AE.panel then AE.panel:refreshDoneBtn() end
    if AE.browser then AE.browser:relayout() end
    return projectStateTable()
end)

-- Remove a saved project (by slug) from the index.
D.register("anim_project_delete", "client", function(args)
    local slug = args.slug
    if not slug and args.name then slug = AnimForge.AnimProjects.slugify(args.name) end
    if not slug then return { error = "slug or name required" } end
    local removed = AnimForge.AnimProjects.delete(slug)
    if AE.project and AE.project.slug == slug then AE.project = nil end
    return { ok = removed, slug = slug }
end)

-- ---------------------------------------------- Anim Forge hub bridge ----
-- Drive the new hub headlessly (for automated UI tests): report state, switch
-- mode, and export an emote without clicking. The pose/project/gw headless ops
-- above still target the same underlying state (AE.panel + AE.gw + projects).

-- Report whether the hub is open + its current mode.
D.register("anim_forge_state", "client", function(args)
    if not AE.hub then return { open = false } end
    return { open = true, mode = AE.hub.mode, reloadEditing = AE.hub.reloadEditing,
        poseTab = AE.panel and AE.panel.activeTab, timelinePopped = AE.timelineWin ~= nil }
end)

-- Switch the pose editor's tab (pose | gizmo) -- deterministic test hook for the tab UI.
D.register("anim_pose_tab", "client", function(args)
    if not AE.panel then return { error = "editor not open" } end
    AE.panel:showTab(args.tab or "pose")
    return { ok = true, tab = AE.panel.activeTab }
end)

-- Pop the timeline out / dock it back -- deterministic test hook.
D.register("anim_timeline_pop", "client", function(args)
    if not AE.panel then return { error = "editor not open" } end
    if args.pop == false then
        if AE.timelineWin then AE.panel:dockTimeline() end
    else
        if not AE.timelineWin then AE.panel:popOutTimeline() end
    end
    return { ok = true, popped = AE.timelineWin ~= nil }
end)

-- Switch the hub to a mode (home / grip / reload / emote / open / duplicate / override / resume).
D.register("anim_forge_mode", "client", function(args)
    if not AE.hub then return { error = "hub not open (open_anim_editor first)" } end
    if not args.mode then return { error = "mode required" } end
    if args.mode == "resume" then AE.hub:doResume() else AE.hub:switchMode(args.mode) end
    return { ok = true, mode = AE.hub.mode }
end)

-- Minimize/restore a panel to just its title bar (same as clicking the title-bar "-"), so the
-- character stays visible while editing. target: "hub" (default) or "rfx" (Reload Attachments).
D.register("anim_forge_collapse", "client", function(args)
    local target = (args and args.target) or "hub"
    local win = (target == "rfx") and AE.rfx and AE.rfx.window or AE.hub
    if not win or not win.setCollapsed then return { error = target .. " window not open" } end
    local c = (args and args.collapsed)
    if c == nil then c = not win.uiCollapsed end
    win:setCollapsed(c and true or false)
    return { ok = true, target = target, collapsed = win.uiCollapsed }
end)

-- Headless emote export: write the emote block to anim_edit.json from the current
-- pose (AE.deltas on the base clip), so 'pz-anim-forge wire-emote' can build it.
-- Mirrors the hub's "Export emote" button.
D.register("anim_emote_export", "client", function(args)
    local name = args.name or AE.emoteName
    local base = args.baseClip or AE.emoteBase or AE.clip
    local mod = args.mod or AE.mod
    if not name or name == "" then return { error = "name required" } end
    if not mod or mod == "" then return { error = "mod required" } end
    AE.emoteName, AE.emoteBase, AE.mod = name, base, mod
    local data = {
        order = AE.order, mode = AE.mode, clip = base, deltas = AE.deltas,
        emote = { name = name, baseClip = base, mod = mod, build = args.build or "42.13" },
    }
    local writer = getFileWriter("AnimForge/anim_edit.json", true, false)
    writer:write(AnimForge.JSON.encode(data)); writer:close()
    return { saved = true, emote = data.emote }
end)
