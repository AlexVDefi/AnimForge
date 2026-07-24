-- Active-mod + weapon enumeration for the editor's Target-mod dropdown and gun picker.
-- Reads live script data each call (no dependency on the pz-anim-forge scan caches), so a
-- gun mod enabled alongside Anim Forge is found and selectable the moment a save is loaded.

AnimForge = AnimForge or {}
local Mods = {}
AnimForge.Mods = Mods

-- Mods that provide the framework / tooling, never an animation target: Anim Forge itself, and the
-- Gunworks (SWMG) reload framework it wires into. Add any other framework mod id here to hide it from
-- the gun picker.
local FRAMEWORK = {
    AnimForge = true, SWMG = true,
}

--- Extract the owning mod folder id from a script's source path
--- (e.g. ".../mods/MyGunMod/42/media/scripts/x.txt" -> "MyGunMod").
---@param fileName string|nil
---@return string|nil
local function modIdFromFileName(fileName)
    if not fileName then return nil end
    return fileName:match("[/\\][Mm]ods[/\\]([^/\\]+)[/\\]")
end

--- Map each active mod's FOLDER name and its id (both lowercased) to a shared entry `{ dir, id, name }`.
--- Script file paths carry the mod's FOLDER, but getActivatedMods() returns the mod.info `id`, which can
--- differ (e.g. folder "GunsOfMarz" but id "MarzGuns"). getModInfoByID(id):getDir() gives that mod's
--- location as a FULL path (e.g. C:\...\mods\GunsOfMarz), so we take its basename for the folder. Keying
--- by both folder and id lets a path-derived folder resolve to an active mod either way. `dir` is the
--- bare folder the tool writes to (what the exporter resolves under ~/Zomboid/mods); `name` is the
--- display label; `id` is the mod.info id.
---@return table<string, table>
local function activeModMap()
    local map = {}
    local am = getActivatedMods()
    if not am then return map end
    for i = 0, am:size() - 1 do
        local id = am:get(i):gsub("^\\", "")
        local info = getModInfoByID(id)
        local folder, name = id, nil
        if info then
            local d = info:getDir()                                   -- a FULL path, not the bare folder
            if d and d ~= "" then folder = d:match("([^/\\]+)[/\\]*$") or d end
            local n = info:getName(); if n and n ~= "" then name = n end
        end
        local entry = { dir = folder, id = id, name = name or folder }
        map[folder:lower()] = entry
        if id:lower() ~= folder:lower() then map[id:lower()] = entry end
    end
    return map
end

--- The mod that owns a script item. `item:getModID()` is the mod.info id the script loader recorded,
--- and it is reliable across every load layout (Steam on/off, ~/Zomboid/mods, Workshop staging). The
--- file path is NOT: depending on how a mod loads, getFileName() can be a media-relative path with no
--- mod folder in it (e.g. "media/scripts/..."), so it is only a last-resort fallback here.
---@param item Item
---@return string|nil
local function itemModKey(item)
    local mid
    pcall(function() mid = item:getModID() end)
    if mid and mid ~= "" then return mid end
    return modIdFromFileName(item:getFileName())
end

