-- In-game animation grip editor.
-- Force-holds a chosen clip on the real player and poses bones live (rotation +
-- translation) via the patched AnimationPlayer overrides, then saves the dialed
-- deltas to AgentBridge/anim_edit.json, which `pz-anim-forge bake` turns into a
-- new .x. The gun rides on Bip01_Prop1 (the equipped/preview weapon).
require "AnimForge/JSON"
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
require "AnimForge/AnimCategories"
require "AnimForge/AnimProjects"
require "AnimForge/AnimForgeTheme"
require "AnimForge/AnimForgeWidgets"

AnimForge = AnimForge or {}

-- Optional bridge integration: when the AgentBridge mod is present, the editor's headless ops register
-- on its Dispatcher so an MCP / agent can drive it. Standalone (no AgentBridge) the ops simply never
-- register and the editor is driven purely through its UI (the "Toggle Anim Forge" keybind, default
-- HOME). Ops are queued and flushed on OnGameBoot, so registration works regardless of mod load order.
local _pendingBridgeOps = {}
local D = {
    register = function(name, side, fn)
        if AgentBridge and AgentBridge.Dispatcher and AgentBridge.Dispatcher.register then
            AgentBridge.Dispatcher.register(name, side, fn)
        else
            _pendingBridgeOps[#_pendingBridgeOps + 1] = { name, side, fn }
        end
    end,
}
Events.OnGameBoot.Add(function()
    if not (AgentBridge and AgentBridge.Dispatcher and AgentBridge.Dispatcher.register) then return end
    for i = 1, #_pendingBridgeOps do
        local op = _pendingBridgeOps[i]
        AgentBridge.Dispatcher.register(op[1], op[2], op[3])
    end
    _pendingBridgeOps = {}
end)

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

-- Mod animation clips discovered by the MCP (pz_anim_list_clips) and pushed in via the
-- anim_mod_clips_set bridge op. modClips is keyed by the force-play name (the filename stem,
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
    nodeFile = nil, clip = nil, animId = nil, mod = nil,
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

-- Load the mod-clip list that the MCP's pz_anim_list_clips cached to disk, so the "Mods" tab is
-- populated without a manual push. Safe to call whenever the editor/browser opens.
local function loadModClipsFromCache()
    local reader = getFileReader("AgentBridge/mod_clips.json", false)
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

-- Load the reload list the MCP's pz_anim_list_reloads cached, for the "Edit reload attachments" picker.
local function loadReloadsFromCache()
    local data = readJsonFile("AgentBridge/reload_markers.json")
    AE.rfx.reloads = (data and data.reloads) or AE.rfx.reloads or {}
    return AE.rfx.reloads
end

-- A reload is worth showing in "Edit reload attachments" only if it actually has something to edit:
-- existing attachment markers, or a prop whitelist (partState) to add them from. The scan also turns
-- up plain animation-only reloads (e.g. AnimatedReloads' Bren/M249/Sten) that have neither - those
-- would otherwise fill the short row list and push a real one (the Musket) off the end.
local function rfxIsEditable(r)
    return r ~= nil and ((r.markers and #r.markers > 0) or (r.propItems and #r.propItems > 0))
end

-- The reloads to present, editable ones first (stable within each group). Falls back to the full
-- list if nothing is editable, so the picker is never mysteriously empty.
local function rfxEditableReloads()
    local all = AE.rfx.reloads or {}
    local editable = {}
    for i = 1, #all do
        if rfxIsEditable(all[i]) then editable[#editable + 1] = all[i] end
    end
    return #editable > 0 and editable or all
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
    return pcall(function() ap:setForcedEditClip(clip) end)
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
    p:setVariable("PerformingAction", "Reload")   -- reconciler stands down; also selects the reload node
    AE.rfx.active = true
    AE.rfx.appliedProp = nil
    AE.rfx.appliedHandProp = nil
    AE.rfx.appliedParts = {}
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

-- Write the edited markers to anim_edit.json as a reloadMarkers output block, for pz_anim_bake to
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
    local writer = getFileWriter("AgentBridge/anim_edit.json", true, false)
    writer:write(AnimForge.JSON.encode(data))
    writer:close()
    return true
end

-- Write the editor's current markers back into the cached reload entry (reload_markers.json) so that
-- closing + reopening the editor after a save shows the just-saved markers, not the stale scan cache
-- (a bake edits the mod XML but never rewrites that cache, which is what pz_anim_list_reloads owns).
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
    local writer = getFileWriter("AgentBridge/reload_markers.json", true, false)
    if writer then
        writer:write(AnimForge.JSON.encode({ reloads = AE.rfx.reloads }))
        writer:close()
    end
end

AE.bones = {
    "Bip01_R_UpperArm", "Bip01_R_Forearm", "Bip01_R_Hand",
    "Bip01_L_UpperArm", "Bip01_L_Forearm", "Bip01_L_Hand",
    "Bip01_Prop1", "Bip01_Spine", "Bip01_Spine1", "Bip01_Neck", "Bip01_Head",
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
    local writer = getFileWriter("AgentBridge/anim_edit.json", true, false)
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

-- ---------------------------------------------------------------- panel ----
-- ----------------------------------------------------- keyframe timeline bar --
-- A thin strip above the scrub bar showing the selected bone's keyframes as ticks.
-- Left-drag a tick to move its time; left-click empty space to seek; right-click a
-- tick to delete it. Owns its own mouse input so it never fights the slider/panel.
KeyframeBar = ISUIElement:derive("KeyframeBar")

function KeyframeBar:new(x, y, w, h)
    local o = ISUIElement:new(x, y, w, h)
    setmetatable(o, self); self.__index = self
    o.dragKf = nil
    return o
end

function KeyframeBar:list()
    local byClip = AE.keyframes[AE.clip]
    return byClip and byClip[AE.bone]
end

-- Nearest keyframe within 7px of bar-local x, or nil.
function KeyframeBar:hitKf(x)
    local list = self:list()
    local len = getClipLen()
    if not (list and len > 0) then return nil end
    local best, bestKf = 7, nil
    for _, kf in ipairs(list) do
        local d = math.abs(x - (kf.t / len) * self.width)
        if d < best then best, bestKf = d, kf end
    end
    return bestKf
end

function KeyframeBar:prerender()
    -- faint track so the empty timeline is visible/clickable
    self:drawRect(0, self.height / 2 - 1, self.width, 2, 0.5, 0.5, 0.5, 0.6)
    local list = self:list()
    local len = getClipLen()
    if not (list and len > 0) then return end
    local now = getClipTime()
    local hoverX = self:isMouseOver() and self:getMouseX() or -999
    for _, kf in ipairs(list) do
        local mx = (kf.t / len) * self.width
        local atNow = math.abs(kf.t - now) <= KF_EPS
        local hot = (self.dragKf == kf) or (math.abs(hoverX - mx) <= 7)
        local s = (hot or atNow) and 8 or 6
        self:drawRect(mx - s / 2, 0, s, self.height, 1, 1.0, atNow and 1.0 or 0.82, hot and 0.55 or (atNow and 0.4 or 0.12))
        self:drawRectBorder(mx - s / 2, 0, s, self.height, 0.7, 0, 0, 0)
    end
end

function KeyframeBar:seekTo(t)
    AE.playing = false
    setClipPaused(true)
    setClipTime(t)
    if AE.panel and AE.panel.playBtn then AE.panel.playBtn:setTitle("Play") end
end

function KeyframeBar:onMouseDown(x, y)
    local kf = self:hitKf(x)
    if kf then
        self.dragKf = kf
        self:setCapture(true)
    else
        local len = getClipLen()
        if len > 0 then
            local t = (x / self.width) * len
            if t < 0 then t = 0 elseif t > len then t = len end
            self:seekTo(t)   -- click empty timeline = scrub there
        end
    end
    return true   -- always consume, so the panel never drags from the bar
end

function KeyframeBar:onMouseMove(dx, dy)
    if not self.dragKf then return end
    local len = getClipLen()
    if len <= 0 then return end
    local t = (self:getMouseX() / self.width) * len
    if t < 0 then t = 0 elseif t > len then t = len end
    self.dragKf.t = t
    local list = self:list()
    if list then table.sort(list, function(a, b) return a.t < b.t end) end
    self:seekTo(t)   -- preview follows the dragged keyframe
end

function KeyframeBar:onMouseUp(x, y)
    self.dragKf = nil
    self:setCapture(false)
end
KeyframeBar.onMouseUpOutside = KeyframeBar.onMouseUp
KeyframeBar.onMouseMoveOutside = KeyframeBar.onMouseMove

function KeyframeBar:onRightMouseDown(x, y)
    local kf = self:hitKf(x)
    if kf then
        local byClip = AE.keyframes[AE.clip]
        local list = byClip and byClip[AE.bone]
        if list then
            for i = #list, 1, -1 do
                if list[i] == kf then table.remove(list, i); break end
            end
            if #list == 0 then byClip[AE.bone] = nil end
        end
    end
    return true
end

AnimEditorPanel = ISPanel:derive("AnimEditorPanel")

local PE_TAB_H = 22
local TIMELINE_POP_W = 520   -- popped-out timeline window width (wider than inline)

-- AnimEditorPanel is the reusable pose-editing view: a Pose tab (bone + stacked
-- sliders + the keyframe timeline) and a Gizmo tab (overlay settings, kept out of
-- the main flow). Single column so it stays slim. Embedded in the hub's content
-- (no background, never moves). Remains `AE.panel` so the bridge + overlay contract
-- holds. The timeline lives in `self.timeHost`, which can pop out into its own
-- draggable window (re-parented, not duplicated).
function AnimEditorPanel:new(x, y, w)
    local o = ISPanel:new(x, y, w or 392, 380)
    setmetatable(o, self); self.__index = self
    o.background = false
    o.moveWithMouse = false
    o.activeTab = "pose"
    return o
end

-- One labelled slider + live value on its own full-width row (tagged for the Pose tab).
function AnimEditorPanel:addSliderRow(label, x, sy, w, kind, axis, vmin, vmax, step, tip)
    local al = ISLabel:new(x, sy, 16, label, 0.8, 0.82, 0.9, 1, UIFont.Small, true)
    al:initialise(); self:addChild(al); al.tab = "pose"
    local sl = ISSliderPanel:new(x + 16, sy, w - 16 - 42, 18, self, AnimEditorPanel.onSlider)
    sl:initialise(); self:addChild(sl); sl.tab = "pose"; sl.tooltip = tip
    sl:setValues(vmin, vmax, step, (vmax - vmin) / 10, true)
    sl:setCurrentValue(0, true)
    sl.kind, sl.axisIndex = kind, axis
    local vl = ISLabel:new(x + w - 40, sy, 16, "0", 0.7, 1, 0.7, 1, UIFont.Small, true)
    vl:initialise(); self:addChild(vl); vl.tab = "pose"
    self.sliders[kind][axis] = sl
    self.valLabels[kind][axis] = vl
end

function AnimEditorPanel:createChildren()
    ISPanel.createChildren(self)
    local T = AnimForge.AnimForgeTheme
    local pad = T.sp.m
    local W = self.width
    local fullW = W - pad * 2
    local halfW = math.floor((fullW - T.sp.s) / 2)

    self.sliders = { rot = {}, pos = {} }
    self.valLabels = { rot = {}, pos = {} }

    -- ---- tab bar: Pose | Gizmo (always visible) ----
    self.tabBtns = {}
    local tx = pad
    for _, t in ipairs({ { k = "pose", l = "Pose" }, { k = "gizmo", l = "Gizmo" } }) do
        local b = ISButton:new(tx, 2, 78, PE_TAB_H, t.l, self, AnimEditorPanel.onTab)
        b.tabKey = t.k; b:initialise(); self:addChild(b); T.styleGhost(b)
        self.tabBtns[t.k] = b; tx = tx + 82
    end
    local top = 2 + PE_TAB_H + 8

    -- =========================== POSE TAB ===========================
    -- bone selector (or click a node on the character)
    self.yBone = top
    local bl = ISLabel:new(pad, top + 2, 16, "Bone", 0.8, 0.82, 0.9, 1, UIFont.Small, true)
    bl:initialise(); self:addChild(bl); bl.tab = "pose"
    self.boneCombo = ISComboBox:new(pad + 40, top, fullW - 40, 22, self, AnimEditorPanel.onBone)
    self.boneCombo:initialise(); self:addChild(self.boneCombo); self.boneCombo.tab = "pose"
    for _, b in ipairs(AE.bones) do
        self.boneCombo:addOptionWithData(b, nil, "Pose this bone. You can also click its node on the character.")
    end
    self.boneCombo:select(AE.bone)

    -- rotation X/Y/Z then translation X/Y/Z, stacked (one column)
    local axes = { "X", "Y", "Z" }
    self.yRot = top + 30
    local sy = self.yRot + 18
    for i = 1, 3 do
        self:addSliderRow(axes[i], pad, sy, fullW, "rot", i, -90, 90, 1,
            "Rotate the selected bone around " .. axes[i] .. " (degrees). Auto-keys at the current time.")
        sy = sy + 24
    end
    self.yTrans = sy + 2
    sy = self.yTrans + 18
    for i = 1, 3 do
        self:addSliderRow(axes[i], pad, sy, fullW, "pos", i, -0.3, 0.3, 0.01,
            "Translate the selected bone along " .. axes[i] .. " (model units).")
        sy = sy + 24
    end

    -- per-bone actions
    local ay = sy + 4
    self.resetBtn = ISButton:new(pad, ay, halfW, 22, "Reset bone", self, AnimEditorPanel.onReset)
    self.resetBtn:initialise(); self:addChild(self.resetBtn); T.styleGhost(self.resetBtn)
    self.resetBtn.tab = "pose"; self.resetBtn.tooltip = "Clear this bone's pose + keyframes on the current clip."
    self.doneBtn = ISButton:new(pad + halfW + T.sp.s, ay, halfW, 22, "Mark done", self, AnimEditorPanel.onMarkDone)
    self.doneBtn:initialise(); self:addChild(self.doneBtn); T.styleGhost(self.doneBtn)
    self.doneBtn.tab = "pose"; self.doneBtn.tooltip = "Mark the current clip/stage finished (progress tracking)."

    -- timeline host (pop-out-able). Header "TIMELINE" drawn in prerender.
    self.yTime = ay + 30
    self.timeHost = ISPanel:new(pad, self.yTime + 18, fullW, 86)
    self.timeHost.background = false
    self.timeHost:initialise(); self:addChild(self.timeHost); self.timeHost.tab = "pose"
    self:buildTimeline(fullW)

    -- loaded-clip status line (always visible, both tabs)
    self.status = ISLabel:new(pad, self.yTime + 18 + 90, 16, "clip: " .. AE.clip, 0.75, 0.95, 0.75, 1, UIFont.Small, true)
    self.status:initialise(); self:addChild(self.status)
    local poseBottom = self.yTime + 18 + 90 + 18

    -- =========================== GIZMO TAB ===========================
    self.yGizmo = top
    local gy = top + 18
    self.nodesTick = ISTickBox:new(pad, gy + 2, 18, 18, "", self, AnimEditorPanel.onNodesTick)
    self.nodesTick:initialise(); self:addChild(self.nodesTick); self.nodesTick.tab = "gizmo"
    self.nodesTick:addOption("show bone nodes")
    self.nodesTick:setSelected(1, AE.showNodes)
    self.nodesTick.tooltip = "Show the clickable bone nodes + the drag gizmo on the character."
    local gy2 = gy + 28
    self.gizmoBtn = ISButton:new(pad, gy2, fullW, 22,
        "Gizmo: " .. (AE.gizmoMode == "rot" and "Rotate" or "Translate"),
        self, AnimEditorPanel.onGizmoMode)
    self.gizmoBtn:initialise(); self:addChild(self.gizmoBtn); T.styleGhost(self.gizmoBtn)
    self.gizmoBtn.tab = "gizmo"; self.gizmoBtn.tooltip = "Switch the drag gizmo between rotate (rings) and translate (arrows). Hotkey: R."
    local gy3 = gy2 + 28
    self.thickLabel = ISLabel:new(pad, gy3, 16, "line", 0.8, 0.85, 1, 1, UIFont.Small, true)
    self.thickLabel:initialise(); self:addChild(self.thickLabel); self.thickLabel.tab = "gizmo"
    self.thickSlider = ISSliderPanel:new(pad + 56, gy3, fullW - 56, 16, self, AnimEditorPanel.onThick)
    self.thickSlider:initialise(); self:addChild(self.thickSlider); self.thickSlider.tab = "gizmo"
    self.thickSlider:setDoButtons(false); self.thickSlider:setValues(1, 20, 1, 5, true)
    self.thickSlider:setCurrentValue(AE.gizmoThick, true)
    self.thickSlider.tooltip = "Gizmo line thickness."
    local gy4 = gy3 + 26
    self.alphaLabel = ISLabel:new(pad, gy4, 16, "opacity", 0.8, 0.85, 1, 1, UIFont.Small, true)
    self.alphaLabel:initialise(); self:addChild(self.alphaLabel); self.alphaLabel.tab = "gizmo"
    self.alphaSlider = ISSliderPanel:new(pad + 56, gy4, fullW - 56, 16, self, AnimEditorPanel.onAlpha)
    self.alphaSlider:initialise(); self:addChild(self.alphaSlider); self.alphaSlider.tab = "gizmo"
    self.alphaSlider:setDoButtons(false); self.alphaSlider:setValues(0.1, 1, 0.05, 0.2, true)
    self.alphaSlider:setCurrentValue(AE.gizmoAlpha, true)
    self.alphaSlider.tooltip = "Gizmo opacity."

    self:setHeight(poseBottom)
    self:showTab(self.activeTab or "pose")
end

-- Build (or rebuild) the timeline widgets as children of self.timeHost, laid out
-- for width w. Created once; layoutTimeline repositions on a width change (pop-out).
function AnimEditorPanel:buildTimeline(w)
    local T = AnimForge.AnimForgeTheme
    local host = self.timeHost
    self.kfBar = KeyframeBar:new(78, 0, w - 78, 13)
    self.kfBar:initialise(); host:addChild(self.kfBar)
    self.playBtn = ISButton:new(0, 15, 70, 22, AE.playing and "Pause" or "Play", self, AnimEditorPanel.onPlayPause)
    self.playBtn:initialise(); host:addChild(self.playBtn); T.styleGhost(self.playBtn)
    self.playBtn.tooltip = "Play / pause the clip (Space)."
    self.scrub = ISSliderPanel:new(78, 17, w - 78, 18, self, AnimEditorPanel.onScrub)
    self.scrub:initialise(); host:addChild(self.scrub)
    self.scrub:setDoButtons(false); self.scrub:setValues(0, 1, 0.001, 0.05, true)
    self.scrub:setCurrentValue(0, true); self.scrub.tooltip = "Scrub through the clip timeline."
    self.timeLbl = ISLabel:new(0, 42, 16, "0.00 / 0.00s", 0.8, 0.85, 1, 1, UIFont.Small, true)
    self.timeLbl:initialise(); host:addChild(self.timeLbl)
    self.clearKfBtn = ISButton:new(w - 108, 40, 108, 20, "Clear keyframes", self, AnimEditorPanel.onClearKf)
    self.clearKfBtn:initialise(); host:addChild(self.clearKfBtn); T.styleGhost(self.clearKfBtn)
    self.clearKfBtn.tooltip = "Delete all keyframes for the selected bone on this clip."
    self.popBtn = ISButton:new(0, 64, 110, 20, "Pop out", self, AnimEditorPanel.onPopTimeline)
    self.popBtn:initialise(); host:addChild(self.popBtn); T.styleGhost(self.popBtn)
    self.popBtn.tooltip = "Pop the timeline out into its own draggable window."
end

-- Reposition the timeline widgets for host width w (inline vs popped-out).
function AnimEditorPanel:layoutTimeline(w)
    self.timeHost:setWidth(w)
    self.kfBar:setX(78); self.kfBar:setWidth(w - 78)
    self.scrub:setX(78); self.scrub:setWidth(w - 78)
    self.clearKfBtn:setX(w - 108)
end

function AnimEditorPanel:onTab(button) self:showTab(button.tabKey) end

-- Show only the active tab's widgets (tagged via .tab); untagged children (tab
-- buttons, status) stay visible.
function AnimEditorPanel:showTab(tab)
    local T = AnimForge.AnimForgeTheme
    self.activeTab = tab
    for _, c in ipairs(self.childrenInOrder or {}) do
        if c.tab then c:setVisible(c.tab == tab) end
    end
    -- the popped-out timeline host is not a child here, so it is unaffected
    for k, b in pairs(self.tabBtns) do
        if k == tab then T.stylePrimary(b) else T.styleGhost(b) end
    end
end

-- Pop the timeline out into a draggable window (or dock it back).
function AnimEditorPanel:onPopTimeline()
    if AE.timelineWin then self:dockTimeline() else self:popOutTimeline() end
end

function AnimEditorPanel:popOutTimeline()
    local px = (AE.hub and AE.hub:getX() + AE.hub:getWidth() + 8) or 120
    local py = (AE.hub and AE.hub:getY() + 60) or 120
    AE.timelineWin = TimelineWindow:new(px, py)
    AE.timelineWin:initialise(); AE.timelineWin:addToUIManager()
    AE.timelineWin:addChild(self.timeHost)          -- re-parents (auto-detaches from the editor)
    local pad = AnimForge.AnimForgeTheme.sp.m
    self.timeHost:setX(pad); self.timeHost:setY(AE.timelineWin:titleBarHeight() + 6)
    self:layoutTimeline(TIMELINE_POP_W - pad * 2)
    self.popBtn:setTitle("Dock")
end

function AnimEditorPanel:dockTimeline()
    local pad = AnimForge.AnimForgeTheme.sp.m
    self:addChild(self.timeHost)                    -- re-parents back into the editor
    self.timeHost.tab = "pose"
    self.timeHost:setX(pad); self.timeHost:setY(self.yTime + 18)
    self:layoutTimeline(self.width - pad * 2)
    self.popBtn:setTitle("Pop out")
    if AE.timelineWin then AE.timelineWin:removeFromUIManager(); AE.timelineWin = nil end
    self:showTab(self.activeTab)                    -- re-apply tab visibility to the docked host
end

-- ================================ reload attachment-marker bar + editor window ===============
-- A colour-coded timeline of the reload's gwSetProp/gwPartToHand/gwPartToGun markers. Drag a tick
-- to retime it, right-click to delete, click empty space to scrub. The live character shows the
-- resulting off-hand prop + ramrod state at the playhead (rfxApplyStateAt).
local RFX_EVENTS = { "gwSetProp", "gwSetHandProp", "gwPartToHand", "gwPartToGun" }
local RFX_EVENT_LABEL = {
    gwSetProp = "Set off-hand prop",
    gwSetHandProp = "Set right-hand prop",
    gwPartToHand = "Part: gun -> hand",
    gwPartToGun = "Part: hand -> gun",
}

---@return number, number, number
local function rfxColor(m)
    if m.event == "gwPartToHand" then return 1.0, 0.6, 0.15       -- orange: part off gun
    elseif m.event == "gwPartToGun" then return 0.4, 0.9, 0.45    -- green: part back on gun
    elseif m.event == "gwSetHandProp" then return 0.85, 0.5, 1.0  -- purple: right-hand prop
    else return 0.35, 0.8, 1.0 end                                -- cyan: off-hand prop
end

---@nodiscard
---@return string
local function rfxShortLabel(m)
    local v = m.value or ""
    if m.event == "gwPartToHand" then return "-> hand"
    elseif m.event == "gwPartToGun" then return "-> gun"
    elseif v == "" then return "clear"
    else return (v:gsub("^.-%.", "")) .. (m.event == "gwSetHandProp" and " (hand)" or "") end
end

MarkerBar = ISUIElement:derive("MarkerBar")

function MarkerBar:new(x, y, w, h)
    local o = ISUIElement:new(x, y, w, h)
    setmetatable(o, self); self.__index = self
    o.dragM = nil
    return o
end

function MarkerBar:hitMarker(x)
    local best, bm = 8, nil
    for i = 1, #AE.rfx.markers do
        local mx = (AE.rfx.markers[i].timePc or 0) * self.width
        local d = math.abs(x - mx)
        if d < best then best, bm = d, AE.rfx.markers[i] end
    end
    return bm
end

function MarkerBar:reapply()
    AE.rfx.appliedProp = nil
    AE.rfx.appliedHandProp = nil
    AE.rfx.appliedParts = {}
    if AE.rfx.active then rfxApplyStateAt(markerFrac()) end
end

function MarkerBar:seekAndPreview(frac)
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    AE.playing = false
    setClipPaused(true)
    setClipTime(frac * getClipLen())
    self:reapply()
end

function MarkerBar:prerender()
    self:drawRect(0, self.height / 2 - 1, self.width, 2, 0.5, 0.5, 0.5, 0.55)
    local len = getClipLen()
    local now = (len > 0) and (getClipTime() / len) or 0
    self:drawRect(now * self.width - 1, 0, 2, self.height, 0.9, 1, 1, 0.35)
    local hoverX = self:isMouseOver() and self:getMouseX() or -999
    local hotLabel, hotX
    for i = 1, #AE.rfx.markers do
        local m = AE.rfx.markers[i]
        local mx = (m.timePc or 0) * self.width
        local r, g, b = rfxColor(m)
        local hot = (self.dragM == m) or (math.abs(hoverX - mx) <= 8)
        local s = hot and 9 or 7
        self:drawRect(mx - s / 2, 0, s, self.height, hot and 1.0 or 0.85, r, g, b)
        self:drawRectBorder(mx - s / 2, 0, s, self.height, 0.8, 0, 0, 0)
        if hot then
            hotLabel = rfxShortLabel(m) .. "  " .. string.format("%d%%", math.floor((m.timePc or 0) * 100 + 0.5))
            hotX = mx
        end
    end
    if hotLabel then self:drawTextCentre(hotLabel, hotX, self.height + 1, 1, 1, 0.85, 1, UIFont.Small) end
end

function MarkerBar:onMouseDown(x, y)
    local m = self:hitMarker(x)
    if m then
        self.dragM = m
        AE.rfx.marker = m
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
    self.dragM.timePc = frac
    self:seekAndPreview(frac)
end

function MarkerBar:onMouseUp(x, y)
    self.dragM = nil
    self:setCapture(false)
end
MarkerBar.onMouseUpOutside = MarkerBar.onMouseUp
MarkerBar.onMouseMoveOutside = MarkerBar.onMouseMove

function MarkerBar:onRightMouseDown(x, y)
    local m = self:hitMarker(x)
    if m then
        for i = #AE.rfx.markers, 1, -1 do
            if AE.rfx.markers[i] == m then table.remove(AE.rfx.markers, i); break end
        end
        self:reapply()
    end
    return true
end

-- The self-contained "Reload Attachments" editor: transport + the marker bar + an add row + save.
-- Opened when a reload is picked from the hub task; closing it ends the preview (restores the gun).
ReloadFxWindow = ISCollapsableWindow:derive("ReloadFxWindow")

function ReloadFxWindow:new(x, y)
    local o = ISCollapsableWindow.new(self, x or 200, y or 110, 470, 232)
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
    self.infoLbl = ISLabel:new(pad, y, 16, tostring(AE.rfx.animId) .. "   (" .. tostring(AE.rfx.clip) .. ")",
        0.85, 0.9, 1, 1, UIFont.Small, true)
    self.infoLbl:initialise(); self:addChild(self.infoLbl)
    self.playBtn = ISButton:new(w - pad - 64, y - 2, 64, 22, "Play", self, ReloadFxWindow.onPlayPause)
    self.playBtn:initialise(); self:addChild(self.playBtn); if T then T.styleGhost(self.playBtn) end
    y = y + 26

    self.scrub = ISSliderPanel:new(pad, y, barW, 18, self, ReloadFxWindow.onScrub)
    self.scrub:initialise(); self:addChild(self.scrub)
    self.scrub:setDoButtons(false); self.scrub:setValues(0, 1, 0.001, 0.05, true); self.scrub:setCurrentValue(0, true)
    y = y + 22

    self.bar = MarkerBar:new(pad, y, barW, 16)
    self.bar:initialise(); self:addChild(self.bar)
    AE.rfx.bar = self.bar
    y = y + 32

    self.nowLbl = ISLabel:new(pad, y, 16, "", 0.7, 0.95, 0.75, 1, UIFont.Small, true)
    self.nowLbl:initialise(); self:addChild(self.nowLbl)
    y = y + 24

    self.evCombo = ISComboBox:new(pad, y, 150, 22, self, nil)
    self.evCombo:initialise(); self:addChild(self.evCombo)
    for i = 1, #RFX_EVENTS do self.evCombo:addOptionWithData(RFX_EVENT_LABEL[RFX_EVENTS[i]], RFX_EVENTS[i]) end
    self.itemCombo = ISComboBox:new(pad + 156, y, 176, 22, self, nil)
    self.itemCombo:initialise(); self:addChild(self.itemCombo)
    self.itemCombo:addOptionWithData("(empty / clear hand)", "")
    for i = 1, #AE.rfx.propItems do
        self.itemCombo:addOptionWithData((AE.rfx.propItems[i]:gsub("^.-%.", "")), AE.rfx.propItems[i])
    end
    self.addBtn = ISButton:new(pad + 338, y, w - pad - (pad + 338), 22, "Add here", self, ReloadFxWindow.onAdd)
    self.addBtn:initialise(); self:addChild(self.addBtn); if T then T.styleGhost(self.addBtn) end
    y = y + 30

    self.saveBtn = ISButton:new(pad, y, 150, 24, "Save to mod", self, ReloadFxWindow.onSave)
    self.saveBtn:initialise(); self:addChild(self.saveBtn); if T then T.styleGhost(self.saveBtn) end
    self.hintLbl = ISLabel:new(pad + 158, y + 5, 16, "drag ticks to retime - right-click deletes",
        0.7, 0.72, 0.82, 1, UIFont.Small, true)
    self.hintLbl:initialise(); self:addChild(self.hintLbl)
end

function ReloadFxWindow:onToggleCollapse()
    self:setCollapsed(not self.uiCollapsed)
end

-- Collapse to just the title bar so the reloading character stays fully visible while retiming.
function ReloadFxWindow:setCollapsed(c)
    if c == self.uiCollapsed then return end
    self.uiCollapsed = c
    local th = self:titleBarHeight()
    local kids = { self.infoLbl, self.playBtn, self.scrub, self.bar, self.nowLbl,
                   self.evCombo, self.itemCombo, self.addBtn, self.saveBtn, self.hintLbl }
    if c then
        self.fullHeight = self.height
        for i = 1, #kids do if kids[i] then kids[i]:setVisible(false) end end
        self:setHeight(th)
        if self.minBtn then self.minBtn:setTitle("+") end
    else
        self:setHeight(self.fullHeight or 232)
        for i = 1, #kids do if kids[i] then kids[i]:setVisible(true) end end
        if self.minBtn then self.minBtn:setTitle("-") end
    end
end

function ReloadFxWindow:onScrub(value)
    if self.bar then self.bar:seekAndPreview(value) end
end

function ReloadFxWindow:onPlayPause()
    AE.playing = not AE.playing
    setClipPaused(not AE.playing)
    self.playBtn:setTitle(AE.playing and "Pause" or "Play")
end

function ReloadFxWindow:onAdd()
    local ev = self.evCombo:getOptionData(self.evCombo.selected) or "gwSetProp"
    local val = self.itemCombo:getOptionData(self.itemCombo.selected) or ""
    AE.rfx.markers[#AE.rfx.markers + 1] = { event = ev, timePc = markerFrac(), value = val }
    if self.bar then self.bar:reapply() end
end

-- Save the marker timings into the mod. Writes the reloadMarkers spec (anim_edit.json) plus a small
-- bake request; the AgentBridge host watcher runs pz_anim_bake automatically and writes back a result
-- we poll for below. No manual bake step -- a restart then shows the retimed reload.
function ReloadFxWindow:onSave()
    if not rfxSave("") then return end
    -- Refresh the cached reload list with the markers we just saved, so closing + reopening the editor
    -- shows the saved state -- the bake edits the mod XML but does NOT rewrite the pz_anim_list_reloads
    -- cache (reload_markers.json) that the picker + rfxLoad read from, which is why reopening showed
    -- the pre-save markers.
    rfxUpdateCachedMarkers()
    local ts = getTimestampMs()
    local writer = getFileWriter("AgentBridge/rfx_bake_request.json", true, false)
    if writer then
        writer:write(AnimForge.JSON.encode({ ts = ts, nodeFile = AE.rfx.nodeFile, animId = AE.rfx.animId }))
        writer:close()
        self.bakeTs = ts
        self.bakePoll = 0
        self.hintLbl:setName("Saving into the mod (auto-baking)...")
    else
        self.hintLbl:setName("saved -> run pz_anim_bake, then restart to see it")
    end
end

function ReloadFxWindow:prerender()
    ISCollapsableWindow.prerender(self)
    if self.uiCollapsed then return end   -- minimized: only the title bar draws
    -- poll for the host auto-bake result (written by the AgentBridge watcher after Save to mod)
    if self.bakeTs then
        self.bakePoll = (self.bakePoll or 0) + 1
        if self.bakePoll >= 15 then
            self.bakePoll = 0
            local ok, r = pcall(readJsonFile, "AgentBridge/rfx_bake_result.json")
            if ok and r and r.ts == self.bakeTs then
                self.bakeTs = nil
                if r.ok and r.liveReload then
                    self.hintLbl:setName("Baked + hot-reloaded live -- do another reload to see the new timing.")
                elseif r.ok then
                    self.hintLbl:setName("Baked into the mod. Restart the game to see the new timing.")
                else
                    self.hintLbl:setName("Bake FAILED: " .. tostring(r.error or "unknown"))
                end
            end
        end
    end
    local len = getClipLen()
    if len > 0 and self.scrub and not (self.bar and self.bar.dragM) then
        self.scrub:setCurrentValue(getClipTime() / len, true)
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
    rfxStopPreview()
    self:removeFromUIManager()
end

-- Open the reload attachment editor for a discovered reload (loads it + starts the live preview).
local function openReloadFx(reload)
    if AE.rfx.window then AE.rfx.window:close() end
    if not rfxLoad(reload) then return false end
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
-- apply path (also used by the load-weapon bridge op).
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
    self.status:setName("saved (single .x)")
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
end

-- ------------------------------------------------------------ bone overlay --
-- Full-screen overlay that draws a clickable node on each bone (click to select,
-- replacing the dropdown) and a drag gizmo on the selected bone. Each bone's world
-- position comes from the patched AnimationPlayer.getBoneGizmoWorld and is projected
-- to screen pixels with the engine's own global isoToScreenX/Y, so the nodes land
-- exactly where the character renders. Dragging an axis handle drives the SAME
-- ensureDelta/setRot/setPos path the sliders use, so the two stay in sync.
AnimEditorOverlay = ISUIElement:derive("AnimEditorOverlay")

local NODE_HIT, HANDLE_HIT, RING_HIT = 9, 10, 12
local DRAG_THRESH2 = 25  -- (px^2) moving past this between down and up = a drag, not a click
local RING_SEGS = 96   -- dense enough that the per-point square dots overlap into a solid ring
local AXIS_COL = { { 1.0, 0.35, 0.35 }, { 0.4, 1.0, 0.45 }, { 0.45, 0.6, 1.0 } } -- X red, Y green, Z blue

-- Bone nodes are colored by LIMB, so the three bones of one limb share a colour.
local LIMB_COLS = {
    leftArm  = { 1.00, 0.30, 0.30 }, -- red
    rightArm = { 0.35, 0.55, 1.00 }, -- blue
    torso    = { 0.40, 0.90, 0.45 }, -- green
    head     = { 1.00, 0.75, 0.20 }, -- amber
    prop     = { 0.85, 0.40, 0.95 }, -- magenta (the gun)
    other    = { 0.70, 0.70, 0.75 }, -- grey
}
local function limbColor(name)
    if name:find("_L_", 1, true) then return LIMB_COLS.leftArm
    elseif name:find("_R_", 1, true) then return LIMB_COLS.rightArm
    elseif name:find("Prop", 1, true) then return LIMB_COLS.prop
    elseif name:find("Spine", 1, true) or name:find("Pelvis", 1, true) then return LIMB_COLS.torso
    elseif name:find("Neck", 1, true) or name:find("Head", 1, true) then return LIMB_COLS.head
    else return LIMB_COLS.other end
end

-- Iso "nearness": larger = closer to the camera (the +(3,3,1) view ray, the world
-- direction that maps to a single screen pixel). Used to dim the far half of each
-- rotation ring, like the attachment editor's gizmo.
local function nearness(x, y, z) return 3 * (x + y) + z end

-- Build the 3 rotation-ring screen polylines from the bone origin + axis tips (all
-- world coords, as returned by getBoneGizmoWorld). The ring for axis i lies in the
-- plane of the OTHER two axes (radius = axis length); a model-space circle projects
-- to the correct on-screen ellipse this way. Each point carries its depth vs origin.
local function buildRings(pi, o, ax, ay, az)
    local ox, oy, oz = o[1], o[2], o[3]
    local n0 = nearness(ox, oy, oz)
    local A = { ax[1] - ox, ax[2] - oy, ax[3] - oz }
    local B = { ay[1] - ox, ay[2] - oy, ay[3] - oz }
    local C = { az[1] - ox, az[2] - oy, az[3] - oz }
    local planes = { { B, C }, { C, A }, { A, B } } -- axis -> its two in-plane vectors
    local rings = {}
    for axis = 1, 3 do
        local u, v = planes[axis][1], planes[axis][2]
        local pts = {}
        for i = 0, RING_SEGS do
            local t = i / RING_SEGS * 2 * math.pi
            local ct, st = math.cos(t), math.sin(t)
            local wx = ox + ct * u[1] + st * v[1]
            local wy = oy + ct * u[2] + st * v[2]
            local wz = oz + ct * u[3] + st * v[3]
            pts[i + 1] = {
                x = isoToScreenX(pi, wx, wy, wz),
                y = isoToScreenY(pi, wx, wy, wz),
                near = nearness(wx, wy, wz) - n0,
            }
        end
        rings[axis] = pts
    end
    return rings
end

function AnimEditorOverlay:new()
    local o = ISUIElement:new(0, 0, getCore():getScreenWidth(), getCore():getScreenHeight())
    setmetatable(o, self); self.__index = self
    o.nodes = {}     -- { { name, sx, sy }, ... }
    o.gizmo = nil    -- { ox, oy, tips = { {x,y}, {x,y}, {x,y} } } for the selected bone
    o.drag = nil     -- { kind = "rot"|"pos", axis = 1..3, lastX, lastY }
    return o
end

-- Recompute node + gizmo screen positions for this frame.
function AnimEditorOverlay:refresh()
    self.nodes = {}
    self.gizmo = nil
    local p = getPlayer(); if not p then return end
    local ap = p:getAnimationPlayer(); if not ap then return end
    local pi = p:getPlayerNum()
    for _, name in ipairs(AE.bones) do
        local idx = ap:getSkinningBoneIndex(name, -1)
        if idx and idx >= 0 then
            local g
            local ok = pcall(function() g = ap:getBoneGizmoWorld(idx, AE.axisLen) end)
            if ok and g and g:size() >= 12 then
                local ox = isoToScreenX(pi, g:get(0), g:get(1), g:get(2))
                local oy = isoToScreenY(pi, g:get(0), g:get(1), g:get(2))
                table.insert(self.nodes, { name = name, sx = ox, sy = oy })
                if name == AE.bone then
                    local axw = { g:get(3), g:get(4), g:get(5) }   -- X axis tip (world)
                    local ayw = { g:get(6), g:get(7), g:get(8) }   -- Y axis tip (world)
                    local azw = { g:get(9), g:get(10), g:get(11) }  -- Z axis tip (world)
                    local tips = {
                        { x = isoToScreenX(pi, axw[1], axw[2], axw[3]), y = isoToScreenY(pi, axw[1], axw[2], axw[3]) },
                        { x = isoToScreenX(pi, ayw[1], ayw[2], ayw[3]), y = isoToScreenY(pi, ayw[1], ayw[2], ayw[3]) },
                        { x = isoToScreenX(pi, azw[1], azw[2], azw[3]), y = isoToScreenY(pi, azw[1], azw[2], azw[3]) },
                    }
                    self.gizmo = { ox = ox, oy = oy, tips = tips,
                        rings = buildRings(pi, { g:get(0), g:get(1), g:get(2) }, axw, ayw, azw) }
                end
            end
        end
    end
end

-- Solid thick line of width `w` px: a dense run of OPAQUE filled squares along the
-- segment (overlapping rects can't gap, unlike drawLine2's thin diagonals). Alpha is
-- forced to 1 so overlaps don't blend; pass dimming via the colour.
-- A thick line as ONE perpendicular quad: uniform thickness in any direction, uniform
-- opacity (single draw, no overlap), gap-free. drawPolygon(nil,...) draws solid colour.
-- (The engine's drawLine/renderline "thickness" is a fixed diagonal offset, so it gives
-- inconsistent/thin lines depending on angle -- hence rolling our own.)
local function quadLine(self, x0, y0, x1, y1, w, a, r, g, b)
    local dx, dy = x1 - x0, y1 - y0
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.001 then return end
    local hx, hy = -dy / len * (w * 0.5), dx / len * (w * 0.5)   -- perpendicular half-width
    self:drawPolygon(nil,
        x0 + hx, y0 + hy, x1 + hx, y1 + hy,
        x1 - hx, y1 - hy, x0 - hx, y0 - hy,
        r, g, b, a)
end

-- Lighten a colour channel toward white by t (0..1).
local function lighten(v, t) return v + (1 - v) * t end

-- Rotation gizmo: 3 thick colored rings around the bone (one per axis), the far
-- half dimmed for depth, and the hovered/dragged ring lit up (brighter + thicker)
-- -- the attachment editor's look, reproduced over the live iso view.
-- Rotation gizmo: 3 colored rings. Each point is offset perpendicular to the local
-- tangent into inner/outer rim vertices, so consecutive segment-quads SHARE an exact
-- edge -- a seamless band with controllable thickness (AE.gizmoThick) and opacity
-- (AE.gizmoAlpha), no gaps and no double-blend mottling. Far half dimmed by colour;
-- hovered/dragged ring lit up (brighter + thicker).
function AnimEditorOverlay:drawRings(gz)
    local active = (self.drag and self.drag.axis) or self.hoverAxis
    local baseW, a = AE.gizmoThick, AE.gizmoAlpha
    for axis = 1, 3 do
        local c = AXIS_COL[axis]
        local ring = gz.rings[axis]
        local n = #ring
        local hot = (axis == active)
        local hw = (hot and (baseW + 3) or baseW) * 0.5
        -- rim vertices (the ring is closed: point n == point 1, so wrap the tangent)
        local ox, oy, ix, iy = {}, {}, {}, {}
        for i = 1, n do
            local prev = ring[i == 1 and n - 1 or i - 1]
            local nxt = ring[i == n and 2 or i + 1]
            local tx, ty = nxt.x - prev.x, nxt.y - prev.y
            local L = math.sqrt(tx * tx + ty * ty); if L < 0.001 then L = 1 end
            local px, py = -ty / L * hw, tx / L * hw
            ox[i], oy[i], ix[i], iy[i] = ring[i].x + px, ring[i].y + py, ring[i].x - px, ring[i].y - py
        end
        for i = 1, n - 1 do
            local front = (ring[i].near + ring[i + 1].near) >= 0
            local mul, tint
            if front then mul, tint = 1.0, (hot and 0.45 or 0.0)
            else mul, tint = (hot and 0.7 or 0.5), 0.0 end
            self:drawPolygon(nil, ox[i], oy[i], ox[i + 1], oy[i + 1], ix[i + 1], iy[i + 1], ix[i], iy[i],
                lighten(c[1] * mul, tint), lighten(c[2] * mul, tint), lighten(c[3] * mul, tint), a)
        end
    end
end

-- Translation gizmo: 3 colored axis arrows (single thick quad each, gap-free), with
-- a grab handle at each tip. The hovered/dragged axis lights up like the rings do.
function AnimEditorOverlay:drawArrows(gz)
    local active = (self.drag and self.drag.axis) or self.hoverAxis
    local baseW, a = AE.gizmoThick, AE.gizmoAlpha
    for axis = 1, 3 do
        local c = AXIS_COL[axis]
        local t = gz.tips[axis]
        local hot = (axis == active)
        local tint = hot and 0.45 or 0.0
        local r, g, b = lighten(c[1], tint), lighten(c[2], tint), lighten(c[3], tint)
        quadLine(self, gz.ox, gz.oy, t.x, t.y, hot and (baseW + 3) or baseW, a, r, g, b)
        local s = hot and (baseW + 8) or (baseW + 5)
        self:drawRect(t.x - s / 2, t.y - s / 2, s, s, a, r, g, b)
        self:drawRectBorder(t.x - s / 2, t.y - s / 2, s, s, a, 0, 0, 0)
    end
end

-- Drive the live override from the keyframe timeline at the current clip time, so
-- scrubbing/playing previews the interpolated pose. Clears stale overrides first so
-- switching clips or removing keyframes returns bones to their natural pose.
function AnimEditorOverlay:applyKeyframes()
    local ap = animPlayer(); if not ap then return end
    pcall(function() ap:clearBoneRotationOverrides() end)
    local byClip = AE.keyframes[AE.clip]
    if not byClip then return end
    local t = getClipTime()
    for bone, list in pairs(byClip) do
        local v = evalKf(list, t)
        if v then
            local d = ensureDelta(bone)
            d.rot[1], d.rot[2], d.rot[3] = v.rot[1], v.rot[2], v.rot[3]
            d.pos[1], d.pos[2], d.pos[3] = v.pos[1], v.pos[2], v.pos[3]
            pcall(function()
                ap:setBoneRotationOverride(bone, v.rot[1], v.rot[2], v.rot[3])
                ap:setBonePositionOverride(bone, v.pos[1], v.pos[2], v.pos[3])
            end)
        end
    end
    -- reflect the selected bone's current-time pose on the sliders
    if AE.panel and byClip[AE.bone] then AE.panel:syncSliders() end
end

function AnimEditorOverlay:prerender()
    self:applyKeyframes()   -- runs regardless of showNodes, so the preview always follows
    if not AE.showNodes or AE.poseActive == false then
        self.nodes = {}; self.gizmo = nil   -- drop stale hit targets on non-posing screens
        return
    end
    self:refresh()
    -- hover highlight: rings in rotate mode, arrows in translate mode
    self.hoverAxis = nil
    if self.gizmo and not self.drag then
        if AE.gizmoMode == "rot" then
            self.hoverAxis = self:pickRing(getMouseX(), getMouseY())
        else
            self.hoverAxis = self:pickArrow(getMouseX(), getMouseY())
        end
    end
    -- Gizmo first, so the bone nodes always draw ON TOP of the rings/arrows.
    local gz = self.gizmo
    if gz then
        if AE.gizmoMode == "rot" and gz.rings then
            self:drawRings(gz)
        else
            self:drawArrows(gz)
        end
        self:drawRect(gz.ox - 2, gz.oy - 2, 4, 4, 1, 1, 1, 1)
    end
    -- Bone nodes on top.
    for _, n in ipairs(self.nodes) do
        local sel = (n.name == AE.bone)
        local c = limbColor(n.name)
        local s = sel and 12 or 8
        self:drawRect(n.sx - s / 2, n.sy - s / 2, s, s, sel and 1.0 or 0.85, c[1], c[2], c[3])
        if sel then -- selected: keep the limb colour, mark it with a white outline
            self:drawRectBorder(n.sx - s / 2, n.sy - s / 2, s, s, 1, 1, 1, 1)
            self:drawRectBorder(n.sx - s / 2 - 1, n.sy - s / 2 - 1, s + 2, s + 2, 1, 1, 1, 1)
        else
            self:drawRectBorder(n.sx - s / 2, n.sy - s / 2, s, s, 1, 0, 0, 0)
        end
    end
end

local function dist2(x0, y0, x1, y1)
    local dx, dy = x1 - x0, y1 - y0
    return dx * dx + dy * dy
end

-- Squared distance from (px,py) to the segment (x1,y1)-(x2,y2).
local function distToSeg(px, py, x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    local l2 = dx * dx + dy * dy
    if l2 < 1e-6 then return dist2(px, py, x1, y1) end
    local t = ((px - x1) * dx + (py - y1) * dy) / l2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return dist2(px, py, x1 + t * dx, y1 + t * dy)
end

-- Which rotation ring (axis 1..3) is under (x,y), or nil. Screen-space nearest
-- segment, like the engine's hitTestCircle.
function AnimEditorOverlay:pickRing(x, y)
    local gz = self.gizmo
    if not gz or not gz.rings then return nil end
    local best, bestAxis = RING_HIT * RING_HIT, nil
    for axis = 1, 3 do
        local ring = gz.rings[axis]
        for i = 1, #ring - 1 do
            local d = distToSeg(x, y, ring[i].x, ring[i].y, ring[i + 1].x, ring[i + 1].y)
            if d < best then best, bestAxis = d, axis end
        end
    end
    return bestAxis
end

-- Which translation arrow (axis 1..3) is under (x,y), or nil. Grabbable along the
-- whole arrow (origin->tip), like the rings, not just the tip handle.
function AnimEditorOverlay:pickArrow(x, y)
    local gz = self.gizmo
    if not gz then return nil end
    local best, bestAxis = HANDLE_HIT * HANDLE_HIT, nil
    for axis = 1, 3 do
        local t = gz.tips[axis]
        local d = distToSeg(x, y, gz.ox, gz.oy, t.x, t.y)
        if d < best then best, bestAxis = d, axis end
    end
    return bestAxis
end

function AnimEditorOverlay:hitNode(x, y)
    local best, bd = nil, NODE_HIT * NODE_HIT
    for _, n in ipairs(self.nodes) do
        local d = dist2(x, y, n.sx, n.sy)
        if d <= bd then best, bd = n, d end
    end
    return best
end

function AnimEditorOverlay:onMouseDown(x, y)
    -- Defer the decision: record what's under the cursor and capture. A quick release
    -- selects the node; moving past the threshold starts the gizmo drag. So a fast
    -- click where a ring/arrow overlaps a node selects the node, while a click-drag
    -- always works the gizmo.
    local axis = (AE.gizmoMode == "rot") and self:pickRing(x, y) or self:pickArrow(x, y)
    local node = self:hitNode(x, y)
    if axis or node then
        self.pending = { x = x, y = y, curX = x, curY = y, axis = axis, node = node, moved = false }
        self:setCapture(true)
        return true
    end
    return false  -- empty space: let the click reach the world
end

function AnimEditorOverlay:onMouseMove(dx, dy)
    -- Active gizmo drag.
    local d = self.drag
    if d and self.gizmo then
        local gz = self.gizmo
        local nx, ny = d.curX + dx, d.curY + dy
        local v = ensureDelta(AE.bone)
        if d.kind == "pos" then
            local t = gz.tips[d.axis]
            local ax, ay = t.x - gz.ox, t.y - gz.oy
            local len = math.sqrt(ax * ax + ay * ay)
            if len > 0.001 then
                local move = (dx * ax + dy * ay) / len
                local cur = v.pos[d.axis] + move * AE.posSens
                if cur > 0.3 then cur = 0.3 elseif cur < -0.3 then cur = -0.3 end
                v.pos[d.axis] = cur
                setPos(AE.bone, v.pos[1], v.pos[2], v.pos[3])
            end
        else
            local a0 = math.atan2(d.curY - gz.oy, d.curX - gz.ox)
            local a1 = math.atan2(ny - gz.oy, nx - gz.ox)
            local da = a1 - a0
            if da > math.pi then da = da - 2 * math.pi elseif da < -math.pi then da = da + 2 * math.pi end
            local cur = v.rot[d.axis] + da * 180 / math.pi
            if cur > 90 then cur = 90 elseif cur < -90 then cur = -90 end
            v.rot[d.axis] = cur
            setRot(AE.bone, v.rot[1], v.rot[2], v.rot[3])
        end
        d.curX, d.curY = nx, ny
        if AE.panel then AE.panel:syncSliders() end
        return
    end
    -- Pending gesture: promote to a gizmo drag once the mouse moves past the threshold.
    local pend = self.pending
    if pend then
        pend.curX = pend.curX + dx
        pend.curY = pend.curY + dy
        if not pend.moved and dist2(pend.x, pend.y, pend.curX, pend.curY) > DRAG_THRESH2 then
            pend.moved = true
            if pend.axis then
                self.drag = { kind = AE.gizmoMode, axis = pend.axis, curX = pend.curX, curY = pend.curY }
                self.pending = nil
            end
        end
    end
end

function AnimEditorOverlay:onMouseUp(x, y)
    if self.drag then
        self.drag = nil
    elseif self.pending then
        -- quick click (never crossed the drag threshold): select the node, if one was under it
        if not self.pending.moved and self.pending.node then
            AE.bone = self.pending.node.name
            if AE.panel then
                AE.panel.boneCombo:select(AE.bone)
                AE.panel:syncSliders()
                AE.panel.status:setName("bone: " .. AE.bone)
            end
        end
        self.pending = nil
    end
    self:setCapture(false)
end
AnimEditorOverlay.onMouseUpOutside = AnimEditorOverlay.onMouseUp
AnimEditorOverlay.onMouseMoveOutside = AnimEditorOverlay.onMouseMove
function AnimEditorOverlay:onFocus() end  -- don't bring the overlay above the panel

-- =================================================================== browser ==
-- A separate window for browsing animations as a scrollable grid of live 3D
-- thumbnails (each frozen on a clip's first frame; hover plays it, click loads it
-- into the editor). Weapon tabs + a search box filter the list. Only the visible
-- grid cells get a live model (a fixed pool reused on scroll), so render cost is
-- bounded to cols*rows regardless of how many clips the tab holds.

-- Short label for a clip (drop the "Bob_" prefix the engine uses on every clip).
local function clipLabel(name) return (name:gsub("^Bob_", "")) end

-- Short tab label: "Bat (2H blunt)" -> "Bat".
local function shortTab(name) return (name:gsub("%s*%b()", "")) end

-- Clip list for a tab. Weapon sets have grip+all (the "all clips" toggle picks);
-- the vanilla theme tabs + "All" have only an `all` list (every clip in that bucket).
local function browserClips(tab, useAll)
    -- Mod clips come from the dynamic discovery list, not the static vanilla categories.
    if tab == "Mods" then return AE.modClipNames or {} end
    local cats = AnimForge.AnimCategories
    local c = cats and cats[tab]
    if not c then return {} end
    if c.grip and not useAll then return c.grip end
    return c.all or {}
end

-- Load an arbitrary clip into the editor (force it on the live player + sync the
-- panel), so picking a thumbnail behaves exactly like choosing it in the dropdown.
-- Loads PAUSED at frame 0 so the live character holds the same pose as the clicked
-- thumbnail (and the scrub bar sits still instead of looping while you browse).
local function selectClipInEditor(clip)
    if not clip then return end
    AE.clip = clip
    forceClip(clip)
    AE.playing = false
    setClipPaused(true)
    setClipTime(0)
    if AE.panel then
        AE.panel:resetScrubDisplay()
        if AE.panel.playBtn then AE.panel.playBtn:setTitle("Play") end
        AE.panel.status:setName("clip: " .. clip)
    end
end

-- ------------------------------------------------------- Gunworks reload ----
-- A Gunworks-reload project drives the SAME per-clip editing pipeline as a grip set,
-- but its "clips" are the reload STAGES (load / loadShort / rack / unload), each a
-- chosen vanilla base clip the user tweaks. The helpers below seed the stages from an
-- archetype, let the user edit each stage's clip, and Save a `gunworks` block to
-- anim_edit.json that tools/pz-anim-forge `wire-gunworks` turns into a drop-in reload
-- pack (renamed .x clips + gated AnimSet nodes + RegisterReloadAnims.lua). The block
-- shape must match gunworks.py's reader.
local GW = {}

-- Per-stage edit state. AE persists across a Lua reload, so backfill the gunworks sub-state.
AE.gw = AE.gw or {}
AE.gw.stages = AE.gw.stages or {}   -- [stageKey] = { baseClip, deltas, duration, blendTime, done, keyframes, events }
AE.gw.config = AE.gw.config or {
    animId = "", fullTypes = "", style = "none", propItem = "",
    spriteLoaded = "", spriteUnloaded = "", build = "42.13",
    luaNamespace = "", mod = "", shortRackAfterInsert = false,
}

-- Deep-copy a deltas map (boneName -> {rot={x,y,z}, pos={x,y,z}}) so a stage keeps its
-- own pose independent of the live AE.deltas the editor mutates.
---@param src table|nil
---@return table
local function gwCopyDeltas(src)
    local out = {}
    for bone, d in pairs(src or {}) do
        local rot = d.rot or {}
        local pos = d.pos or {}
        out[bone] = {
            rot = { rot[1] or 0, rot[2] or 0, rot[3] or 0 },
            pos = { pos[1] or 0, pos[2] or 0, pos[3] or 0 },
        }
    end
    return out
end

-- Split a comma/space separated list into a clean array (drops blanks + inner spaces).
---@param s string|nil
---@return string[]
local function gwSplitList(s)
    local out = {}
    if not s or s == "" then return out end
    local parts = luautils.split(s, ",")
    for i = 1, #parts do
        local token = parts[i]:gsub("%s+", "")
        if token ~= "" then out[#out + 1] = token end
    end
    return out
end

-- Copy the live editor pose (AE.deltas + the active clip's keyframes) into the active
-- stage, so switching stages or saving never loses the current stage's edits.
function GW.captureActiveStage()
    local key = AE.gw.activeStage
    if not key then return end
    local stage = AE.gw.stages[key]
    if not stage then return end
    stage.deltas = gwCopyDeltas(AE.deltas)
    if stage.baseClip and AE.keyframes[stage.baseClip] then
        stage.keyframes = AE.keyframes[stage.baseClip]
    end
end

-- Load a stage's base clip into the editor and restore its stored deltas live.
---@param key string
---@return boolean
function GW.loadStage(key)
    local stage = AE.gw.stages[key]
    if not stage or not stage.baseClip then return false end
    GW.captureActiveStage()
    AE.gw.activeStage = key
    AE.deltas = gwCopyDeltas(stage.deltas)
    selectClipInEditor(stage.baseClip)
    for bone in pairs(AE.deltas) do
        applyBone(bone)
    end
    return true
end

-- Seed the stage list + archetype from a reloadArchetypes entry (AnimCategories.lua).
---@param archetypeKey string
---@return boolean
function GW.seedArchetype(archetypeKey)
    local cats = AnimForge.AnimCategories
    local defs = cats and cats.reloadArchetypes
    local def = defs and defs[archetypeKey]
    if not def then return false end
    AE.gw.archetypeKey = archetypeKey
    AE.gw.archetype = def.archetype
    AE.gw.order = def.order
    AE.gw.stages = {}
    for i = 1, #def.order do
        local stageKey = def.order[i]
        local seed = def.stages[stageKey] or {}
        AE.gw.stages[stageKey] = {
            baseClip = seed.baseClip, deltas = {}, done = false,
        }
    end
    AE.gw.config.archetype = def.archetype
    AE.gw.activeStage = def.order[1]
    return true
end

-- Build the `gunworks` block for anim_edit.json (matches gunworks.py's schema).
---@return table
function GW.buildBlock()
    GW.captureActiveStage()
    local cfg = AE.gw.config
    local block = {
        animId = cfg.animId,
        fullTypes = gwSplitList(cfg.fullTypes),
        archetype = AE.gw.archetype,
        build = (cfg.build ~= "" and cfg.build) or "42.13",
    }
    if cfg.style and cfg.style ~= "" then block.style = cfg.style end
    if cfg.luaNamespace and cfg.luaNamespace ~= "" then block.luaNamespace = cfg.luaNamespace end
    if cfg.shortRackAfterInsert then block.shortRackAfterInsert = true end
    if cfg.propItem and cfg.propItem ~= "" then block.prop = { item = cfg.propItem } end
    if cfg.style == "sprite" then
        block.sprite = { loaded = cfg.spriteLoaded, unloaded = cfg.spriteUnloaded }
    end
    local stages = {}
    local order = AE.gw.order or {}
    for i = 1, #order do
        local stageKey = order[i]
        local s = AE.gw.stages[stageKey]
        if s and s.baseClip then
            local entry = { baseClip = s.baseClip, deltas = s.deltas or {} }
            if s.duration then entry.duration = s.duration end
            if s.blendTime then entry.blendTime = s.blendTime end
            if s.events then entry.events = s.events end
            stages[stageKey] = entry
        end
    end
    block.stages = stages
    return block
end

-- Write the gunworks block to anim_edit.json (consumed by `wire-gunworks`).
function GW.saveJson()
    local data = { order = AE.order, mode = AE.mode, gunworks = GW.buildBlock() }
    local writer = getFileWriter("AgentBridge/anim_edit.json", true, false)
    writer:write(AnimForge.JSON.encode(data))
    writer:close()
end

-- Assemble a serializable gunworks project (AnimProjects type="gunworks").
---@param name string
---@return table
function GW.buildProject(name)
    GW.captureActiveStage()
    local cfg = AE.gw.config
    local prop = nil
    if cfg.propItem and cfg.propItem ~= "" then prop = { item = cfg.propItem } end
    local sprite = nil
    if cfg.style == "sprite" then sprite = { loaded = cfg.spriteLoaded, unloaded = cfg.spriteUnloaded } end
    local stages = {}
    local order = AE.gw.order or {}
    for i = 1, #order do
        local stageKey = order[i]
        local s = AE.gw.stages[stageKey]
        if s then
            stages[stageKey] = {
                baseClip = s.baseClip, duration = s.duration, blendTime = s.blendTime,
                done = s.done == true, deltas = s.deltas or {},
                keyframes = s.keyframes, events = s.events,
            }
        end
    end
    return {
        type = "gunworks", name = name, weapon = AE.gw.archetypeKey,
        archetypeKey = AE.gw.archetypeKey, order = order,
        gunworks = {
            animId = cfg.animId, fullTypes = gwSplitList(cfg.fullTypes),
            archetype = AE.gw.archetype, style = cfg.style, prop = prop, sprite = sprite,
            shortRackAfterInsert = cfg.shortRackAfterInsert == true,
            luaNamespace = cfg.luaNamespace, mod = cfg.mod, build = cfg.build,
        },
        stages = stages,
    }
end

-- Restore a saved gunworks project into the live gunworks edit state.
---@param project table
function GW.applyProject(project)
    local cfg = project.gunworks or {}
    AE.gw.archetypeKey = project.archetypeKey or project.weapon
    AE.gw.archetype = cfg.archetype
    AE.gw.order = project.order or {}
    AE.gw.stages = {}
    AE.keyframes = {}
    AE.deltas = {}
    local stages = project.stages or {}
    for i = 1, #AE.gw.order do
        local stageKey = AE.gw.order[i]
        local s = stages[stageKey] or {}
        AE.gw.stages[stageKey] = {
            baseClip = s.baseClip, deltas = gwCopyDeltas(s.deltas), duration = s.duration,
            blendTime = s.blendTime, done = s.done == true, keyframes = s.keyframes, events = s.events,
        }
        if s.baseClip and s.keyframes then AE.keyframes[s.baseClip] = s.keyframes end
    end
    AE.gw.config = {
        animId = cfg.animId or "", fullTypes = table.concat(cfg.fullTypes or {}, ", "),
        style = cfg.style or "none", propItem = (cfg.prop and cfg.prop.item) or "",
        spriteLoaded = (cfg.sprite and cfg.sprite.loaded) or "",
        spriteUnloaded = (cfg.sprite and cfg.sprite.unloaded) or "",
        build = cfg.build or "42.13", luaNamespace = cfg.luaNamespace or "",
        mod = cfg.mod or "", shortRackAfterInsert = cfg.shortRackAfterInsert == true,
    }
    AE.gw.activeStage = AE.gw.order[1]
    AE.project = { name = project.name, slug = project.slug, weapon = AE.gw.archetypeKey, type = "gunworks" }
end

AE.GW = GW   -- expose for the panel (added separately) + bridge handlers

-- -------------------------------------------------------- one grid thumbnail --
-- A live model held on `clipName`'s first frame. Independent AnimationPlayer (so
-- each cell shows a different pose), driven by the UI3DModel.setForcedClip patch.
AnimThumb = ISUI3DModel:derive("AnimThumb")

function AnimThumb:new(x, y, w, h, browser)
    local o = ISUI3DModel.new(self, x, y, w, h)
    o.browser = browser
    o.animateWhilePaused = true   -- keep applying the forced clip even if the game is paused
    o.clipName = nil
    o.bodySet = false
    o.selected = false
    return o
end

-- Give the model a body once its java object exists (deferred from creation).
function AnimThumb:ensureBody()
    if self.bodySet or not self.javaObject then return end
    local p = getSpecificPlayer(0)
    if not p then return end
    self.javaObject:setCharacter(p)
    self.javaObject:setDirection(IsoDirections.SE)
    self.javaObject:setZoom(self.browser and self.browser.zoom or 0)
    self.bodySet = true
end

function AnimThumb:setClip(clip)
    if clip == self.clipName then return end
    self.clipName = clip
    if self.javaObject then self.javaObject:setForcedClip(clip or "") end
end

function AnimThumb:prerender()
    self:ensureBody()
    local hot = self:isMouseOver()
    if self.javaObject then
        -- re-assert the clip (java object may have been created after setClip).
        if self.clipName then self.javaObject:setForcedClip(self.clipName) end
        -- Hover plays the clip; otherwise hold frame 0. The freeze MUST use
        -- setAnimate(false): the engine only advances the player with a non-zero
        -- frame delta while animate=true (AnimatedModel.updateInternal), so an
        -- animate=true "paused" cell still drifts by a variable delta each frame
        -- (visible jitter). animate=false routes through Update(0.0F) = truly frozen.
        self.javaObject:setForcedClipPaused(not hot)
        self.javaObject:setAnimate(hot)
    end
    if hot then
        self:drawRect(0, 0, self.width, self.height, 0.18, 0.4, 0.6, 0.9)
    end
    -- NOT ISUI3DModel.prerender: it force-sets animate=true whenever the game is
    -- unpaused, which would re-introduce the jitter. Do the base draw + our animate.
    ISUIElement.prerender(self)
    local s = self.selected
    self:drawRectBorder(0, 0, self.width, self.height,
        s and 1 or 0.45, s and 0.95 or 0.5, s and 0.5 or 0.55, s and 0.6 or 0.5)
    -- Project checklist badge (top-left): done = green, edited = amber, to-do = hollow.
    local clip = self.clipName
    if clip then
        local bs = 14
        local r, g, b = 0.12, 0.12, 0.14
        if AE.done[clip] then
            r, g, b = 0.25, 0.78, 0.38
        elseif clipEdited(clip) then
            r, g, b = 0.90, 0.66, 0.20
        end
        self:drawRect(4, 4, bs, bs, 0.92, r, g, b)
        self:drawRectBorder(4, 4, bs, bs, 1, 0, 0, 0)
    end
end

-- Click the corner badge toggles done (only with a project active); anywhere
-- else loads the clip into the editor. Never starts the base drag-rotate.
function AnimThumb:onMouseDown(x, y)
    if self.clipName and self.browser then
        if AE.project and x >= 2 and x <= 20 and y >= 2 and y <= 20 then
            setClipDone(self.clipName, not (AE.done[self.clipName] == true))
            self.browser:relayout()
            return true
        end
        self.browser:pick(self.clipName)
    end
    return true
end
function AnimThumb:onMouseUp(x, y) return true end
function AnimThumb:onMouseMove(dx, dy) return true end

-- ---------------------------------------------------------- browser window ----
AnimBrowser = ISCollapsableWindow:derive("AnimBrowser")

function AnimBrowser:new(x, y)
    local cols, rows = 5, 4
    local cellW, modelH, labelH = 92, 100, 14
    local pad = 8
    local cellH = modelH + labelH
    local gridW = cols * cellW
    local w = pad * 2 + gridW + 12          -- +scrollbar gutter
    -- title + project bar + 2 tab rows (weapon sets, vanilla themes) + controls + grid
    local h = 24 + 4 + 26 + 24 + 24 + 26 + rows * cellH + pad
    local o = ISCollapsableWindow.new(self, x, y, w, h)
    o.title = "Animation Browser"
    o.cols, o.rows = cols, rows
    o.cellW, o.cellH, o.modelH = cellW, cellH, modelH
    o.pad, o.gridW = pad, gridW
    -- Restore the last view (tab / search / scroll) so reopening lands where you left.
    o.tab = AE.browserTab or "All"
    o.useAll = AE.useAll
    o.search = AE.browserSearch or ""
    o.scrollRow = AE.browserScrollRow or 0
    o.zoom = AE.browserZoom or 0
    o.clips = {}
    o.pool = {}
    o.shownCount = 0
    o.draggingScroll = false
    o.scrollGrab = 0
    o.resizable = false
    return o
end

function AnimBrowser:createChildren()
    ISCollapsableWindow.createChildren(self)
    self:setResizable(false)
    local th = self:titleBarHeight()
    local pad = self.pad
    local cats = AnimForge.AnimCategories
    self.tabBtns = {}

    -- Project bar: New set / Load / Save + a live progress label. The checklist a
    -- project tracks IS the weapon's grip tab, so creating a set just selects that
    -- tab; per-clip done badges + the X/N count live on the grid below.
    local projY = th + 4
    self.newBtn = ISButton:new(pad, projY, 62, 20, "New set", self, AnimBrowser.onNewSet)
    self.newBtn:initialise(); self:addChild(self.newBtn)
    self.loadBtn = ISButton:new(pad + 66, projY, 50, 20, "Load", self, AnimBrowser.onLoad)
    self.loadBtn:initialise(); self:addChild(self.loadBtn)
    self.saveProjBtn = ISButton:new(pad + 120, projY, 50, 20, "Save", self, AnimBrowser.onSaveProject)
    self.saveProjBtn:initialise(); self:addChild(self.saveProjBtn)
    self.projTextX = pad + 178   -- progress label is drawn in prerender (refreshes live)

    -- Row 1: curated weapon sets. Row 2: every vanilla clip, bucketed by theme
    -- ("All" = the whole library). A tab is just a view; buckets overlap on purpose.
    local function makeTabRow(names, y)
        local tabW = math.floor(self.gridW / math.max(1, #names))
        local tx = pad
        for _, name in ipairs(names) do
            local b = ISButton:new(tx, y, tabW - 2, 20, shortTab(name), self, AnimBrowser.onTab)
            b.tabName = name
            b:initialise(); self:addChild(b)
            self.tabBtns[name] = b
            tx = tx + tabW
        end
    end
    local tabsY = projY + 26
    makeTabRow((cats and cats.order) or {}, tabsY)
    -- Row 2 is the vanilla theme buckets plus a "Mods" tab for discovered mod clips.
    local themeSrc = (cats and cats.themeOrder) or { "All" }
    local themeTabs = {}
    for i = 1, #themeSrc do
        themeTabs[i] = themeSrc[i]
    end
    themeTabs[#themeTabs + 1] = "Mods"
    makeTabRow(themeTabs, tabsY + 24)

    -- search + grip/all toggle (the toggle only affects the weapon-set tabs)
    local ctrlY = tabsY + 48
    self.searchLbl = ISLabel:new(pad, ctrlY, 20, "search", 0.8, 0.85, 1, 1, UIFont.Small, true)
    self.searchLbl:initialise(); self:addChild(self.searchLbl)
    self.searchEntry = ISTextEntryBox:new(self.search or "", pad + 48, ctrlY, 176, 20)
    self.searchEntry:initialise(); self.searchEntry:instantiate(); self:addChild(self.searchEntry)
    self.allTick = ISTickBox:new(pad + 232, ctrlY, 18, 18, "", self, AnimBrowser.onAllTick)
    self.allTick:initialise(); self:addChild(self.allTick)
    self.allTick:addOption("all clips")
    self.allTick:setSelected(1, self.useAll)

    -- reusable thumbnail pool (one per visible cell)
    self.gridY = ctrlY + 26
    for i = 1, self.cols * self.rows do
        local t = AnimThumb:new(0, 0, self.cellW, self.modelH, self)
        t:initialise(); self:addChild(t); t:setVisible(false)
        self.pool[i] = t
    end
    self:refilter()
end

function AnimBrowser:totalRows()
    return math.ceil(#self.clips / self.cols)
end

function AnimBrowser:clampScroll()
    local maxRow = math.max(0, self:totalRows() - self.rows)
    if self.scrollRow > maxRow then self.scrollRow = maxRow end
    if self.scrollRow < 0 then self.scrollRow = 0 end
end

function AnimBrowser:refilter()
    local base = browserClips(self.tab, self.useAll)
    local q = (self.search or ""):lower()
    if q == "" then
        self.clips = base
    else
        local out = {}
        for _, n in ipairs(base) do
            if n:lower():find(q, 1, true) then out[#out + 1] = n end
        end
        self.clips = out
    end
    self:clampScroll()
    self.title = "Animation Browser  (" .. #self.clips .. ")"
    self:relayout()
end

-- Assign the pool to the visible cells; hide the rest.
function AnimBrowser:relayout()
    local pad, cw, ch = self.pad, self.cellW, self.cellH
    local start = self.scrollRow * self.cols
    local shown = 0
    for r = 0, self.rows - 1 do
        for c = 0, self.cols - 1 do
            local cell = r * self.cols + c
            local idx = start + cell + 1
            local t = self.pool[cell + 1]
            if idx <= #self.clips then
                t:setX(pad + c * cw)
                t:setY(self.gridY + r * ch)
                t:setClip(self.clips[idx])
                t.selected = (self.clips[idx] == AE.clip)
                t:setVisible(true)
                shown = shown + 1
            else
                t:setVisible(false)
            end
        end
    end
    self.shownCount = shown
end

-- Names currently shown in the grid (for automation/inspection).
function AnimBrowser:visibleClips()
    local out = {}
    local start = self.scrollRow * self.cols
    for i = 1, self.cols * self.rows do
        local idx = start + i
        if idx <= #self.clips then out[#out + 1] = self.clips[idx] end
    end
    return out
end

function AnimBrowser:pick(clip)
    selectClipInEditor(clip)
    self:relayout()   -- refresh the selection highlight
end

function AnimBrowser:onTab(button)
    self.tab = button.tabName
    self.scrollRow = 0
    self:refilter()
end

function AnimBrowser:onAllTick(index, selected)
    self.useAll = selected and true or false
    self.scrollRow = 0
    self:refilter()
end

-- Push the active project's prefix/mod/tag into the editor panel's fields and
-- force its first clip, so New/Load lands the editor on the new set.
function AnimBrowser:syncPanelFields()
    local panel = AE.panel
    if not panel then return end
    if panel.nameEntry then panel.nameEntry:setText(AE.namePrefix or "") end
    if panel.modEntry then panel.modEntry:setText(AE.mod or "") end
    if panel.tagEntry then panel.tagEntry:setText(AE.tag or "") end
    if panel.applyLoadedClip then panel:applyLoadedClip() end
end

-- Current player's index (context menus are keyed to it), or 0.
---@return integer
local function playerNum()
    local p = getPlayer()
    if not p then return 0 end
    return p:getPlayerNum()
end

-- "New set": pick a weapon category, then start a project for it.
function AnimBrowser:onNewSet(button)
    local menu = ISContextMenu.get(playerNum(), button:getAbsoluteX(), button:getAbsoluteY() + button:getHeight())
    local cats = AnimForge.AnimCategories
    local order = (cats and cats.order) or {}
    for i = 1, #order do
        menu:addOption(order[i], self, AnimBrowser.onPickNewWeapon, order[i])
    end
end

function AnimBrowser:onPickNewWeapon(weapon)
    -- prefix / mod / tag come from the editor panel's fields (fall back to AE).
    local prefix, mod, tag = AE.namePrefix, AE.mod, AE.tag
    local panel = AE.panel
    if panel then
        if panel.nameEntry then prefix = panel.nameEntry:getInternalText() end
        if panel.modEntry then mod = panel.modEntry:getInternalText() end
        if panel.tagEntry then tag = panel.tagEntry:getInternalText() end
    end
    if not prefix or prefix == "" then prefix = weapon .. "Gun" end
    if not newProject(prefix, weapon, prefix, mod, tag, self.useAll) then return end
    self.tab = weapon
    self.scrollRow = 0
    self:refilter()
    self:syncPanelFields()
end

-- "Load": list saved projects (load on click) + a Delete submenu.
function AnimBrowser:onLoad(button)
    local menu = ISContextMenu.get(playerNum(), button:getAbsoluteX(), button:getAbsoluteY() + button:getHeight())
    local rows = AnimForge.AnimProjects.list()
    if #rows == 0 then
        menu:addOption("(no saved sets)", self, nil)
        return
    end
    for i = 1, #rows do
        local r = rows[i]
        local label = r.name .. "  (" .. tostring(r.weapon) .. ")  " .. tostring(r.done) .. "/" .. tostring(r.total)
        menu:addOption(label, self, AnimBrowser.onPickLoad, r.slug)
    end
    local delOpt = menu:addOption("Delete", self, nil)
    local sub = ISContextMenu:getNew(menu)
    menu:addSubMenu(delOpt, sub)
    for i = 1, #rows do
        sub:addOption(rows[i].name, self, AnimBrowser.onPickDelete, rows[i].slug)
    end
end

function AnimBrowser:onPickLoad(slug)
    if not loadProject(slug) then return end
    self.tab = AE.weapon
    self.useAll = AE.useAll
    if self.allTick then self.allTick:setSelected(1, self.useAll) end
    self.scrollRow = 0
    self:refilter()
    self:syncPanelFields()
end

function AnimBrowser:onPickDelete(slug)
    AnimForge.AnimProjects.delete(slug)
    if AE.project and AE.project.slug == slug then AE.project = nil end
end

function AnimBrowser:onSaveProject(button)
    if not AE.project then return end
    saveProject()
end

function AnimBrowser:onMouseWheel(del)
    self.scrollRow = self.scrollRow + (del > 0 and 1 or -1)
    self:clampScroll()
    self:relayout()
    return true
end

-- Click+drag the scrollbar. The track sits right of the grid (no thumbnail there),
-- so clicks in it reach the window; we intercept them before the base window-drag.
function AnimBrowser:onMouseDown(x, y)
    local sx, sy, sw, sh, ty, thumbH = self:scrollbarRect()
    if sx and x >= sx and x <= sx + sw and y >= sy and y <= sy + sh then
        -- grab on the thumb keeps it under the cursor; a click on the bare track
        -- jumps the thumb so its centre lands at the click.
        self.scrollGrab = (y >= ty and y <= ty + thumbH) and (y - ty) or (thumbH / 2)
        self.draggingScroll = true
        self.scrollRow = self:scrollFromMouseY(y)
        self:clampScroll(); self:relayout()
        self:setCapture(true)
        return true
    end
    return ISCollapsableWindow.onMouseDown(self, x, y)
end

function AnimBrowser:onMouseMove(dx, dy)
    if self.draggingScroll then
        self.scrollRow = self:scrollFromMouseY(self:getMouseY())
        self:clampScroll(); self:relayout()
        return
    end
    return ISCollapsableWindow.onMouseMove(self, dx, dy)
end

function AnimBrowser:onMouseMoveOutside(dx, dy)
    if self.draggingScroll then
        self.scrollRow = self:scrollFromMouseY(self:getMouseY())
        self:clampScroll(); self:relayout()
        return
    end
    return ISCollapsableWindow.onMouseMoveOutside(self, dx, dy)
end

function AnimBrowser:onMouseUp(x, y)
    if self.draggingScroll then
        self.draggingScroll = false
        self:setCapture(false)
        return
    end
    return ISCollapsableWindow.onMouseUp(self, x, y)
end

function AnimBrowser:onMouseUpOutside(x, y)
    if self.draggingScroll then
        self.draggingScroll = false
        self:setCapture(false)
        return
    end
    return ISCollapsableWindow.onMouseUpOutside(self, x, y)
end

function AnimBrowser:update()
    ISCollapsableWindow.update(self)
    if self.searchEntry then
        local t = self.searchEntry:getInternalText() or ""
        if t ~= self.search then
            self.search = t; self.scrollRow = 0; self:refilter()
        end
    end
end

function AnimBrowser:prerender()
    ISCollapsableWindow.prerender(self)
    -- project bar: live progress (badges on the grid are green=done, amber=edited).
    local py = self:titleBarHeight() + 4
    if AE.project then
        local done, edited, total = projectProgress()
        local txt = (AE.project.name or "?") .. " (" .. tostring(AE.project.weapon) .. ")   "
            .. done .. "/" .. total .. " done"
        if edited > done then txt = txt .. "   +" .. (edited - done) .. " edited" end
        self:drawText(txt, self.projTextX, py + 4, 0.82, 0.92, 0.8, 1, UIFont.Small)
    else
        self:drawText("no project - New set >", self.projTextX, py + 4, 0.7, 0.7, 0.72, 1, UIFont.Small)
    end
    -- active-tab highlight
    for name, b in pairs(self.tabBtns) do
        b.backgroundColor = (name == self.tab)
            and { r = 0.28, g = 0.42, b = 0.62, a = 1 }
            or { r = 0.1, g = 0.1, b = 0.12, a = 1 }
    end
    -- labels under each visible thumbnail
    local pad, cw, ch = self.pad, self.cellW, self.cellH
    local start = self.scrollRow * self.cols
    for r = 0, self.rows - 1 do
        for c = 0, self.cols - 1 do
            local idx = start + r * self.cols + c + 1
            if idx <= #self.clips then
                local lbl = clipLabel(self.clips[idx])
                if #lbl > 16 then lbl = lbl:sub(1, 15) .. "." end
                self:drawTextCentre(lbl, pad + c * cw + cw / 2, self.gridY + r * ch + self.modelH, 0.85, 0.88, 0.92, 1, UIFont.Small)
            end
        end
    end
    self:drawScrollbar()
end

-- Scrollbar track rect (window-relative) and the current thumb's y + height.
-- Returns nil when there's nothing to scroll.
function AnimBrowser:scrollbarRect()
    local total = self:totalRows()
    if total <= self.rows then return nil end
    local x = self.pad + self.gridW + 2
    local y = self.gridY
    local w = 10
    local h = self.rows * self.cellH
    local maxRow = total - self.rows
    local thumbH = math.max(16, h * self.rows / total)
    local ty = y + (h - thumbH) * (maxRow > 0 and self.scrollRow / maxRow or 0)
    return x, y, w, h, ty, thumbH, maxRow
end

function AnimBrowser:drawScrollbar()
    local x, y, w, h, ty, thumbH = self:scrollbarRect()
    if not x then return end
    self:drawRect(x, y, w, h, 0.4, 0.2, 0.2, 0.25)
    local my = self:getMouseY()
    local hot = self.draggingScroll or (self:isMouseOver() and self:getMouseX() >= x
        and self:getMouseX() <= x + w and my >= ty and my <= ty + thumbH)
    self:drawRect(x, ty, w, thumbH, hot and 1 or 0.85,
        hot and 0.8 or 0.6, hot and 0.85 or 0.7, hot and 1 or 0.95)
end

-- Map a window-relative mouse Y (minus the grab offset) to a scroll row.
function AnimBrowser:scrollFromMouseY(my)
    local x, y, w, h, ty, thumbH, maxRow = self:scrollbarRect()
    if not x or maxRow <= 0 then return 0 end
    local denom = h - thumbH
    local frac = denom > 0 and ((my - self.scrollGrab) - y) / denom or 0
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    return math.floor(frac * maxRow + 0.5)
end

-- Remember the current view so reopening restores it (persists on AE, which
-- survives across open/close and Lua reloads).
function AnimBrowser:saveState()
    AE.browserTab = self.tab
    AE.useAll = self.useAll
    AE.browserSearch = self.search
    AE.browserScrollRow = self.scrollRow
    AE.browserX = self:getX()   -- remember where it was dragged to
    AE.browserY = self:getY()
end

function AnimBrowser:close()
    self:saveState()
    AE.browser = nil
    ISCollapsableWindow.close(self)
end

local function closeBrowser()
    if AE.browser then
        AE.browser:saveState()
        AE.browser:removeFromUIManager(); AE.browser = nil
    end
end

-- x/y are explicit overrides (bridge). Otherwise reopen at the saved/dragged spot,
-- falling back on first-ever-open to the right of the editor panel.
local function openBrowser(x, y)
    loadModClipsFromCache()   -- keep the "Mods" tab in sync with the MCP's cached discovery list
    closeBrowser()   -- saves state (incl. position) from any existing instance first
    local px, py = x or AE.browserX, y or AE.browserY
    if not px then
        if AE.panel then
            px, py = AE.panel:getX() + AE.panel:getWidth() + 10, AE.panel:getY()
        else
            px, py = 380, 90
        end
    end
    AE.browser = AnimBrowser:new(px, py or 90)
    AE.browser:initialise(); AE.browser:addToUIManager()
    return AE.browser
end

-- ====================================================== Anim Forge hub ======
-- A single adaptive window: a left nav rail of task "modes" + a content area
-- that reshapes per mode (web-app IA). It composes the proven engine -- the
-- embedded AnimEditorPanel pose view (kept as AE.panel for the bridge contract),
-- the AnimBrowser, and the project/GW functions above -- so this layer is
-- presentation only. First open (no remembered mode) shows the launcher landing.
local T = AnimForge.AnimForgeTheme
-- Forward-declared so AnimForgeWindow:close() (defined below, before these) closes
-- over the right upvalue instead of a nil global.
local openPanel, closePanel

local NAV_W = 128            -- slimmer nav rail
local HEADER_H = 74          -- initial header band height; per-mode it sizes to its text (see layoutHeader)
local HEADER_MIN = 46        -- floor so a one-line header still reads as a card
local HEADER_MAX = 150       -- ceiling so a runaway string can't swallow the content area
local FOOTER_H = 42
local SCROLLBAR_W = 13       -- gutter the content scrollbar occupies
local EMOTE_BASES = { "Bob_Idle", "Bob_IdleHandgun", "Bob_IdleRifle", "Bob_IdleAimRifle" }
local ARCHETYPE_ORDER = { "magazine", "magazinehandgun", "shotgun", "revolver", "boltactionnomag", "doublebarrel", "lever" }
local STYLE_OPTS = { "none", "sprite" }

-- The task modes (drive the nav, the landing tiles, and routing). `pose` = the mode
-- embeds the pose editor; `setup` = it shows a setup form.
local MODES = {
    grip      = { label = "New grip set",     group = "Create", pose = true,
                  purpose = "Make a custom gun's held + aim animation set.",
                  how = "Name it, pick the weapon family + target mod, Create, then pose each clip from the Browser.",
                  whenDone = "Sign off every clip (green), then Export set to your mod." },
    reload    = { label = "New reload",         group = "Create", pose = false,
                  purpose = "Build a Gunworks reload (load / rack / unload stages).",
                  how = "Name the set + archetype + mod and Create; then edit each stage's pose + duration and fill the gun config.",
                  whenDone = "Add the gun fullType, then Export reload pack -> mod." },
    emote     = { label = "Pose / emote",       group = "Create", pose = true,
                  purpose = "Pose for a screenshot, or export it as a 1-frame emote.",
                  how = "Name it, pick a base idle + mod, pose the body, then Export emote.",
                  whenDone = "Export emote writes a 1-frame .x you can trigger with Preview." },
    open      = { label = "Open existing",     group = "Open",   pose = false,
                  purpose = "Reopen a saved set, or one from an installed mod.",
                  how = "Pick a saved project (or a mod that has one) from the lists.",
                  whenDone = "Selecting loads it straight into its editor." },
    resume    = { label = "Resume last",       group = "Open",   pose = false,
                  purpose = "Jump back into your most recent project." },
    duplicate = { label = "Duplicate set",     group = "Open",   pose = false,
                  purpose = "Clone a saved set as the start of a new gun.",
                  how = "Pick the source set, give the copy a new name + mod, Duplicate.",
                  whenDone = "The clone opens ready to edit + re-export." },
    override  = { label = "Override clip",      group = "Quick",  pose = true,
                  purpose = "Tweak ONE vanilla animation and overwrite it in place.",
                  how = "Pick the clip from the Browser, pose it.",
                  whenDone = "Save .x overwrites that vanilla clip (no rename)." },
    reloadfx  = { label = "Edit reload attachments", navLabel = "Reload attachments", group = "Quick", pose = false,
                  purpose = "Retune WHEN a gun's reload props/parts appear (cartridge, ball, ramrod).",
                  how = "Pick a mod reload below; drag the timeline markers while the reload plays - the character shows each attachment live.",
                  whenDone = "Save to mod, run pz_anim_bake, then reboot to see it in a real reload." },
}
local MODE_ORDER = { "grip", "reload", "emote", "open", "resume", "duplicate", "override", "reloadfx" }

-- Nav entries: a Menu (launcher) shortcut, then grouped headers + one row per mode.
local NAV_DEFS = (function()
    local groups = { "Create", "Open", "Quick" }
    local defs = { { key = "home", label = "< Menu" } }
    for _, g in ipairs(groups) do
        defs[#defs + 1] = { header = g }
        for _, key in ipairs(MODE_ORDER) do
            if MODES[key].group == g then defs[#defs + 1] = { key = key, label = MODES[key].navLabel or MODES[key].label } end
        end
    end
    return defs
end)()

AnimForgeWindow = ISCollapsableWindow:derive("AnimForgeWindow")

function AnimForgeWindow:new(x, y)
    local o = ISCollapsableWindow.new(self, x or 60, y or 60, 560, 640)
    o.title = "Anim Forge"
    o.resizable = false
    o.toast = StatusToast.new()
    o.allEntries = {}        -- every text field, for typing-focus detection
    o.scr = {}               -- [mode] = { widgets = {...} }
    o.setupBottom = {}       -- [mode] = y where the pose editor starts (below the setup form)
    o.mode = AE.forgeMode or "home"
    o.reloadEditing = nil    -- stageKey while posing a reload stage (sub-state)
    o.uiCollapsed = false    -- minimized to the title bar (get the panel out of the character's way)
    return o
end

-- ---- small widget factories. Screen widgets live in self.content (the scroll
-- container) so they scroll + clip; coords are content-relative. ----
function AnimForgeWindow:mkLabel(x, y, text, col)
    col = col or T.col.text2
    local l = ISLabel:new(x, y, 16, text, col[1], col[2], col[3], col[4] or 1, UIFont.Small, true)
    l:initialise(); self.content:addChild(l); l:setVisible(false)
    return l
end
function AnimForgeWindow:mkField(x, y, w, value, placeholder, numbers, tip)
    local e = ISTextEntryBox:new(value or "", x, y, w, 20)
    e:initialise(); e:instantiate()
    if placeholder then e:setPlaceholderText(placeholder) end
    if numbers then e:setOnlyNumbers(true) end
    if tip then e.tooltip = tip end
    e:setClearButton(true)
    self.content:addChild(e); e:setVisible(false)
    self.allEntries[#self.allEntries + 1] = e
    return e
end
function AnimForgeWindow:mkCombo(x, y, w, options, sel, tip)
    local c = ISComboBox:new(x, y, w, 22, self, nil)
    c:initialise(); self.content:addChild(c); c:setVisible(false)
    -- per-option tooltip = the field tooltip (ISComboBox shows the selected option's tooltip on hover)
    for _, o in ipairs(options) do c:addOptionWithData(o, nil, tip) end
    if sel then c:select(sel) end
    return c
end
function AnimForgeWindow:mkButton(x, y, w, h, label, fn, style, tip)
    local b = ISButton:new(x, y, w, h, label, self, fn)
    b:initialise(); self.content:addChild(b); b:setVisible(false)
    if tip then b.tooltip = tip end
    ;(style or T.styleGhost)(b)
    return b
end
local function comboText(c) return c and c.selected and c:getOptionText(c.selected) or nil end

function AnimForgeWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    self:setResizable(false)
    local th = self:titleBarHeight()

    -- Minimize toggle in the title bar (right of the close X): collapse to just the title bar so the
    -- panel can be tucked out of the character's way while posing. self.pin stops the vanilla
    -- mouse-away auto-collapse from fighting the explicit toggle.
    self.pin = true
    local mbh = th - 2
    self.minBtn = ISButton:new(1 + mbh + 3, 1, mbh, mbh, "-", self, AnimForgeWindow.onToggleCollapse)
    self.minBtn:initialise()
    self.minBtn.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    self.minBtn.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    self.minBtn.backgroundColorMouseOver = { r = 1, g = 1, b = 1, a = 0.2 }
    self.minBtn.tooltip = "Minimize / restore the panel"
    self:addChild(self.minBtn)

    self.contentX = NAV_W
    self.contentW = self.width - NAV_W
    -- content-relative layout origin + usable width (minus padding + scrollbar gutter)
    self.bodyX = T.sp.m
    self.bodyY = T.sp.s
    self.bodyW = self.contentW - T.sp.m * 2 - SCROLLBAR_W
    local contentH = self.height - th - HEADER_H - FOOTER_H

    -- nav rail
    self.nav = NavRail:new(0, th, NAV_W, self.height - th, AnimForgeWindow.onNav, self)
    self.nav:initialise(); self:addChild(self.nav)
    self.nav:setEntries(NAV_DEFS)

    -- instructional header (window child, above the scroll area). Height is set per-mode by
    -- layoutHeader() from the paginated text; HEADER_H is only the initial band.
    self.headerH = HEADER_H
    self.header = HelpHeader:new(self.contentX + T.sp.m, th + T.sp.xs, self.contentW - T.sp.m * 2, HEADER_H - T.sp.s)
    self.header:initialise(); self:addChild(self.header)

    -- scrollable content container: all mode widgets + the pose editor live in here
    self.content = ISPanel:new(self.contentX, th + HEADER_H, self.contentW, contentH)
    self.content.background = true
    self.content.backgroundColor = { r = T.col.surface[1], g = T.col.surface[2], b = T.col.surface[3], a = 1 }
    self.content.borderColor = { r = T.col.hair[1], g = T.col.hair[2], b = T.col.hair[3], a = 1 }
    self.content:initialise(); self:addChild(self.content)
    self.content:setScrollChildren(true)
    self.content:addScrollBars()
    self.content.prerender = function(s)
        ISPanel.prerender(s)
        s:setStencilRect(0, 0, s:getWidth(), s:getHeight())   -- clip scrolled children
    end
    self.content.render = function(s) s:clearStencilRect() end
    self.content.onMouseWheel = function(s, del)
        if s:getScrollHeight() > s:getHeight() then
            s:setYScroll(s:getYScroll() - del * 40); return true
        end
        return false
    end

    -- embedded pose editor (shown only in `pose` modes), assigned as AE.panel
    self.pose = AnimEditorPanel:new(self.bodyX, self.bodyY, self.bodyW)
    self.pose:initialise(); self.content:addChild(self.pose)
    self.pose:setVisible(false)
    AE.panel = self.pose

    -- footer (window children, fixed below the scroll area): browse + secondary + primary + toast
    local fy = self.height - FOOTER_H + 8
    local function footBtn(x, w, label, fn, style)
        local b = ISButton:new(x, fy, w, 24, label, self, fn)
        b:initialise(); self:addChild(b); b:setVisible(false)
        ;(style or T.styleGhost)(b)
        return b
    end
    self.browseBtn = footBtn(self.contentX + T.sp.m, 104, "Browse clips", AnimForgeWindow.onBrowseToggle)
    self.secondaryBtn = footBtn(self.width - 286, 132, "", AnimForgeWindow.onSecondary)
    self.primaryBtn = footBtn(self.width - 146, 134, "", AnimForgeWindow.onPrimary, T.stylePrimary)

    self:buildScreens()
    self:switchMode(self.mode)
end

-- Collect a screen's widgets so switchMode can show/hide them as a group.
function AnimForgeWindow:screen(key) self.scr[key] = self.scr[key] or { widgets = {} }; return self.scr[key] end
function AnimForgeWindow:add(key, w) table.insert(self:screen(key).widgets, w); return w end

function AnimForgeWindow:buildScreens()
    local x, y, w = self.bodyX, self.bodyY, self.bodyW
    local gap = T.sp.s
    local hw = math.floor((w - gap) / 2)   -- half width for two-per-row layouts
    local x2 = x + hw + gap
    -- ---- landing launcher: a 2-col tile per mode ----
    do
        local tileH = 54
        for i, key in ipairs(MODE_ORDER) do
            local c = (i - 1) % 2
            local r = math.floor((i - 1) / 2)
            local b = self:mkButton(c == 0 and x or x2, y + r * (tileH + gap), hw, tileH,
                MODES[key].label, AnimForgeWindow.onTile, T.styleGhost, MODES[key].purpose)
            b.tileKey = key
            self:add("home", b)
        end
    end
    -- ---- grip (two rows) ----
    do
        self:add("grip", self:mkLabel(x, y, "Set name"))
        self.gripName = self:add("grip", self:mkField(x, y + 16, hw, AE.namePrefix, "MyPistol", false,
            "Set name + clip prefix. Output anims are named <name>_<clip>.x"))
        self:add("grip", self:mkLabel(x2, y, "Target mod"))
        self.gripMod = self:add("grip", self:mkField(x2, y + 16, hw, AE.mod, "MyGunMod", false,
            "Mod folder the set exports into."))
        self:add("grip", self:mkLabel(x, y + 44, "Weapon"))
        self.gripWeapon = self:add("grip", self:mkCombo(x, y + 60, hw, AnimForge.AnimCategories.order, AE.weapon,
            "Weapon family whose grip/aim clips you'll pose."))
        self.gripCreate = self:add("grip", self:mkButton(x2, y + 58, hw, 24, "Create", AnimForgeWindow.onGripCreate,
            T.styleGhost, "Create the set + open the Browser to pose each clip."))
        self.setupBottom.grip = y + 60 + 24 + T.sp.s
    end
    -- ---- emote (two rows) ----
    do
        self:add("emote", self:mkLabel(x, y, "Emote name"))
        self.emoteName = self:add("emote", self:mkField(x, y + 16, hw, AE.emoteName or "", "wave_custom", false,
            "Name to trigger the emote with (player:playEmote)."))
        self:add("emote", self:mkLabel(x2, y, "Target mod"))
        self.emoteMod = self:add("emote", self:mkField(x2, y + 16, hw, AE.mod, "MyEmoteMod", false,
            "Mod folder the 1-frame emote exports into."))
        self:add("emote", self:mkLabel(x, y + 44, "Base idle"))
        self.emoteBase = self:add("emote", self:mkCombo(x, y + 60, hw, EMOTE_BASES, AE.emoteBase or EMOTE_BASES[1],
            "Base idle clip to pose over."))
        self.emoteLoad = self:add("emote", self:mkButton(x2, y + 58, hw, 24, "Load base", AnimForgeWindow.onEmoteLoad,
            T.styleGhost, "Load the base idle so you can pose the body."))
        self.setupBottom.emote = y + 60 + 24 + T.sp.s
    end
    -- ---- override ----
    do
        self:add("override", self:mkLabel(x, y, "Pick a vanilla clip in the Browser, then pose it.", T.col.muted))
        self:add("override", self:mkLabel(x, y + 16, "Save .x overwrites that clip in place.", T.col.muted))
        self.setupBottom.override = y + 40
    end
    -- ---- duplicate ----
    do
        self:add("duplicate", self:mkLabel(x, y, "Source set"))
        self.dupSource = self:add("duplicate", self:mkCombo(x, y + 16, w, { "(none)" }, nil, "The saved set to clone."))
        self:add("duplicate", self:mkLabel(x, y + 44, "New name"))
        self.dupName = self:add("duplicate", self:mkField(x, y + 60, hw, "", "MyPistol2", false, "Name for the cloned set."))
        self:add("duplicate", self:mkLabel(x2, y + 44, "Target mod"))
        self.dupMod = self:add("duplicate", self:mkField(x2, y + 60, hw, "", "MyGunMod", false, "Mod folder for the clone."))
    end
    -- ---- reload (Gunworks) ----
    self:buildReloadScreen(x, y, w)
    -- ---- reloadfx: pick a discovered mod reload to retune its attachment markers ----
    do
        self:add("reloadfx", self:mkLabel(x, y, "Pick a mod reload to retune its attachment timings:", T.col.muted))
        self.rfxRows = {}
        for i = 1, 6 do
            local b = self:add("reloadfx", self:mkButton(x, y + 22 + (i - 1) * 26, w, 22, "",
                AnimForgeWindow.onReloadFxPick, T.styleGhost))
            b:setVisible(false)
            self.rfxRows[i] = b
        end
        self.rfxEmpty = self:add("reloadfx", self:mkLabel(x, y + 26,
            "No reloads found. Run the pz_anim_list_reloads tool, then reopen this.", T.col.muted))
    end
    -- ---- open / resume: two list columns with headers ----
    do
        local listW = math.floor((w - gap) / 2)
        local listY = y + 20
        local listH = self.content:getHeight() - listY - T.sp.s
        self:add("open", self:mkLabel(x, y, "Saved projects"))
        self:add("open", self:mkLabel(x2, y, "From an installed mod"))
        self.openList = ISScrollingListBox:new(x, listY, listW, listH)
        self.openList:initialise(); self.content:addChild(self.openList); self.openList:setVisible(false)
        self.openList.font = UIFont.Small
        self.openList:setOnMouseDownFunction(self, AnimForgeWindow.onOpenPick)
        self:add("open", self.openList)
        self.modList = ISScrollingListBox:new(x2, listY, listW, listH)
        self.modList:initialise(); self.content:addChild(self.modList); self.modList:setVisible(false)
        self.modList.font = UIFont.Small
        self.modList:setOnMouseDownFunction(self, AnimForgeWindow.onModPick)
        self:add("open", self.modList)
    end
end

function AnimForgeWindow:buildReloadScreen(x, y, w)
    local gap = T.sp.s
    local hw = math.floor((w - gap) / 2)
    local x2 = x + hw + gap
    local lblW = 96
    -- rCreate = the create row (always shown when not editing a stage).
    -- rPost   = stages + config (shown only AFTER the set is created, mirroring grip's
    --           Create gate so Mark done / progress / persistence all have a project).
    self.rCreate, self.rPost = {}, {}
    local function create(wgt) self:add("reload", wgt); table.insert(self.rCreate, wgt); return wgt end
    local function post(wgt) self:add("reload", wgt); table.insert(self.rPost, wgt); return wgt end

    -- ---- create row (two rows): Set name + Target mod, then Archetype + Create set ----
    create(self:mkLabel(x, y, "Set name (animId)"))
    self.rAnimId = create(self:mkField(x, y + 16, hw, AE.gw.config.animId, "PumpShotgun", false,
        "The GunworksReloadAnim id + clip prefix for this reload."))
    create(self:mkLabel(x2, y, "Target mod"))
    self.rMod = create(self:mkField(x2, y + 16, hw, AE.gw.config.mod, "MyGunMod", false,
        "Mod folder the reload pack exports into."))
    create(self:mkLabel(x, y + 44, "Archetype"))
    self.rArch = create(self:mkCombo(x, y + 60, hw, (function()
        local opts = {}; for _, k in ipairs(ARCHETYPE_ORDER) do opts[#opts + 1] = AnimForge.AnimCategories.reloadArchetypes[k].display end; return opts
    end)(), nil, "Reload family. Seeds the load/rack/unload stages + their base clips."))
    self.rArch.selected = 1   -- default to the first archetype (combos start at 0 = none)
    self.rCreateBtn = create(self:mkButton(x2, y + 58, hw, 24, "Create set", AnimForgeWindow.onReloadCreate,
        T.stylePrimary, "Create + save the reload set, then reveal the stages + config."))
    self.rHint = create(self:mkLabel(x, y + 88, "Name + mod, pick the archetype, then Create set.", T.col.muted))

    -- ---- stage rows (post-create): label + base clip + duration + Edit pose ----
    self.rStageRows = {}
    local sy = y + 110
    for i = 1, 4 do
        local row = {}
        row.label = post(self:mkLabel(x, sy + 4, "stage"))
        row.base  = post(self:mkLabel(x + 78, sy + 4, "-", T.col.muted))
        row.dur   = post(self:mkField(w - 158, sy + 2, 44, "", "auto", true,
            "Stage duration in seconds (blank = vanilla default)."))
        row.edit  = post(self:mkButton(w - 100, sy, 100, 22, "Edit pose", AnimForgeWindow.onReloadEditStage,
            T.styleGhost, "Load this stage's clip into the pose editor."))
        self.rStageRows[i] = row
        sy = sy + 26
    end

    -- ---- config grid (post-create), single column: each field full width ----
    local cy = sy + 8
    local function cfgField(rowI, label, value, ph, tip)
        local ry = cy + rowI * 26
        post(self:mkLabel(x, ry + 3, label))
        return post(self:mkField(x + lblW, ry, w - lblW, value, ph, false, tip))
    end
    self.rFullType = cfgField(0, "gun fullType", AE.gw.config.fullTypes, "Base.Shotgun",
        "Gun item fullType(s) this reload applies to (comma-separated).")
    self.rNamespace = cfgField(1, "lua namespace", AE.gw.config.luaNamespace, "MyMod",
        "Lua require dir under media/lua/shared (default = mod name).")
    self.rProp = cfgField(2, "off-hand prop", AE.gw.config.propItem, "Base.ShotgunShells (optional)",
        "Optional item shown in the off hand during the reload.")
    self.rBuild = cfgField(3, "build", AE.gw.config.build, "42.13", "Mod build subfolder (e.g. 42.13).")
    local syc = cy + 4 * 26
    post(self:mkLabel(x, syc + 3, "style"))
    self.rStyle = post(self:mkCombo(x + lblW, syc, 120, STYLE_OPTS, AE.gw.config.style,
        "none = no model swap; sprite = swap the gun sprite during reload."))
    self.rShort = ISTickBox:new(x + lblW + 130, syc + 2, 18, 18, "", self, nil)
    self.rShort:initialise(); self.content:addChild(self.rShort); self.rShort:setVisible(false)
    self.rShort:addOption("short rack after insert"); self.rShort:setSelected(1, AE.gw.config.shortRackAfterInsert == true)
    self.rShort.tooltip = "Mag-fed: play a short rack after inserting a partial mag."
    post(self.rShort)
    self.rSpriteL = cfgField(5, "sprite loaded", AE.gw.config.spriteLoaded, "Mod.GunLoaded",
        "style=sprite: gun sprite while loaded.")
    self.rSpriteU = cfgField(6, "sprite unloaded", AE.gw.config.spriteUnloaded, "Mod.GunEmpty",
        "style=sprite: gun sprite while unloaded.")

    -- Back button lives in the band above the embedded pose editor (only shown while
    -- editing a stage), so it never overlaps the config grid or the pose view.
    self.rBackBtn = self:add("reload", self:mkButton(x, y + 2, 130, 22, "< Back to stages", AnimForgeWindow.onReloadBack, T.styleGhost))
end

-- ---- mode switching ----
function AnimForgeWindow:onNav(key)
    if key == "resume" then self:doResume(); return end
    self:switchMode(key)
end
function AnimForgeWindow:onTile(button) self:switchMode(button.tileKey) end

function AnimForgeWindow:hideAll()
    self.pose:setVisible(false)
    for _, sc in pairs(self.scr) do
        for _, wgt in ipairs(sc.widgets) do wgt:setVisible(false) end
    end
end

-- Populate the "Edit reload attachments" task with the reloads the MCP cached (refreshed each time
-- the task is opened).
function AnimForgeWindow:refreshReloadFx()
    loadReloadsFromCache()
    local reloads = rfxEditableReloads()
    for i = 1, #self.rfxRows do
        local b = self.rfxRows[i]
        local r = reloads[i]
        if r then
            local n = (r.markers and #r.markers) or 0
            b:setTitle("Edit   " .. tostring(r.mod) .. " . " .. tostring(r.animId)
                .. "    (" .. tostring(r.clip) .. ")   "
                .. n .. (n == 1 and " marker" or " markers"))
            b.reload = r
            b:setVisible(true)
        else
            b.reload = nil
            b:setVisible(false)
        end
    end
    if self.rfxEmpty then self.rfxEmpty:setVisible(#reloads == 0) end
end

function AnimForgeWindow:onReloadFxPick(button)
    if button.reload then openReloadFx(button.reload) end
end

function AnimForgeWindow:onToggleCollapse()
    self:setCollapsed(not self.uiCollapsed)
end

-- Collapse the whole panel to just its title bar (nav + header + content + footer hidden, height
-- shrunk) so it stops covering the character while you pose; restore rebuilds the active mode.
function AnimForgeWindow:setCollapsed(c)
    if c == self.uiCollapsed then return end
    self.uiCollapsed = c
    local th = self:titleBarHeight()
    if c then
        self.fullHeight = self.height
        self.nav:setVisible(false)
        self.header:setVisible(false)
        self.content:setVisible(false)
        self.browseBtn:setVisible(false)
        self.secondaryBtn:setVisible(false)
        self.primaryBtn:setVisible(false)
        self:setHeight(th)
        if self.minBtn then self.minBtn:setTitle("+") end
    else
        self:setHeight(self.fullHeight or 640)
        self.nav:setVisible(true)
        self.header:setVisible(true)
        self.content:setVisible(true)
        if self.minBtn then self.minBtn:setTitle("-") end
        self:switchMode(self.mode)   -- restores the mode's widgets + footer + header layout
    end
end

-- Size the header band to the paginated help text (autosetheight gave the RichText panel its true
-- content height), clamp it, then drop the scroll content area directly below it. Keeps the "open"
-- mode's two lists (sized to the content box) in sync.
function AnimForgeWindow:layoutHeader()
    local th = self:titleBarHeight()
    local inner = (self.header and self.header:getHeight()) or HEADER_H
    if inner < HEADER_MIN then inner = HEADER_MIN end
    if inner > HEADER_MAX then inner = HEADER_MAX; self.header:setHeight(inner) end
    self.headerH = T.sp.xs + inner + T.sp.xs   -- card top pad + text + small gap to content
    local cy = th + self.headerH
    self.content:setY(cy)
    self.content:setHeight(self.height - cy - FOOTER_H)
    if self.openList and self.modList then
        local listH = self.content:getHeight() - (self.bodyY + 20) - T.sp.s
        self.openList:setHeight(listH); self.modList:setHeight(listH)
    end
end

function AnimForgeWindow:switchMode(key)
    self:hideAll()
    self.mode = key
    AE.forgeMode = key
    self.reloadEditing = nil
    self.nav:setActive(key)

    local m = MODES[key]
    if key == "home" then
        self.header:setContent("Anim Forge", "What do you want to make? Pick a task to begin.",
            "Each task reshapes this panel and tells you what to do.", "")
    elseif m then
        self.header:setContent(m.label, m.purpose, m.how, m.whenDone)
    end
    self:layoutHeader()   -- resize the header band + content area to the freshly paginated text

    local sc = self.scr[key]
    if sc then
        for _, wgt in ipairs(sc.widgets) do wgt:setVisible(true) end
    end
    if key == "reloadfx" then self:refreshReloadFx() end

    -- pose modes show the embedded editor below the setup form; reload shows pose only while editing a stage
    local showPose = m and m.pose
    AE.poseActive = showPose and true or false   -- gates the world overlay's bone nodes/gizmo
    if showPose then
        self.pose:setY(self.setupBottom[key] or self.bodyY)
        self.pose:setVisible(true)
    end
    -- Browse is for the pose/override flows; reload uses the archetype's seeded clips.
    self.browseBtn:setVisible((m and m.pose) or key == "override")

    if key == "reload" then self:refreshReload() end
    if key == "open" then self:refreshOpenLists() end
    if key == "duplicate" then self:refreshDupSources() end

    self:configFooter()
    self:updateScroll()
end

-- Size the scroll container to the active mode's content (the tallest visible
-- widget bottom, including the pose editor) so it scrolls only when it overflows.
function AnimForgeWindow:updateScroll()
    local maxB = self.bodyY
    local sc = self.scr[self.mode]
    if sc then
        for _, wgt in ipairs(sc.widgets) do
            if wgt:getIsVisible() then maxB = math.max(maxB, wgt:getY() + wgt:getHeight()) end
        end
    end
    if self.pose:getIsVisible() then maxB = math.max(maxB, self.pose:getY() + self.pose:getHeight()) end
    self.content:setScrollHeight(maxB + T.sp.m)
    self.content:setYScroll(0)
end

-- Footer button labels/visibility per mode.
function AnimForgeWindow:configFooter()
    local key = self.mode
    local prim, sec = nil, nil
    if key == "grip" then prim = "Export set -> mod"
    elseif key == "emote" then prim = "Export emote -> mod"; sec = "Preview emote"
    elseif key == "override" then prim = "Save .x (overwrite)"
    elseif key == "duplicate" then prim = "Duplicate & open"
    elseif key == "reload" then
        -- Export only after the set is created (and not while posing a stage).
        if not self.reloadEditing and AE.project and AE.project.type == "gunworks" then
            prim = "Export reload pack -> mod"
        end
    end
    if prim then self.primaryBtn:setTitle(prim); self.primaryBtn:setVisible(true) else self.primaryBtn:setVisible(false) end
    if sec then self.secondaryBtn:setTitle(sec); self.secondaryBtn:setVisible(true) else self.secondaryBtn:setVisible(false) end
end

function AnimForgeWindow:onBrowseToggle()
    if AE.browser then closeBrowser() else openBrowser() end
end

-- ---- grip ----
function AnimForgeWindow:onGripCreate()
    local name = self.gripName:getInternalText()
    local weapon = comboText(self.gripWeapon) or AE.weapon
    local mod = self.gripMod:getInternalText()
    if name == "" or mod == "" then self.toast:set("Enter a set name and target mod first.", "danger"); return end
    if not newProject(name, weapon, name, mod, "", false) then
        self.toast:set("Unknown weapon: " .. tostring(weapon), "danger"); return
    end
    openBrowser()
    if AE.browser then AE.browser.tab = weapon; AE.browser:refilter() end
    self.toast:set("Created '" .. name .. "'. Pose each clip from the Browser.", "ok")
end

-- ---- emote ----
function AnimForgeWindow:onEmoteLoad()
    local base = comboText(self.emoteBase) or EMOTE_BASES[1]
    AE.emoteName = self.emoteName:getInternalText()
    AE.emoteBase = base
    AE.mod = self.emoteMod:getInternalText()
    selectClipInEditor(base)
    self.toast:set("Loaded base '" .. base .. "'. Pose the body, then Export emote.", "ok")
end

-- ---- duplicate ----
function AnimForgeWindow:refreshDupSources()
    self.dupSource:clear()
    self._dupRows = AP.list()
    if #self._dupRows == 0 then self.dupSource:addOption("(no saved sets)") return end
    for i = 1, #self._dupRows do
        local r = self._dupRows[i]
        self.dupSource:addOption(r.name .. "  (" .. tostring(r.weapon) .. ")")
    end
    self.dupSource:select(1)
end

-- ---- reload (Gunworks) ----
-- Create set: establish (+ persist) a gunworks project, mirroring grip's Create.
-- Seeds the archetype (unless re-creating the same one, so stage edits survive),
-- pulls the form into config, saves the project, and reveals the stages + config.
function AnimForgeWindow:onReloadCreate()
    local name = self.rAnimId:getInternalText()
    local mod = self.rMod:getInternalText()
    if name == "" or mod == "" then
        self.toast:set("Enter a set name (animId) and target mod first.", "danger"); return
    end
    local key = ARCHETYPE_ORDER[self.rArch.selected or 1]
    if AE.gw.archetypeKey ~= key or not AE.gw.order or #AE.gw.order == 0 then
        if not GW.seedArchetype(key) then self.toast:set("Unknown archetype.", "danger"); return end
    end
    self.reloadEditing = nil
    self:syncReloadConfig()                 -- form -> AE.gw.config
    AE.gw.config.animId = name; AE.gw.config.mod = mod
    local proj = GW.buildProject(name)
    proj.slug = (AE.project and AE.project.type == "gunworks") and AE.project.slug or nil
    local slug = AP.save(proj)
    AE.project = { name = name, slug = slug, weapon = AE.gw.archetypeKey, type = "gunworks" }
    self:refreshReload()
    self.toast:set("Created set '" .. name .. "'. Edit each stage + config, then Export.", "ok")
end

function AnimForgeWindow:refreshReload()
    local editing = self.reloadEditing ~= nil
    local created = AE.project ~= nil and AE.project.type == "gunworks"

    if editing then
        -- editing a stage: hide the whole reload screen; show only Back + the pose editor
        for _, wgt in ipairs(self:screen("reload").widgets) do wgt:setVisible(false) end
        self.rBackBtn:setVisible(true)
        self.pose:setY(self.bodyY + 28)   -- below the Back button
        self.pose:setVisible(true)
        AE.poseActive = true
        self:configFooter()
        self:updateScroll()
        return
    end

    self.pose:setVisible(false)
    self.rBackBtn:setVisible(false)
    AE.poseActive = false
    -- create row always; the hint only until the set exists; stages + config only after
    for _, wgt in ipairs(self.rCreate) do wgt:setVisible(true) end
    self.rHint:setVisible(not created)
    for _, wgt in ipairs(self.rPost) do wgt:setVisible(created) end

    if created then
        local order = AE.gw.order or {}
        for i = 1, 4 do
            local row = self.rStageRows[i]
            local key = order[i]
            local on = key ~= nil
            row.label:setVisible(on); row.base:setVisible(on)
            row.dur:setVisible(on); row.edit:setVisible(on)
            if key then
                local s = AE.gw.stages[key] or {}
                row.label:setName(key)
                -- shorten the base clip (drop the common Bob_Reload_ prefix) so it fits before the dur field
                row.base:setName((s.baseClip or "-"):gsub("^Bob_Reload_", ""))
                row.dur:setText(s.duration and tostring(s.duration) or "")
                row.edit.stageKey = key
                row.dur.stageKey = key
            end
        end
        -- reflect AE.gw.config in the form (after create / load / back round-trip)
        local c = AE.gw.config
        self.rAnimId:setText(c.animId or ""); self.rMod:setText(c.mod or "")
        self.rFullType:setText(c.fullTypes or ""); self.rNamespace:setText(c.luaNamespace or "")
        self.rProp:setText(c.propItem or ""); self.rBuild:setText(c.build or "42.13")
        self.rSpriteL:setText(c.spriteLoaded or ""); self.rSpriteU:setText(c.spriteUnloaded or "")
        self.rStyle:select(c.style or "none")
        self.rShort:setSelected(1, c.shortRackAfterInsert == true)
        if AE.gw.archetypeKey then
            for i = 1, #ARCHETYPE_ORDER do
                if ARCHETYPE_ORDER[i] == AE.gw.archetypeKey then self.rArch.selected = i end
            end
        end
    end
    self:configFooter()
    self:updateScroll()
end

function AnimForgeWindow:onReloadEditStage(button)
    local key = button.stageKey
    if not key then return end
    self:syncReloadConfig()   -- keep typed config + durations across the edit sub-state
    if GW.loadStage(key) then
        self.reloadEditing = key
        self:refreshReload()
        self.toast:set("Editing stage '" .. key .. "'. Pose, then Back to stages.", "ok")
    end
end

function AnimForgeWindow:onReloadBack()
    GW.captureActiveStage()
    self.reloadEditing = nil
    self:refreshReload()
end

-- pull the reload config form into AE.gw.config
function AnimForgeWindow:syncReloadConfig()
    local c = AE.gw.config
    c.animId = self.rAnimId:getInternalText()
    c.fullTypes = self.rFullType:getInternalText()
    c.mod = self.rMod:getInternalText()
    c.luaNamespace = self.rNamespace:getInternalText()
    c.propItem = self.rProp:getInternalText()
    c.build = self.rBuild:getInternalText()
    c.style = comboText(self.rStyle) or "none"
    c.spriteLoaded = self.rSpriteL:getInternalText()
    c.spriteUnloaded = self.rSpriteU:getInternalText()
    c.shortRackAfterInsert = self.rShort:isSelected(1)
    -- per-stage durations from the rows (guard stale keys after an archetype reseed)
    for i = 1, 4 do
        local row = self.rStageRows[i]
        local sk = row.dur.stageKey
        if sk and AE.gw.stages[sk] then
            local d = tonumber(row.dur:getInternalText())
            if d then AE.gw.stages[sk].duration = d end
        end
    end
end

-- ---- open / resume / lists ----
function AnimForgeWindow:refreshOpenLists()
    self.openList:clear()
    self._openRows = AP.list()
    for i = 1, #self._openRows do
        local r = self._openRows[i]
        local tag = (r.type == "gunworks" and "  [reload]" or "")
        -- Visible text stays compact so it fits the column; the full detail (incl. weapon family) is
        -- on the hover tooltip, so nothing is lost to truncation.
        local disp = r.name .. "  " .. tostring(r.done) .. "/" .. tostring(r.total) .. tag
        local tip = r.name .. "  (" .. tostring(r.weapon) .. ")  " .. tostring(r.done) .. "/" .. tostring(r.total) .. tag
        self.openList:addItem(disp, r, tip)
    end
    if self.openList:size() == 0 then self.openList:addItem("(no saved sets yet)", nil) end
    -- mods that have a saved project targeting them (round-trip set)
    self.modList:clear()
    local byMod = {}
    for i = 1, #self._openRows do
        local proj = AP.load(self._openRows[i].slug)
        local mod = proj and (proj.mod or (proj.gunworks and proj.gunworks.mod))
        if mod and mod ~= "" then byMod[mod] = byMod[mod] or {}; table.insert(byMod[mod], self._openRows[i]) end
    end
    self._modRows = {}
    local active = {}
    pcall(function() local am = getActivatedMods(); if am then for i = 0, am:size() - 1 do active[am:get(i)] = true end end end)
    for mod, rows in pairs(byMod) do
        local tag = active[mod] and "" or "  (inactive)"
        for _, r in ipairs(rows) do
            self._modRows[#self._modRows + 1] = r
            self.modList:addItem(mod .. tag .. "  -  " .. r.name, r,
                mod .. tag .. "  ->  " .. r.name .. "  (" .. tostring(r.weapon) .. ")")
        end
    end
    if self.modList:size() == 0 then self.modList:addItem("(no mods with a saved set)", nil) end
end

function AnimForgeWindow:onOpenPick()
    local sel = self.openList.items[self.openList.selected]
    if not sel or not sel.item then return end
    self:loadAndRoute(sel.item.slug)
end
function AnimForgeWindow:onModPick()
    local sel = self.modList.items[self.modList.selected]
    if not sel or not sel.item then return end
    self:loadAndRoute(sel.item.slug)
end

function AnimForgeWindow:loadAndRoute(slug)
    local proj = AP.load(slug)
    if not proj then self.toast:set("Could not load that set.", "danger"); return end
    if proj.type == "gunworks" then
        GW.applyProject(proj)
        for i = 1, #ARCHETYPE_ORDER do if ARCHETYPE_ORDER[i] == AE.gw.archetypeKey then self.rArch.selected = i end end
        self:switchMode("reload")
        self:refreshReload()
    else
        if not loadProject(slug) then self.toast:set("Load failed.", "danger"); return end
        self.gripName:setText(AE.namePrefix or ""); self.gripMod:setText(AE.mod or "")
        if AE.weapon then self.gripWeapon:select(AE.weapon) end
        openBrowser(); if AE.browser then AE.browser.tab = AE.weapon; AE.browser:refilter() end
        self:switchMode("grip")
    end
    self.toast:set("Opened '" .. tostring(proj.name) .. "'.", "ok")
end

function AnimForgeWindow:doResume()
    local rows = AP.list()
    if #rows == 0 then self.toast:set("No saved sets to resume.", "danger"); self:switchMode("home"); return end
    local best = rows[1]
    for i = 2, #rows do if (rows[i].updated or 0) > (best.updated or 0) then best = rows[i] end end
    self:loadAndRoute(best.slug)
end

-- ---- footer actions ----
function AnimForgeWindow:onPrimary()
    local key = self.mode
    if key == "grip" then
        AE.mod = self.gripMod:getInternalText(); AE.namePrefix = self.gripName:getInternalText()
        local done, _, total = projectProgress()
        if not AE.project then self.toast:set("Create the set first.", "danger"); return end
        if total > 0 and done < total then self.toast:set("Tip: " .. done .. "/" .. total .. " clips signed off. Exporting anyway.", "edited") end
        if self.pose:onSaveSet() then self.toast:set("Exported '" .. AE.namePrefix .. "' -> " .. AE.mod .. ". Run wire-set / pz_anim_bake to build.", "ok") end
    elseif key == "override" then
        AE.panel:onSave(); self.toast:set("Saved single .x for '" .. AE.clip .. "'. Run pz_anim_bake to build.", "ok")
    elseif key == "emote" then
        self:exportEmote()
    elseif key == "duplicate" then
        self:doDuplicate()
    elseif key == "reload" then
        self:exportReload()
    end
end

function AnimForgeWindow:onSecondary()
    if self.mode == "emote" then
        local p = getPlayer()
        local nm = self.emoteName:getInternalText()
        if p and nm ~= "" then pcall(function() p:playEmote(nm) end); self.toast:set("Playing emote '" .. nm .. "' (needs the baked node loaded).", "ok") end
    end
end

function AnimForgeWindow:doDuplicate()
    local rows = self._dupRows or {}
    local idx = self.dupSource and self.dupSource.selected or 0
    local src = rows[idx]
    local newName = self.dupName:getInternalText()
    local newMod = self.dupMod:getInternalText()
    if not src then self.toast:set("Pick a source set.", "danger"); return end
    if newName == "" or newMod == "" then self.toast:set("Enter a new name and mod.", "danger"); return end
    if not loadProject(src.slug) then self.toast:set("Load failed.", "danger"); return end
    AE.project = { name = newName, slug = AP.slugify(newName), weapon = AE.weapon }
    AE.namePrefix = newName; AE.mod = newMod
    saveProject()
    self.gripName:setText(newName); self.gripMod:setText(newMod)
    if AE.weapon then self.gripWeapon:select(AE.weapon) end
    self:switchMode("grip")
    openBrowser(); if AE.browser then AE.browser.tab = AE.weapon; AE.browser:refilter() end
    self.toast:set("Duplicated as '" .. newName .. "'.", "ok")
end

function AnimForgeWindow:exportEmote()
    local nm = self.emoteName:getInternalText()
    local base = comboText(self.emoteBase) or EMOTE_BASES[1]
    local mod = self.emoteMod:getInternalText()
    if nm == "" or mod == "" then self.toast:set("Enter an emote name and target mod.", "danger"); return end
    AE.emoteName = nm; AE.emoteBase = base; AE.mod = mod
    -- single-frame pose: capture the current bone deltas onto the base clip at t=0
    local data = {
        order = AE.order, mode = AE.mode, clip = base, deltas = AE.deltas,
        emote = { name = nm, baseClip = base, mod = mod },
    }
    local writer = getFileWriter("AgentBridge/anim_edit.json", true, false)
    writer:write(AnimForge.JSON.encode(data)); writer:close()
    self.toast:set("Wrote emote '" .. nm .. "' -> " .. mod .. ". Run wire-emote / pz_anim_bake to build.", "ok")
end

function AnimForgeWindow:exportReload()
    self:syncReloadConfig()
    local c = AE.gw.config
    if c.animId == "" or c.fullTypes == "" or c.mod == "" then
        self.toast:set("Need animId, gun fullType, and target mod.", "danger"); return
    end
    for _, key in ipairs(AE.gw.order or {}) do
        if not (AE.gw.stages[key] and AE.gw.stages[key].baseClip) then
            self.toast:set("Stage '" .. key .. "' has no base clip. Seed an archetype.", "danger"); return
        end
    end
    GW.captureActiveStage(); GW.saveJson()
    local name = c.animId ~= "" and c.animId or "gunworks"
    local slug = AP.save(GW.buildProject(name))
    AE.project = { name = name, slug = slug, weapon = AE.gw.archetypeKey, type = "gunworks" }
    self.toast:set("Exported reload '" .. name .. "' -> " .. c.mod .. ". Run wire-gunworks to build.", "ok")
end

-- ---- live frame: content card, toast, primary-enable ----
function AnimForgeWindow:prerender()
    ISCollapsableWindow.prerender(self)
    if self.uiCollapsed then return end   -- minimized: only the title bar draws
    local th = self:titleBarHeight()
    -- backdrop behind header + footer (the scroll content panel paints its own surface). The header
    -- title/description sit directly on this backdrop -- no card box, to avoid a panel-in-a-panel.
    T.fill(self, self.contentX, th, self.contentW, self.height - th, T.col.bg0)
    -- footer divider + toast
    local fy = self.height - FOOTER_H
    T.hairline(self, self.contentX + T.sp.s, fy, self.contentW - T.sp.s * 2)
    self.toast:render(self, self.contentX + T.sp.m, fy + 16)
    -- grip live progress at the bottom-right of the header band
    if self.mode == "grip" and AE.project then
        local done, edited, total = projectProgress()
        local txt = done .. "/" .. total .. " done" .. (edited > done and ("  +" .. (edited - done) .. " edited") or "")
        T.textRight(self, txt, self.width - T.sp.l, th + (self.headerH or HEADER_H) - 16, done >= total and total > 0 and T.col.done or T.col.text2)
    end
end

function AnimForgeWindow:isTyping()
    for _, e in ipairs(self.allEntries) do if e and e:isFocused() then return true end end
    return false
end

function AnimForgeWindow:close()
    closePanel()
end

-- ------------------------------------------------------------- open/close ---
openPanel = function()
    if AE.hub then AE.hub:removeFromUIManager(); AE.hub = nil end
    if AE.overlay then AE.overlay:removeFromUIManager(); AE.overlay = nil end
    -- Overlay under the hub; the gizmo/nodes draw over the world, the hub on top.
    AE.overlay = AnimEditorOverlay:new()
    AE.overlay:initialise(); AE.overlay:addToUIManager()
    AE.hub = AnimForgeWindow:new(60, 80)
    AE.hub:initialise(); AE.hub:addToUIManager()
    AE.panel.boneCombo:select(AE.bone)
    AE.panel:syncSliders()
    forceClip(AE.clip)
    setClipPaused(not AE.playing)
end

closePanel = function()
    saveProject()   -- persist any dialed-in edits for the active project
    forceClip(nil)
    local ap = animPlayer()
    if ap then pcall(function() ap:clearBoneRotationOverrides() end) end  -- drop live keyframe pose
    if AE.timelineWin then AE.timelineWin:removeFromUIManager(); AE.timelineWin = nil end  -- popped timeline (+ its host)
    if AE.hub then AE.hub:removeFromUIManager(); AE.hub = nil end
    AE.panel = nil
    if AE.overlay then AE.overlay:removeFromUIManager(); AE.overlay = nil end
    closeBrowser()
end

-- Rebindable keybind (Options > Key Bindings > Anim Forge). Default HOME.
local KEYBIND = "Toggle Anim Forge"
local function registerKeybind()
    for _, kb in ipairs(keyBinding) do
        if kb.value == KEYBIND then return end   -- already registered (reload-safe)
    end
    table.insert(keyBinding, { value = "[Anim Forge]" })
    table.insert(keyBinding, { value = KEYBIND, key = Keyboard.KEY_HOME })
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

-- ------------------------------------------------------------- bridge ops ---
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

-- Push the MCP's pz_anim_list_clips result into the editor so mod clips appear in the "Mods"
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

-- ----------------------------------------- reload attachment-marker editor bridge ops ----
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
    return { ok = true, count = #AE.rfx.reloads, reloads = AE.rfx.reloads }
end)

D.register("anim_rfx_load", "client", function(args)
    loadReloadsFromCache()
    local key = args and (args.animId or args.nodeFile)
    local reload = rfxFindReload(key)
    if not reload and not key then reload = rfxFirstEditable() end
    if not reload then return { error = "reload not found; run pz_anim_list_reloads first" } end
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
    if event ~= "gwSetProp" and event ~= "gwPartToHand" and event ~= "gwPartToGun" then
        return { error = "event must be gwSetProp / gwPartToHand / gwPartToGun" }
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

-- Open the "Reload Attachments" editor window for a reload (loads it + live preview). No animId ->
-- the first discovered reload. This is what the hub task tile calls.
D.register("anim_rfx_open", "client", function(args)
    loadReloadsFromCache()
    local key = args and (args.animId or args.nodeFile)
    local reload = rfxFindReload(key)
    if not reload and not key then reload = rfxFirstEditable() end
    if not reload then return { error = "no reload found; run pz_anim_list_reloads first" } end
    if not openReloadFx(reload) then return { error = "could not open (Gunworks missing / no gun / no attach location)" } end
    return { ok = true, animId = AE.rfx.animId, clip = AE.rfx.clip, markers = AE.rfx.markers }
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
-- mode, and export an emote without clicking. The pose/project/gw bridge cmds
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
-- pose (AE.deltas on the base clip), so wire-emote / pz_anim_bake can build it.
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
    local writer = getFileWriter("AgentBridge/anim_edit.json", true, false)
    writer:write(AnimForge.JSON.encode(data)); writer:close()
    return { saved = true, emote = data.emote }
end)
