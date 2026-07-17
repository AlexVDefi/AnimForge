-- Anim Forge editor: shared state + logic core.
-- Holds AE (the editor state, ResetLua-safe on disk), the forced-clip transport, the
-- keyframe timeline, the reload-preview logic, and the project glue. Every other editor
-- file requires this and re-localizes what it needs from AnimForge.EditCore.

require "AnimForge/JSON"
require "AnimForge/AnimCategories"
require "AnimForge/AnimProjects"

AnimForge = AnimForge or {}

-- Optional automation surface. Anim Forge is driven entirely through its own UI (the "Toggle Anim
-- Forge" keybind, default HOME); this just records the editor's named headless ops in AnimForge.ops.
-- An external driver may set AnimForge.opHook to receive each op as it registers, and/or replay
-- AnimForge.ops for any registered before it hooked in. Standalone nothing consumes them; nothing
-- here requires or assumes any other mod.
AnimForge.ops = {}
function AnimForge.registerOp(op, side, fn)
    AnimForge.ops[op] = { name = op, side = side, fn = fn }
    if AnimForge.opHook then AnimForge.opHook(op, side, fn) end
end

AnimForge.AnimEdit = AnimForge.AnimEdit or {
    clip = "Bob_IdleHandgun",
    order = "XYZ",
    mode = "post",
    bone = "Bip01_R_UpperArm",
    deltas = {},   -- boneName -> { rot = {ex,ey,ez}, pos = {tx,ty,tz} }
    namePrefix = "MyGun",  -- output animations are named <prefix>_<clip>
    mod = "",              -- target mod dir name for Save Set
    tag = "",              -- item tag wire-set gates on (blank = <prefixlower>anims)
    weapon = "Handgun",    -- current weapon category
    useAll = false,        -- grip set (false) vs every matching clip (true)
    panel = nil,
    overlay = nil,         -- bone-node / gizmo overlay (full-screen ISUIElement)
    showNodes = true,      -- draw the clickable bone nodes over the character
    gizmoMode = "rot",     -- "rot" (rotate handles) or "pos" (translate handles)
    axisLen = 0.16,        -- gizmo axis/ring radius in model units (tuned in-game)
    posSens = 0.0015,      -- translation drag sensitivity (model units / screen px)
    gizmoThick = 6,        -- gizmo line thickness (px), slider-controlled
    gizmoAlpha = 1.0,      -- gizmo opacity (0..1), slider-controlled
    playing = false,       -- forced clip paused/held (false) vs playing (true); held by default so the scrub doesn't loop
    keyframes = {},        -- [clip][bone] = sorted list of { t, rot={x,y,z}, pos={x,y,z} }
    project = nil,         -- active project metadata { name, slug, weapon } (full data lives on disk + in keyframes/done)
    done = {},             -- [clip] = true: clips the user has signed off in the active project
}
local AE = AnimForge.AnimEdit

-- Reload-safe defaults: the table above persists across Lua reloads (the `or {...}`
-- only initialises once), so fields added to the literal must be backfilled here.
AE.keyframes = AE.keyframes or {}
if AE.playing == nil then AE.playing = false end
AE.gizmoMode = AE.gizmoMode or "rot"
AE.axisLen = AE.axisLen or 0.16
AE.posSens = AE.posSens or 0.0015
AE.gizmoThick = AE.gizmoThick or 6
AE.gizmoAlpha = AE.gizmoAlpha or 1.0
if AE.showNodes == nil then AE.showNodes = true end
if AE.poseActive == nil then AE.poseActive = true end   -- hub sets this false on non-posing screens
AE.done = AE.done or {}
AE.browser = nil   -- a Lua reload destroys the window; drop the stale handle

-- Mod animation clips discovered by 'pz-anim-forge scan' (cached to disk) and settable via the
-- anim_mod_clips_set headless op. modClips is keyed by the force-play name (the filename stem,
-- e.g. Bob_MusketReload); modClipNames is the ordered list the "Mods" browser tab shows.
AE.modClips = AE.modClips or {}
AE.modClipNames = AE.modClipNames or {}
AE.glbDst = AE.glbDst or ""   -- "" = save the mod .glb in place; else an absolute new-file path

-- Populate the "Mods" browser tab from a discovered clip list ({mod,stem,name,format,srcPath,...}),
-- keyed by stem (the force-play name).
local function applyModClips(clips)
    AE.modClips = {}
    AE.modClipNames = {}
    clips = clips or {}
    for i = 1, #clips do
        local c = clips[i]
        if c and c.stem and c.srcPath then
            AE.modClips[c.stem] = c
            AE.modClipNames[#AE.modClipNames + 1] = c.stem
        end
    end
end

-- Reload attachment-marker editor state ("Edit reload attachments"). A loaded reload = one mod
-- AnimSet node: its clip (force-played for the timeline), the editable gw markers, and the item
-- whitelist for the picker. snapshot = the gun's pre-preview parts + prop, restored on exit.
AE.rfx = AE.rfx or {
    reloads = {},        -- discovered reloads (from reload_markers.json) for the picker
    partsByGun = {},     -- gun fullType -> PartType -> {part fullTypes} (gwSetPart location/part dropdowns)
    nodeFile = nil, clip = nil, animId = nil, mod = nil,
    group = nil,         -- the grouped reload being edited (multi-stage); nil for a bare single node
    stageIndex = nil,    -- 1-based index into group.stages of the stage currently loaded/focused
    combined = false,    -- "Combined timeline" mode: all stages laid end to end on one marker bar
    loadVariant = "load",-- which load stage the combined bar shows in its middle slot: "load" | "loadshort"
    markers = {},        -- editable gw markers: { {event, timePc, value}, ... }
    propItems = {},      -- item fullTypes the item dropdown offers
    marker = nil,        -- currently selected marker (for the bar / add controls)
    gunId = nil,         -- the auto-equipped preview gun
    snapshot = nil,      -- { parts = {fullType...}, prop = fullType|"" } for restore
    active = false,      -- preview session live (reconciler suppressed)
    lastFrac = -1,       -- last previewed fraction (avoid redundant re-apply)
}

-- Lazily reach the Gunworks reload runtime (only present when the SWMG mod is loaded). Requiring at
-- file scope would break the editor for users without Gunworks, so resolve on first use - by then a
-- reload has been picked, which implies Gunworks is active.
local _reloadAnim = nil
local function getReloadAnim()
    if _reloadAnim == nil then
        if getActivatedMods() and getActivatedMods():contains("SWMG") then
            _reloadAnim = require("WeaponSystems/Utils/ReloadAnim")
            require("WeaponSystems/ReloadAnim/Visuals")
            require("WeaponSystems/ReloadAnim/Props")
            require("WeaponSystems/ReloadAnim/PartState")
        else
            _reloadAnim = false
        end
    end
    return _reloadAnim or nil
end

-- Load the mod-clip list that 'pz-anim-forge scan' cached to disk, so the "Mods" tab is
-- populated without a manual push. Safe to call whenever the editor/browser opens.
local function loadModClipsFromCache()
    local reader = getFileReader("AnimForge/mod_clips.json", false)
    if not reader then return end
    local parts = {}
    local line = reader:readLine()
    while line do
        parts[#parts + 1] = line
        line = reader:readLine()
    end
    reader:close()
    if #parts == 0 then return end
    local content = table.concat(parts, "\n")
    if content == "" or content == "null" then return end
    local data = AnimForge.JSON.decode(content)
    if data and data.clips then applyModClips(data.clips) end
end

---@param path string
---@nodiscard
---@return table|nil
local function readJsonFile(path)
    local reader = getFileReader(path, false)
    if not reader then return nil end
    local parts = {}
    local line = reader:readLine()
    while line do
        parts[#parts + 1] = line
        line = reader:readLine()
    end
    reader:close()
    if #parts == 0 then return nil end
    local content = table.concat(parts, "\n")
    if content == "" or content == "null" then return nil end
    return AnimForge.JSON.decode(content)
end

-- Load the reload list that 'pz-anim-forge scan' cached, for the "Edit reload attachments" picker.
local function loadReloadsFromCache()
    local data = readJsonFile("AnimForge/reload_markers.json")
    AE.rfx.reloads = (data and data.reloads) or AE.rfx.reloads or {}
    AE.rfx.partsByGun = (data and data.partsByGun) or AE.rfx.partsByGun or {}
    return AE.rfx.reloads
end

-- A reload is worth showing in "Edit reload attachments" only if it actually has something to edit:
-- existing attachment markers, or a prop whitelist (partState) to add them from. The scan also turns
-- up plain animation-only reloads (e.g. AnimatedReloads' Bren/M249/Sten) that have neither - those
-- would otherwise fill the short row list and push a real one (the Musket) off the end.
local function rfxIsEditable(r)
    return r ~= nil and ((r.markers and #r.markers > 0) or (r.propItems and #r.propItems > 0))
end

-- Set of mods enabled on this save (lowercased ids). The scan cache (reload_markers.json) is built
-- from every mod installed on disk, so it also carries reloads from mods that are installed but NOT
-- enabled here (e.g. Gunsmithing's muskets when only N-A-Guns is active). We gate the picker to the
-- active set so only reloads you can actually use show up.
local function activeModSet()
    local set = {}
    local am = getActivatedMods()
    if am then
        for i = 0, am:size() - 1 do set[(am:get(i):gsub("^\\", "")):lower()] = true end
    end
    return set
end

-- The owning mod folder id for a cached reload, from its baked node path (".../mods/<ModId>/.../X.xml").
-- nil when the path has no mods/ segment (a base-game node) -- those stay visible.
local function reloadModId(r)
    local nf = r and r.nodeFile
    return nf and nf:match("[/\\][Mm]ods[/\\]([^/\\]+)[/\\]") or nil
end

-- Reloads whose owning mod is enabled right now (plus any non-mod nodes). This is the picker's
-- visibility gate; AE.rfx.reloads itself is left whole so a marker Save still writes every mod's
-- entries back to the shared cache (filtering the cache would erase disabled mods' entries on disk).
local function rfxActiveReloads()
    local all = AE.rfx.reloads or {}
    local active = activeModSet()
    local out = {}
    for i = 1, #all do
        local mid = reloadModId(all[i])
        if (not mid) or active[mid:lower()] then out[#out + 1] = all[i] end
    end
    return out
end

-- The reloads to present, editable ones first (stable within each group). Falls back to the active
-- list (never the disabled-mod entries) if nothing is editable, so the picker only ever shows what
-- belongs to the current mod set.
local function rfxEditableReloads()
    local all = rfxActiveReloads()
    local editable = {}
    for i = 1, #all do
        if rfxIsEditable(all[i]) then editable[#editable + 1] = all[i] end
    end
    return #editable > 0 and editable or all
end

-- Stage order for the per-stage switcher: the reload cycle (unload, then the load variants, then rack).
local RFX_STAGE_ORDER = { unload = 1, load = 2, loadshort = 3, rack = 4 }

-- Stage label for a reload node, from its file name "<animId>_<Stage>.xml" (falls back to the clip
-- tail). Multi-stage gunworks reloads share one animId across Load/LoadShort/Rack/Unload nodes.
local function rfxStageLabel(r)
    local nf = (r and r.nodeFile) or ""
    local base = nf:match("([^/\\]+)%.xml$") or ""
    local stage = base:match("_([^_]+)$")
    if stage and stage ~= "" then return stage end
    local clip = (r and r.clip) or ""
    return clip:match("_([^_]+)$") or "stage"
end

-- Group the visible reloads by (mod, animId) so a multi-stage gunworks reload is ONE picker row that
-- carries its stages (Load/LoadShort/Rack/Unload), each still its own editable node; single-node
-- reloads (e.g. the muskets) become one-stage groups. Each group: { mod, animId, propItems, stages,
-- markerCount }. Groups with something to edit (markers or a prop whitelist) sort first.
local function rfxGroupedReloads()
    local all = rfxActiveReloads()
    local byKey, order = {}, {}
    for i = 1, #all do
        local r = all[i]
        local key = (r.mod or "") .. "\0" .. (r.animId or "")
        local g = byKey[key]
        if not g then
            g = { mod = r.mod, animId = r.animId, propItems = r.propItems or {}, stages = {}, markerCount = 0 }
            byKey[key] = g
            order[#order + 1] = g
        end
        r.stage = rfxStageLabel(r)
        g.stages[#g.stages + 1] = r
        g.markerCount = g.markerCount + ((r.markers and #r.markers) or 0)
        if (#g.propItems == 0) and r.propItems and #r.propItems > 0 then g.propItems = r.propItems end
    end
    for i = 1, #order do
        table.sort(order[i].stages, function(a, b)
            local oa = RFX_STAGE_ORDER[(a.stage or ""):lower()] or 99
            local ob = RFX_STAGE_ORDER[(b.stage or ""):lower()] or 99
            if oa ~= ob then return oa < ob end
            return (a.stage or "") < (b.stage or "")
        end)
    end
    local editable, plain = {}, {}
    for i = 1, #order do
        local g = order[i]
        if g.markerCount > 0 or #g.propItems > 0 then editable[#editable + 1] = g else plain[#plain + 1] = g end
    end
    for i = 1, #plain do editable[#editable + 1] = plain[i] end
    return editable
end

-- First reload worth editing (for headless defaults when no animId/nodeFile is given).
local function rfxFirstEditable()
    local list = rfxEditableReloads()
    return list[1]
end

-- Force-hold `clip` on the live player (nil clears).
local function forceClip(clip)
    local p = getPlayer(); if not p then return false end
    local ap = p:getAnimationPlayer(); if not ap then return false end
    return pcall(function()
        ap:setForcedEditClip(clip)
        ap:setForcedEditClipReversed(false)   -- forward by default; the reload unload stage re-sets true
    end)
end

-- ---- clip transport (play/pause + scrub), via the patched AnimationPlayer ----
local function animPlayer()
    local p = getPlayer(); if not p then return nil end
    return p:getAnimationPlayer()
end
local function setClipPaused(paused)
    local ap = animPlayer(); if not ap then return end
    pcall(function() ap:setForcedEditClipPaused(paused and true or false) end)
end
local function setClipTime(seconds)
    local ap = animPlayer(); if not ap then return end
    pcall(function() ap:setForcedEditClipTime(seconds) end)
end
local function getClipTime()
    local ap = animPlayer(); if not ap then return 0 end
    local t = 0
    pcall(function() t = ap:getForcedEditClipTime() end)
    return t or 0
end
local function getClipLen()
    local ap = animPlayer(); if not ap then return 0 end
    local l = 0
    pcall(function() l = ap:getForcedEditClipLength() end)
    return l or 0
end

---@nodiscard
---@return number
local function markerFrac()
    local len = getClipLen()
    if len <= 0 then return 0 end
    local f = getClipTime() / len
    if f < 0 then return 0 elseif f > 1 then return 1 end
    return f
end

-- ---- combined multi-stage timeline -------------------------------------------------------------
-- The "Combined timeline" mode lays a grouped reload's stages end to end as EQUAL segments (so each
-- clip gets full editing width) and scrubs the whole reload cycle on one bar. The cycle order is
-- Unload -> the chosen Load variant -> Rack: a reload plays EITHER the full Load or the Short load,
-- never both, so only the selected one appears on the combined bar (the other stays editable via the
-- per-stage switcher). These helpers map a global 0..1 bar position to a (real stageIndex, local clip
-- fraction) pair through that ordered, filtered stage list.

-- Temporal cycle order + friendly display names for the reload stages.
local RFX_CYCLE_ORDER = { unload = 1, load = 2, loadshort = 2, rack = 3 }
local RFX_STAGE_DISPLAY = { load = "Load", loadshort = "Short load", rack = "Rack", unload = "Unload" }

---@param name string|nil
---@nodiscard
---@return string
local function rfxStageDisplay(name)
    return RFX_STAGE_DISPLAY[(name or ""):lower()] or (name or "stage")
end

---@nodiscard
---@return number
local function rfxStageCount()
    local g = AE.rfx.group
    return (g and g.stages and #g.stages) or 0
end

-- The group's load + loadShort stage indices (either may be nil).
---@nodiscard
---@return number|nil, number|nil
local function rfxLoadVariantIndexes()
    local g = AE.rfx.group
    local loadIdx, shortIdx
    if g and g.stages then
        for i = 1, #g.stages do
            local nm = (g.stages[i].stage or ""):lower()
            if nm == "load" then loadIdx = i elseif nm == "loadshort" then shortIdx = i end
        end
    end
    return loadIdx, shortIdx
end

-- True when the reload has BOTH a full Load and a Short load (so the combined view offers a choice).
---@nodiscard
---@return boolean
local function rfxHasBothLoadVariants()
    local l, s = rfxLoadVariantIndexes()
    return (l ~= nil and s ~= nil)
end

-- Ordered real stage indices shown on the combined bar: Unload -> selected Load variant -> Rack (plus
-- any non-cycle stages after). The unselected load variant (AE.rfx.loadVariant) is omitted -- a reload
-- never plays both.
---@nodiscard
---@return number[]
local function rfxCombinedStages()
    local g = AE.rfx.group
    if not g or not g.stages then return {} end
    local loadIdx, shortIdx = rfxLoadVariantIndexes()
    local variant = AE.rfx.loadVariant or "load"
    local slot = (variant == "loadshort") and (shortIdx or loadIdx) or (loadIdx or shortIdx)
    local list = {}
    for i = 1, #g.stages do
        if i ~= loadIdx and i ~= shortIdx then list[#list + 1] = i end
    end
    if slot then list[#list + 1] = slot end
    table.sort(list, function(a, b)
        local oa = RFX_CYCLE_ORDER[(g.stages[a].stage or ""):lower()] or 99
        local ob = RFX_CYCLE_ORDER[(g.stages[b].stage or ""):lower()] or 99
        if oa ~= ob then return oa < ob end
        return a < b
    end)
    return list
end

-- Global bar fraction -> real stageIndex, local fraction within that stage's clip (through the
-- combined cycle list).
---@param frac number
---@nodiscard
---@return number, number
local function rfxGlobalToStage(frac)
    local cs = rfxCombinedStages()
    local n = #cs
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    if n <= 1 then return cs[1] or (AE.rfx.stageIndex or 1), frac end
    local g = frac * n
    local p = math.floor(g) + 1
    if p > n then p = n elseif p < 1 then p = 1 end
    local f = g - (p - 1)
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
    return cs[p], f
end

-- real stageIndex, local fraction -> global bar fraction (from the stage's position in the cycle list).
---@param stageIndex number
---@param localFrac number
---@nodiscard
---@return number
local function rfxStageToGlobal(stageIndex, localFrac)
    local cs = rfxCombinedStages()
    local n = #cs
    if n <= 1 then return localFrac or 0 end
    local pos
    for i = 1, n do if cs[i] == stageIndex then pos = i; break end end
    if not pos then return 0 end
    return ((pos - 1) + (localFrac or 0)) / n
end

-- The unload stage is the load motion played in reverse (mag eject = insert backwards -- every
-- archetype seeds unload.baseClip == load.baseClip, and the baked node carries m_AnimReverse). Preview
-- it reversed so it matches the game; every other stage plays forward. Call right after forceClip,
-- which resets the reversed flag to false.
local function rfxSetStageReverse(stageName)
    local ap = animPlayer(); if not ap then return end
    local rev = (stageName ~= nil and tostring(stageName):lower() == "unload")
    pcall(function() ap:setForcedEditClipReversed(rev) end)
end

-- Focus a stage's clip for combined scrubbing: force its clip + point the working state at its marker
-- list BY REFERENCE (so combined edits persist to the stage), without the full rfxLoad preview
-- restart. Resets the applied-state caches so the next apply repaints for the new clip.
---@param s number
---@return nil
local function rfxFocusStage(s)
    local g = AE.rfx.group
    if not g or not g.stages[s] then return end
    local st = g.stages[s]
    st.markers = st.markers or {}
    AE.rfx.stageIndex = s
    AE.rfx.nodeFile = st.nodeFile
    AE.rfx.clip = st.clip
    AE.rfx.animId = st.animId
    AE.rfx.markers = st.markers
    if st.clip then
        AE.clip = st.clip
        forceClip(st.clip)
        rfxSetStageReverse(st.stage)
    end
    AE.rfx.appliedProp = nil
    AE.rfx.appliedHandProp = nil
    AE.rfx.appliedParts = {}
    AE.rfx.appliedGunParts = {}
end

-- Global playhead fraction on the combined bar, from the current clip time + focused stage.
---@nodiscard
---@return number
local function rfxGlobalFrac()
    local len = getClipLen()
    local lf = (len > 0) and (getClipTime() / len) or 0
    return rfxStageToGlobal(AE.rfx.stageIndex or 1, lf)
end

-- Split a gwSetPart value "PartType=fullType" into its parts. Empty fullType means detach. Returns
-- nil partType for a malformed value.
---@param value string|nil
---@nodiscard
---@return string|nil, string
local function rfxParsePartSwap(value)
    if not value or value == "" then return nil, "" end
    local eq = value:find("=", 1, true)
    if not eq then return nil, "" end
    local pt = value:sub(1, eq - 1)
    if pt == "" then return nil, "" end
    return pt, value:sub(eq + 1)
end

-- The transfer parts referenced by the loaded reload's gwPartToHand/gwPartToGun markers.
---@nodiscard
---@return table<string, boolean>
local function rfxTransferParts()
    local parts = {}
    for i = 1, #AE.rfx.markers do
        local m = AE.rfx.markers[i]
        if (m.event == "gwPartToHand" or m.event == "gwPartToGun") and m.value and m.value ~= "" then
            parts[m.value] = true
        end
    end
    return parts
end

---@nodiscard
---@return HandWeapon|nil
local function rfxGun()
    local p = getPlayer()
    if not p then return nil end
    if AE.rfx.gunId then
        local g = p:getInventory():getItemById(AE.rfx.gunId)
        if instanceof(g, "HandWeapon") then return g end
    end
    local held = p:getPrimaryHandItem()
    if instanceof(held, "HandWeapon") then return held end
    return nil
end

-- Give + equip the reload's gun so the preview has something to attach props/parts to. Gun fullType
-- is <mod>.<animId> (e.g. Gunsmithing.Musket1770); falls back to a held HandWeapon.
local function rfxEquipGun()
    local p = getPlayer()
    if not p then return nil end
    local existing = rfxGun()
    if existing then AE.rfx.gunId = existing:getID(); return existing end

    local gunType = (AE.rfx.mod and AE.rfx.animId) and (AE.rfx.mod .. "." .. AE.rfx.animId) or nil
    if not gunType then return nil end
    local gun = p:getInventory():AddItem(gunType)
    if not instanceof(gun, "HandWeapon") then return nil end
    p:setPrimaryHandItem(gun)
    if gun:isTwoHandWeapon() then p:setSecondaryHandItem(gun) end
    p:resetEquippedHandsModels()
    AE.rfx.gunId = gun:getID()
    return gun
end

-- Snapshot the gun's current weapon parts + off-hand prop, so the preview can be fully reverted.
local function rfxSnapshot()
    local RA = getReloadAnim()
    local p = getPlayer()
    local gun = rfxGun()
    if not RA or not p or not gun then return end
    local parts = {}
    local all = gun:getAllWeaponParts()
    if all and all.size then
        for i = 0, all:size() - 1 do
            local part = all:get(i)
            if part then parts[#parts + 1] = part:getFullType() end
        end
    end
    local propItem = p:getAttachedItem(RA.RELOAD_MAGAZINE_ATTACH_LOCATION)
    AE.rfx.snapshot = { parts = parts, prop = propItem and propItem:getFullType() or "" }
end

-- Compute the desired off-hand prop + part-on-gun state at fraction `frac` (fold markers <= frac)
-- and apply the DELTA to the live player+gun. Cheap on scrub: only mutates when the state changes.
local function rfxApplyStateAt(frac)
    local RA = getReloadAnim()
    local p = getPlayer()
    local gun = rfxGun()
    if not RA or not p or not gun then return end
    if not RA.hasAttachLocation(p, RA.RELOAD_MAGAZINE_ATTACH_LOCATION) then return end

    local sorted = {}
    for i = 1, #AE.rfx.markers do sorted[i] = AE.rfx.markers[i] end
    table.sort(sorted, function(a, b) return (a.timePc or 0) < (b.timePc or 0) end)

    local desiredProp = ""       -- off-hand (Bip01_Prop2) slot
    local desiredHandProp = ""   -- right-hand (Bip01_R_Hand) slot -- independent of the off-hand one
    local partsOffGun = {}
    -- gun-part swaps (gwSetPart): PartType -> desired fullType, seeded with each location's default part
    -- so scrubbing before its first marker reverts to that default. "" desired means detach.
    local desiredGunParts = {}
    for pt, def in pairs(AE.rfx.gwDefaultParts or {}) do desiredGunParts[pt] = def end
    for i = 1, #sorted do
        local m = sorted[i]
        if (m.timePc or 0) <= frac then
            if m.event == "gwSetProp" then
                desiredProp = m.value or ""
            elseif m.event == "gwSetHandProp" then
                desiredHandProp = m.value or ""
            elseif m.event == "gwPartToHand" then
                desiredProp = m.value or ""
                if m.value and m.value ~= "" then partsOffGun[m.value] = true end
            elseif m.event == "gwPartToGun" then
                desiredProp = ""
                if m.value and m.value ~= "" then partsOffGun[m.value] = nil end
            elseif m.event == "gwSetPart" then
                local pt, ft = rfxParsePartSwap(m.value)
                if pt then desiredGunParts[pt] = ft end
            end
        end
    end

    AE.rfx.appliedParts = AE.rfx.appliedParts or {}
    for part in pairs(rfxTransferParts()) do
        local off = partsOffGun[part] and true or false
        if AE.rfx.appliedParts[part] ~= off then
            if off then
                RA.detachVisualPart(p, gun, part)
            else
                RA.attachVisualPart(p, gun, part)
            end
            AE.rfx.appliedParts[part] = off
            p:resetEquippedHandsModels()
        end
    end

    -- gwSetPart: swap the part model at each touched location to its desired variant (or detach).
    AE.rfx.appliedGunParts = AE.rfx.appliedGunParts or {}
    for pt, desired in pairs(desiredGunParts) do
        if AE.rfx.appliedGunParts[pt] ~= desired then
            if desired ~= "" then
                RA.attachVisualPart(p, gun, desired)   -- auto-evicts the part sharing this PartType
            else
                local cur = gun:getWeaponPart(pt)
                if cur then RA.detachVisualPart(p, gun, cur:getFullType()) end
            end
            AE.rfx.appliedGunParts[pt] = desired
            p:resetEquippedHandsModels()
        end
    end

    if desiredProp ~= AE.rfx.appliedProp then
        RA.applyPropEvent(p, gun, RA.PROP_SET_EVENT, desiredProp)
        AE.rfx.appliedProp = desiredProp
    end
    if desiredHandProp ~= AE.rfx.appliedHandProp then
        RA.applyPropEvent(p, gun, RA.PROP_SET_HAND_EVENT, desiredHandProp)
        AE.rfx.appliedHandProp = desiredHandProp
    end
end

-- Enter the preview session: equip the gun, snapshot it, suppress the per-tick reconciler (which
-- keys off PerformingAction=="Reload"), and paint the state at the current playhead.
local function rfxStartPreview()
    local RA = getReloadAnim()
    local p = getPlayer()
    if not RA or not p then return false end
    rfxEquipGun()
    if not rfxGun() then return false end
    rfxSnapshot()
    -- Record each gwSetPart location's current (default) part, so the fold reverts to it when scrubbing
    -- before that location's first marker.
    AE.rfx.gwDefaultParts = {}
    local previewGun = rfxGun()
    if previewGun then
        for i = 1, #AE.rfx.markers do
            local mk = AE.rfx.markers[i]
            if mk.event == "gwSetPart" then
                local pt = rfxParsePartSwap(mk.value)
                if pt and AE.rfx.gwDefaultParts[pt] == nil then
                    local cur = previewGun:getWeaponPart(pt)
                    AE.rfx.gwDefaultParts[pt] = cur and cur:getFullType() or ""
                end
            end
        end
    end
    p:setVariable("PerformingAction", "Reload")   -- reconciler stands down; also selects the reload node
    AE.rfx.active = true
    AE.rfx.appliedProp = nil
    AE.rfx.appliedHandProp = nil
    AE.rfx.appliedParts = {}
    AE.rfx.appliedGunParts = {}
    AE.rfx.lastFrac = -1
    rfxApplyStateAt(markerFrac())
    return true
end

-- Leave the preview: clear the previewed prop, restore the snapshotted parts, release the reconciler.
local function rfxStopPreview()
    local RA = getReloadAnim()
    local p = getPlayer()
    local gun = rfxGun()
    if RA and p then
        if gun then
            RA.clearOffHandProp(p)
            local snap = AE.rfx.snapshot
            if snap then
                for i = 1, #snap.parts do RA.attachVisualPart(p, gun, snap.parts[i]) end
            end
            RA.restoreWeaponParts(p, gun)
            p:resetEquippedHandsModels()
        end
        p:clearVariable("PerformingAction")
    end
    AE.rfx.active = false
    AE.rfx.appliedProp = nil
    AE.rfx.appliedHandProp = nil
    AE.rfx.appliedParts = {}
    AE.rfx.appliedGunParts = {}
    AE.rfx.gwDefaultParts = nil
    AE.rfx.snapshot = nil
    AE.rfx.lastFrac = -1
end

-- Load a discovered reload: copy its markers, force-play its clip on the live character, and start
-- the live preview.
local function rfxLoad(reload)
    if not reload then return false end
    rfxStopPreview()
    AE.rfx.nodeFile = reload.nodeFile
    AE.rfx.clip = reload.clip
    AE.rfx.animId = reload.animId
    AE.rfx.mod = reload.mod
    AE.rfx.propItems = reload.propItems or {}
    AE.rfx.markers = {}
    local src = reload.markers or {}
    for i = 1, #src do
        AE.rfx.markers[i] = { event = src[i].event, timePc = src[i].timePc or 0, value = src[i].value or "" }
    end
    AE.rfx.marker = AE.rfx.markers[1]
    if AE.rfx.clip then
        AE.clip = AE.rfx.clip
        forceClip(AE.rfx.clip)
        rfxSetStageReverse(reload.stage or rfxStageLabel(reload))
        AE.playing = false
        setClipPaused(true)
        setClipTime(0)
    end
    rfxStartPreview()
    return true
end

-- Find a discovered reload by animId (or nodeFile) in the cached list.
---@nodiscard
---@return table|nil
local function rfxFindReload(key)
    if not key then return nil end
    for i = 1, #AE.rfx.reloads do
        local r = AE.rfx.reloads[i]
        if r.animId == key or r.nodeFile == key then return r end
    end
    return nil
end

-- Write the edited markers to anim_edit.json as a reloadMarkers output block, for the bake tool to
-- surgically rewrite the node XML (dst == "" -> in place).
local function rfxSave(dst)
    if not AE.rfx.nodeFile then return false end
    local markers = {}
    for i = 1, #AE.rfx.markers do
        local m = AE.rfx.markers[i]
        markers[i] = { event = m.event, timePc = m.timePc or 0, value = m.value or "" }
    end
    local data = {
        clip = AE.rfx.clip,
        output = {
            format = "reloadMarkers",
            nodeFile = AE.rfx.nodeFile,
            dst = (dst and dst ~= "") and dst or AE.rfx.nodeFile,
            animId = AE.rfx.animId,
            markers = markers,
        },
    }
    local writer = getFileWriter("AnimForge/anim_edit.json", true, false)
    writer:write(AnimForge.JSON.encode(data))
    writer:close()
    return true
end

-- Write the editor's current markers back into the cached reload entry (reload_markers.json) so that
-- closing + reopening the editor after a save shows the just-saved markers, not the stale scan cache
-- (a bake edits the mod XML but never rewrites that cache, which is what the scan owns).
local function rfxUpdateCachedMarkers()
    if not AE.rfx.reloads or not AE.rfx.nodeFile then return end
    local copy = {}
    for i = 1, #AE.rfx.markers do
        local m = AE.rfx.markers[i]
        copy[i] = { event = m.event, timePc = m.timePc or 0, value = m.value or "" }
    end
    local matched = false
    for i = 1, #AE.rfx.reloads do
        if AE.rfx.reloads[i].nodeFile == AE.rfx.nodeFile then
            AE.rfx.reloads[i].markers = copy
            matched = true
            break
        end
    end
    if not matched then return end
    local writer = getFileWriter("AnimForge/reload_markers.json", true, false)
    if writer then
        writer:write(AnimForge.JSON.encode({ reloads = AE.rfx.reloads }))
        writer:close()
    end
end

AE.bones = {
    "Bip01_R_UpperArm", "Bip01_R_Forearm", "Bip01_R_Hand",
    "Bip01_L_UpperArm", "Bip01_L_Forearm", "Bip01_L_Hand",
    "Bip01_Prop1", "Bip01_Prop2", "Bip01_Spine", "Bip01_Spine1", "Bip01_Neck", "Bip01_Head",
}
AE.clips = {
    "Bob_IdleHandgun", "Bob_IdleAimHandgun",
    "Bob_IdleAimHandgun_Up45", "Bob_IdleAimHandgun_Up75",
    "Bob_IdleAimHandgun_Down", "Bob_IdleAimHandgun_Down75",
}

local function ensureDelta(bone)
    local d = AE.deltas[bone]
    if not d then d = { rot = { 0, 0, 0 }, pos = { 0, 0, 0 } }; AE.deltas[bone] = d end
    return d
end

local function applyBone(bone)
    local p = getPlayer(); if not p then return false end
    local ap = p:getAnimationPlayer(); if not ap then return false end
    local d = ensureDelta(bone)
    return pcall(function()
        ap:setBoneRotationOverride(bone, d.rot[1], d.rot[2], d.rot[3])
        ap:setBonePositionOverride(bone, d.pos[1], d.pos[2], d.pos[3])
    end)
end

-- ---- keyframes: per-clip, per-bone {t, rot, pos} timeline with interpolation ----
-- Editing a bone auto-records a keyframe at the current clip time; the live override
-- is the keyframes interpolated at the current time, so scrubbing/playing previews it.
local KF_EPS = 0.02   -- seconds: editing within this of a keyframe updates it in place

local function cloneTriple(v) return { v[1], v[2], v[3] } end

local function kfList(clip, bone, create)
    local byClip = AE.keyframes[clip]
    if not byClip then
        if not create then return nil end
        byClip = {}; AE.keyframes[clip] = byClip
    end
    local list = byClip[bone]
    if not list and create then list = {}; byClip[bone] = list end
    return list
end

-- Interpolated { rot={x,y,z}, pos={x,y,z} } at time t, or nil if no keyframes. Holds
-- the end values outside the keyframe range (no extrapolation), linear between.
local function evalKf(list, t)
    local n = list and #list or 0
    if n == 0 then return nil end
    if n == 1 or t <= list[1].t then return { rot = cloneTriple(list[1].rot), pos = cloneTriple(list[1].pos) } end
    if t >= list[n].t then return { rot = cloneTriple(list[n].rot), pos = cloneTriple(list[n].pos) } end
    for i = 1, n - 1 do
        local a, b = list[i], list[i + 1]
        if t >= a.t and t <= b.t then
            local span = b.t - a.t
            local f = span > 1e-6 and (t - a.t) / span or 0
            local r, p = {}, {}
            for k = 1, 3 do
                r[k] = a.rot[k] + (b.rot[k] - a.rot[k]) * f
                p[k] = a.pos[k] + (b.pos[k] - a.pos[k]) * f
            end
            return { rot = r, pos = p }
        end
    end
    return { rot = cloneTriple(list[n].rot), pos = cloneTriple(list[n].pos) }
end

-- Insert or update (within KF_EPS) a keyframe at time t, keeping the list sorted.
local function upsertKf(clip, bone, t, rot, pos)
    local list = kfList(clip, bone, true)
    for i = 1, #list do
        if math.abs(list[i].t - t) <= KF_EPS then
            list[i].rot = cloneTriple(rot); list[i].pos = cloneTriple(pos); return
        elseif list[i].t > t then
            table.insert(list, i, { t = t, rot = cloneTriple(rot), pos = cloneTriple(pos) }); return
        end
    end
    list[#list + 1] = { t = t, rot = cloneTriple(rot), pos = cloneTriple(pos) }
end

-- Editing while playing auto-pauses, so the keyframe lands at a stable time.
local function pauseForEdit()
    if AE.playing then
        AE.playing = false
        setClipPaused(true)
        if AE.panel and AE.panel.playBtn then AE.panel.playBtn:setTitle("Play") end
    end
end

-- Record the bone's current delta as a keyframe at the current clip time.
local function recordKf(bone)
    pauseForEdit()
    local d = ensureDelta(bone)
    upsertKf(AE.clip, bone, getClipTime(), d.rot, d.pos)
end

-- setRot/setPos are the single edit path (sliders, gizmo, automation); each one
-- auto-records a keyframe at the current time, then applies the live override.
local function setRot(bone, ex, ey, ez)
    local d = ensureDelta(bone); d.rot = { ex, ey, ez }
    recordKf(bone); return applyBone(bone)
end
local function setPos(bone, tx, ty, tz)
    local d = ensureDelta(bone); d.pos = { tx, ty, tz }
    recordKf(bone); return applyBone(bone)
end

local function saveJson(set)
    local data = {
        clip = AE.clip, order = AE.order, mode = AE.mode, deltas = AE.deltas,
        keyframes = AE.keyframes,   -- per-clip timeline; baker still reads `deltas` for the constant case
    }
    -- A 'set' block tells the baker to produce SEPARATE renamed animations for a
    -- whole clip set in a mod, instead of overwriting the one vanilla clip.
    if set then
        local block = { clips = AE.clips, namePrefix = AE.namePrefix, mod = AE.mod }
        -- Only carry an explicit tag; blank lets wire-set apply its own default.
        if AE.tag and AE.tag ~= "" then block.tag = AE.tag end
        data.set = block
    end
    -- Editing a discovered MOD .glb clip: tell the baker to rewrite that clip's bone rotation
    -- keys (with the -90X convention compensation) back into the same file or a chosen new one.
    local meta = AE.modClips[AE.clip]
    if meta and meta.format == "glb" then
        local dst = (AE.glbDst and AE.glbDst ~= "") and AE.glbDst or meta.srcPath
        data.output = { format = "glb", srcGlb = meta.srcPath, dst = dst, clip = meta.stem, mod = meta.mod }
    end
    local writer = getFileWriter("AnimForge/anim_edit.json", true, false)
    writer:write(AnimForge.JSON.encode(data))
    writer:close()
end

-- Point AE.clips at a weapon's curated grip set (or its full set). Returns true
-- if the category exists.
local function loadWeapon(weapon, useAll)
    local cats = AnimForge.AnimCategories
    local cat = cats and cats[weapon]
    if not cat then return false end
    AE.weapon = weapon
    AE.useAll = useAll and true or false
    AE.clips = useAll and cat.all or cat.grip
    if #AE.clips > 0 then AE.clip = AE.clips[1] end
    return true
end

-- ------------------------------------------------------------- projects ----
-- A project bundles a weapon's grip checklist with the per-clip edits (kept live
-- in AE.keyframes) and a per-clip "done" flag (AE.done), so a custom gun's whole
-- animation set can be saved, reloaded, and tracked. AnimProjects.lua owns disk
-- persistence; this layer maps a project to/from the editor's live AE state.
local AP = AnimForge.AnimProjects

-- True if `clip` has at least one keyframed bone (so the badge can show "edited").
---@param clip string
---@return boolean
local function clipEdited(clip)
    local byClip = AE.keyframes[clip]
    if not byClip then return false end
    for _ in pairs(byClip) do return true end
    return false
end

-- done / edited / total clip counts for the active project (0,0,total when none).
---@return integer done
---@return integer edited
---@return integer total
local function projectProgress()
    local clips = AE.clips or {}
    local total, done, edited = #clips, 0, 0
    if not AE.project then return 0, 0, total end
    for i = 1, total do
        local clip = clips[i]
        if AE.done[clip] then done = done + 1 end
        if clipEdited(clip) then edited = edited + 1 end
    end
    return done, edited, total
end

-- Assemble a serializable project table from the live AE state (for saving).
---@return table|nil
local function buildProject()
    local proj = AE.project
    if not proj then return nil end
    local clips = AE.clips or {}
    local perClip = {}
    for i = 1, #clips do
        local clip = clips[i]
        local entry = { done = AE.done[clip] == true }
        local kf = AE.keyframes[clip]
        if kf then entry.keyframes = kf end
        perClip[clip] = entry
    end
    return {
        name = proj.name, slug = proj.slug, weapon = proj.weapon,
        namePrefix = AE.namePrefix, mod = AE.mod, tag = AE.tag,
        useAll = AE.useAll == true, clips = clips, perClip = perClip,
    }
end

-- Persist the active project to disk (no-op when none active). Returns its slug.
-- Type-aware: a gunworks project must be rebuilt via GW.buildProject (the grip
-- buildProject would overwrite it with an empty grip shape, losing the stages).
---@return string|nil
local function saveProject()
    if AE.project and AE.project.type == "gunworks" and AE.GW then
        local proj = AE.GW.buildProject(AE.project.name)
        proj.slug = AE.project.slug
        local slug = AP.save(proj)
        AE.project.slug = slug
        return slug
    end
    local proj = buildProject()
    if not proj then return nil end
    local slug = AP.save(proj)
    AE.project.slug = slug
    return slug
end

-- Load a project table into the live AE state (clips, keyframes, done, metadata).
---@param project table
local function applyProject(project)
    AE.weapon = project.weapon
    AE.useAll = project.useAll == true
    if project.namePrefix then AE.namePrefix = project.namePrefix end
    AE.mod = project.mod or ""
    AE.tag = project.tag or ""
    AE.clips = project.clips or {}
    AE.keyframes = {}
    AE.done = {}
    AE.deltas = {}   -- the overlay re-derives live deltas from the loaded keyframes
    local perClip = project.perClip or {}
    for i = 1, #AE.clips do
        local clip = AE.clips[i]
        local pc = perClip[clip]
        if pc then
            if pc.done then AE.done[clip] = true end
            if pc.keyframes then AE.keyframes[clip] = pc.keyframes end
        end
    end
    AE.project = { name = project.name, slug = project.slug, weapon = project.weapon }
    if #AE.clips > 0 then AE.clip = AE.clips[1] end
end

-- Start a fresh project for `weapon` (autosaving any outgoing one first). The
-- checklist is a snapshot of the weapon's grip (or full) set so later category
-- regeneration can't shift an in-progress set. Returns false on unknown weapon.
---@param name string
---@param weapon string
---@param prefix string
---@param mod string
---@param tag string
---@param useAll boolean
---@return boolean
local function newProject(name, weapon, prefix, mod, tag, useAll)
    local cats = AnimForge.AnimCategories
    local cat = cats and cats[weapon]
    if not cat then return false end
    saveProject()   -- don't lose the outgoing project's edits
    local src = cat.grip
    if useAll then src = cat.all end
    local snap = {}
    for i = 1, #src do snap[i] = src[i] end
    local project = {
        name = name, slug = AP.slugify(name), weapon = weapon,
        namePrefix = prefix, mod = mod, tag = tag,
        useAll = useAll == true, clips = snap, perClip = {},
    }
    applyProject(project)
    AP.save(project)
    return true
end

-- Load a saved project by slug into the editor (autosaving the outgoing one).
---@param slug string
---@return boolean
local function loadProject(slug)
    saveProject()   -- flush the outgoing project first (matters if it IS this slug)
    local project = AP.load(slug)
    if not project then return false end
    applyProject(project)
    return true
end

-- Toggle a clip's done flag in the active project and persist immediately, so a
-- checkoff is never lost. No-op when no project is active.
---@param clip string
---@param done boolean
local function setClipDone(clip, done)
    if not AE.project then return end
    if done then AE.done[clip] = true else AE.done[clip] = nil end
    saveProject()
end


-- ---- ramrod / prop-socket rotation fix (the -90X off-hand socket correction) ------------------
-- Blender ships the two weapon sockets - Bip01_Prop1 (gun) and Bip01_Prop2 (off-hand / ramrod) -
-- 90 deg off what PZ expects, so an item riding the socket renders at a fixed wrong angle. The bake
-- writes a -90X into the glb (marker-guarded, via the pz-anim-forge prop-fix path). These preview
-- that SAME correction live by post-multiplying -90X on the socket bone(s) still needing it: X
-- commutes with the engine's -90X bone modifier, so the live override reproduces the baked file.
local PROP_SOCKET_BONES = { "Bip01_Prop1", "Bip01_Prop2" }
local PROP_FIX_EULER = { -90, 0, 0 }   -- degrees (matches the baked -90X); flip here if it previews mirrored

-- Discovered clip meta ({srcPath, format, propBones, propFix, ...}) for the loaded reload's clip.
local function rfxClipMeta()
    return (AE.rfx.clip and AE.modClips) and AE.modClips[AE.rfx.clip] or nil
end

-- Prop sockets the loaded clip still needs corrected (in the glb, not yet in its pz_prop_fix marker).
local function rfxNeededPropBones()
    local meta = rfxClipMeta()
    if not (meta and meta.format == "glb" and meta.propBones) then return {} end
    local fixed = {}
    for _, b in ipairs(meta.propFix or {}) do fixed[b] = true end
    local needed = {}
    for _, b in ipairs(meta.propBones) do if not fixed[b] then needed[#needed + 1] = b end end
    return needed
end

-- Does the loaded clip have a prop socket at all (so the fix control applies to it)?
local function rfxClipHasPropSocket()
    local meta = rfxClipMeta()
    return (meta and meta.format == "glb" and meta.propBones and #meta.propBones > 0) and true or false
end

-- Clear any live prop-socket override (both sockets), so switching clips / closing never leaves a
-- stale -90X on the player.
local function rfxClearPropOverrides()
    local ap = animPlayer(); if not ap then return end
    for i = 1, #PROP_SOCKET_BONES do
        pcall(function() ap:setBoneRotationOverride(PROP_SOCKET_BONES[i], 0, 0, 0) end)
    end
    AE.rfx.livePropFix = false
end

-- Apply (on) or clear (off) the live -90X preview. Overrides the sockets this clip still needs, or
-- an explicit `bones` list (used right after a bake: the on-disk glb is fixed but the loaded clip is
-- still cached uncorrected, so we keep the override on the just-baked sockets for the session).
local function rfxSetLivePropFix(on, bones)
    rfxClearPropOverrides()
    if not on then return end
    local ap = animPlayer(); if not ap then return end
    local list = bones or rfxNeededPropBones()
    for i = 1, #list do
        pcall(function()
            ap:setBoneRotationOverride(list[i], PROP_FIX_EULER[1], PROP_FIX_EULER[2], PROP_FIX_EULER[3])
        end)
    end
    AE.rfx.livePropFix = true
end

-- Write the prop-fix bake request the watcher claims. scope "mod" fixes every glb in the reload's
-- mod; otherwise the loaded clip's glb (only sockets it still needs). Returns the ts to poll on, or
-- nil when there is nothing to request.
local function rfxWritePropFixRequest(scope)
    local ts = getTimestampMs()
    local req = { ts = ts }
    if scope == "mod" then
        if not AE.rfx.mod or AE.rfx.mod == "" then return nil end
        req.mod = AE.rfx.mod
        req.scope = "mod"
    else
        local meta = rfxClipMeta()
        if not (meta and meta.srcPath) then return nil end
        local needed = rfxNeededPropBones()
        if #needed == 0 then return nil end   -- already fully fixed on disk
        req.glb = meta.srcPath
        req.scope = "clip"
        req.bones = needed
    end
    local writer = getFileWriter("AnimForge/glb_prop_fix_request.json", true, false)
    if not writer then return nil end
    writer:write(AnimForge.JSON.encode(req))
    writer:close()
    return ts
end

-- After a successful bake, mark the clip (or the whole mod's clips) fixed in the in-memory cache so
-- the tick reflects on-disk truth and a repeat click is a no-op.
local function rfxMarkPropFixed(scope)
    if not AE.modClips then return end
    local function markOne(meta)
        if meta and meta.format == "glb" and meta.propBones then meta.propFix = meta.propBones end
    end
    if scope == "mod" then
        for _, meta in pairs(AE.modClips) do
            if meta and meta.mod == AE.rfx.mod then markOne(meta) end
        end
    else
        markOne(rfxClipMeta())
    end
end


AnimForge.EditCore = {
    KF_EPS = KF_EPS,
    animPlayer = animPlayer,
    applyBone = applyBone,
    rfxClipHasPropSocket = rfxClipHasPropSocket,
    rfxClearPropOverrides = rfxClearPropOverrides,
    rfxNeededPropBones = rfxNeededPropBones,
    rfxSetLivePropFix = rfxSetLivePropFix,
    rfxWritePropFixRequest = rfxWritePropFixRequest,
    rfxMarkPropFixed = rfxMarkPropFixed,
    applyModClips = applyModClips,
    clipEdited = clipEdited,
    ensureDelta = ensureDelta,
    evalKf = evalKf,
    forceClip = forceClip,
    getClipLen = getClipLen,
    getClipTime = getClipTime,
    getReloadAnim = getReloadAnim,
    loadModClipsFromCache = loadModClipsFromCache,
    loadProject = loadProject,
    loadReloadsFromCache = loadReloadsFromCache,
    loadWeapon = loadWeapon,
    markerFrac = markerFrac,
    newProject = newProject,
    projectProgress = projectProgress,
    readJsonFile = readJsonFile,
    recordKf = recordKf,
    rfxApplyStateAt = rfxApplyStateAt,
    rfxEditableReloads = rfxEditableReloads,
    rfxGroupedReloads = rfxGroupedReloads,
    rfxStageCount = rfxStageCount,
    rfxStageDisplay = rfxStageDisplay,
    rfxCombinedStages = rfxCombinedStages,
    rfxHasBothLoadVariants = rfxHasBothLoadVariants,
    rfxGlobalToStage = rfxGlobalToStage,
    rfxStageToGlobal = rfxStageToGlobal,
    rfxFocusStage = rfxFocusStage,
    rfxGlobalFrac = rfxGlobalFrac,
    rfxFindReload = rfxFindReload,
    rfxFirstEditable = rfxFirstEditable,
    rfxGun = rfxGun,
    rfxLoad = rfxLoad,
    rfxParsePartSwap = rfxParsePartSwap,
    rfxSave = rfxSave,
    rfxStartPreview = rfxStartPreview,
    rfxStopPreview = rfxStopPreview,
    rfxUpdateCachedMarkers = rfxUpdateCachedMarkers,
    saveJson = saveJson,
    saveProject = saveProject,
    setClipDone = setClipDone,
    setClipPaused = setClipPaused,
    setClipTime = setClipTime,
    setPos = setPos,
    setRot = setRot
}