--- Active mods that own at least one ranged weapon, each with its sorted weapon fullTypes.
--- Shape: { { id = "MyGunMod", name = "My Gun Mod", weapons = { "MyMod.M4CARBINE", ... } }, ... }
---@return table[]
function Mods.scanGunMods()
    local activeMap = activeModMap()
    local byMod, order = {}, {}
    local sm = getScriptManager()
    local items = sm and sm:getAllItems()
    if items then
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item and item:isRanged() then
                local key = itemModKey(item)
                local entry = key and activeMap[key:lower()]
                if entry and not FRAMEWORK[entry.dir] and not FRAMEWORK[entry.id] then
                    local bucket = byMod[entry.dir]
                    if not bucket then
                        bucket = { id = entry.dir, name = entry.name, weapons = {} }
                        byMod[entry.dir] = bucket
                        order[#order + 1] = bucket
                    end
                    bucket.weapons[#bucket.weapons + 1] = item:getFullName()
                end
            end
        end
    end
    for i = 1, #order do table.sort(order[i].weapons) end
    return order
end

--- Display names + a parallel id list of the scanned gun mods (for a combo).
---@return string[] names, string[] ids
function Mods.gunModChoices()
    local mods = Mods.scanGunMods()
    local names, ids = {}, {}
    for i = 1, #mods do
        names[i] = mods[i].name
        ids[i] = mods[i].id
    end
    return names, ids
end

--- The weapon fullTypes owned by one mod id.
---@param modId string
---@return string[]
function Mods.weaponsForMod(modId)
    local mods = Mods.scanGunMods()
    for i = 1, #mods do
        if mods[i].id == modId then return mods[i].weapons end
    end
    return {}
end

--- The weapon parts from a mod that can mount on a given gun. The gun's own ModelWeaponPart list
--- is not Lua-reachable, so each of the mod's items is instantiated and its runtime WeaponPart
--- MountOn is checked against the gun fullType. Shape: { { fullType, partType }, ... }.
---@param modId string
---@param gunFullType string
---@return table[]
function Mods.attachmentsForGun(modId, gunFullType)
    local out = {}
    if not modId or not gunFullType then return out end
    local activeMap = activeModMap()
    local sm = getScriptManager()
    local items = sm and sm:getAllItems()
    if items then
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item then
                local key = itemModKey(item)
                local entry = key and activeMap[key:lower()]
                if entry and entry.dir == modId then
                    local inst = instanceItem(item:getFullName())
                    if inst and instanceof(inst, "WeaponPart") then
                        local mo = inst:getMountOn()
                        if mo then
                            for j = 0, mo:size() - 1 do
                                if mo:get(j) == gunFullType then
                                    out[#out + 1] = { fullType = item:getFullName(), partType = inst:getPartType() }
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return out
end

--- Picker row for a fullType: its display name + icon texture (nil if it can't be resolved).
---@param fullType string
---@return table  { fullType, name, tex }
function Mods.itemInfo(fullType)
    local inst = instanceItem(fullType)
    return {
        fullType = fullType,
        name = (inst and inst:getName()) or fullType,
        tex = inst and inst:getTex() or nil,
    }
end

--- Picker rows for every weapon in a mod: { { fullType, name, tex }, ... }.
---@param modId string
---@return table[]
function Mods.gunInfos(modId)
    local out = {}
    local guns = Mods.weaponsForMod(modId)
    for i = 1, #guns do out[i] = Mods.itemInfo(guns[i]) end
    return out
end

--- A script item's display name without instantiating it (cheap for big lists).
---@param item Item
---@return string
local function scriptName(item)
    local dn = item:getDisplayName()
    if dn == nil or dn == "" then return item:getFullName() end
    return dn
end

--- The mountable attachments for a gun, as picker rows { fullType, name, tex, partType }.
---@param modId string
---@param gunFullType string
---@return table[]
function Mods.attachmentInfos(modId, gunFullType)
    local parts = Mods.attachmentsForGun(modId, gunFullType)
    local out = {}
    for i = 1, #parts do
        local info = Mods.itemInfo(parts[i].fullType)
        info.partType = parts[i].partType
        out[i] = info
    end
    return out
end

--- Every item a mod owns, as lightweight picker rows { fullType, name } (icon resolved lazily by the
--- picker, since a mod can have many items). Sorted by name.
---@param modId string
---@return table[]
function Mods.modItemInfos(modId)
    local out = {}
    if not modId or modId == "" then return out end
    local activeMap = activeModMap()
    local sm = getScriptManager()
    local items = sm and sm:getAllItems()
    if items then
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item then
                local key = itemModKey(item)
                local entry = key and activeMap[key:lower()]
                if entry and entry.dir == modId then
                    out[#out + 1] = { fullType = item:getFullName(), name = scriptName(item) }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

--- Every base-game item (module "Base"), built once and cached. Rows { fullType, name }; the picker
--- resolves the icon lazily and gates on a search query, so the ~thousands of rows stay responsive.
local _baseItems = nil
---@return table[]
function Mods.baseItemInfos()
    if _baseItems then return _baseItems end
    local out = {}
    local sm = getScriptManager()
    local items = sm and sm:getAllItems()
    if items then
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item and item:getModuleName() == "Base" then
                out[#out + 1] = { fullType = item:getFullName(), name = scriptName(item) }
            end
        end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    _baseItems = out
    return out
end

return Mods
