-- Persistent named projects for the Anim Grip Editor.
-- A project bundles a weapon category's grip checklist with the per-clip edits
-- (keyframes) and a per-clip "done" flag, so a custom gun's whole animation set
-- can be saved, reloaded, and tracked to completion. Stored on disk under
-- ~/Zomboid/Lua/AgentBridge/anim_projects/ so projects survive Core.ResetLua.
-- Kahlua exposes no directory enumeration, so an index.json lists the projects
-- (slug -> summary) while each project's heavy keyframe data lives in its own
-- <slug>.json. Client-only dev tool: no world/inventory state, nothing to sync.
--
-- Two project shapes share this store, distinguished by an optional `type` field:
--   "grip"     (default) - the original grip checklist: { name, slug, weapon,
--               namePrefix, mod, tag, useAll, clips, perClip }.
--   "gunworks"          - a Gunworks-reload project: the grip fields above PLUS a
--               `gunworks` config block { animId, fullTypes (array), archetype,
--               style, prop = { item }, sprite, attachments, shortRackAfterInsert,
--               luaNamespace, mod, build } and a `stages` block keyed by stage
--               (load / loadShort / rack / unload), each
--               { baseClip, duration, blendTime, done, keyframes, deltas, events }.
-- All blocks are plain serializable tables; save/load round-trip the whole project
-- table, so the new fields persist losslessly without per-field handling. The index
-- summary additionally carries `type` so the loader can branch without a full read.
require "AnimForge/JSON"

AnimForge = AnimForge or {}
AnimForge.AnimProjects = AnimForge.AnimProjects or {}
local P = AnimForge.AnimProjects
local JSON = AnimForge.JSON

local DIR = "AgentBridge/anim_projects/"
local INDEX = DIR .. "index.json"

--- Turn a display name into a filesystem-safe slug (lowercase alphanumerics, runs
--- of anything else collapsed to a single underscore). Empty input -> "set".
---@param name string
---@return string
local function slugify(name)
    local s = string.lower(tostring(name or ""))
    s = s:gsub("[^%a%d]+", "_")
    s = s:gsub("^_+", "")
    s = s:gsub("_+$", "")
    if s == "" then return "set" end
    return s
end
P.slugify = slugify

--- Read + decode a JSON file under ~/Zomboid/Lua, or nil if missing/empty.
---@param path string
---@return table|nil
local function readJson(path)
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
    return JSON.decode(content)
end

--- Encode + write a table as JSON to a file under ~/Zomboid/Lua (creates dirs).
---@param path string
---@param tbl table
local function writeJson(path, tbl)
    local writer = getFileWriter(path, true, false)
    writer:write(JSON.encode(tbl))
    writer:close()
end

--- The project index: { order = {slug,...}, meta = { [slug] = {name,weapon,total,done,updated} } }.
--- A fresh structure is returned when the file does not exist yet.
---@return table
local function readIndex()
    local idx = readJson(INDEX)
    if type(idx) ~= "table" then idx = {} end
    if type(idx.order) ~= "table" then idx.order = {} end
    if type(idx.meta) ~= "table" then idx.meta = {} end
    return idx
end

--- True if a stage table holds at least one keyframed bone (so it counts as "edited").
---@param stage table|nil
---@return boolean
local function stageEdited(stage)
    local kf = stage and stage.keyframes
    if not kf then return false end
    for _ in pairs(kf) do return true end
    return false
end

--- Count done / edited / total stages for a gunworks project. A stage is "edited" when
--- it has at least one keyframed bone, "done" when its per-stage flag is set. The stage
--- universe is the project's `stages` keys (so it matches whatever the archetype seeded).
---@param project table
---@return integer done
---@return integer edited
---@return integer total
local function gunworksProgress(project)
    local stages = (project and project.stages) or {}
    local total, done, edited = 0, 0, 0
    for _, stage in pairs(stages) do
        total = total + 1
        if stage.done then done = done + 1 end
        if stageEdited(stage) then edited = edited + 1 end
    end
    return done, edited, total
end
P.gunworksProgress = gunworksProgress

--- Count done / edited / total units for a project. For grip projects a unit is a clip
--- (edited = at least one keyframed bone, done = per-clip flag); for gunworks projects a
--- unit is a reload stage (counted from the `stages` block). The `type` field selects.
---@param project table
---@return integer done
---@return integer edited
---@return integer total
function P.progress(project)
    if project and project.type == "gunworks" then
        return gunworksProgress(project)
    end
    local clips = (project and project.clips) or {}
    local perClip = (project and project.perClip) or {}
    local total, done, edited = #clips, 0, 0
    for i = 1, total do
        local pc = perClip[clips[i]]
        if pc then
            if pc.done then done = done + 1 end
            local kf = pc.keyframes
            if kf then
                for _ in pairs(kf) do edited = edited + 1; break end
            end
        end
    end
    return done, edited, total
end

--- Saved projects as an ordered array of summary rows (no keyframe data loaded).
---@return table[] rows  -- each { slug, name, weapon, type, total, done, updated }
---@nodiscard
function P.list()
    local idx = readIndex()
    local out = {}
    for i = 1, #idx.order do
        local slug = idx.order[i]
        local m = idx.meta[slug]
        if m then
            out[#out + 1] = {
                slug = slug, name = m.name, weapon = m.weapon,
                type = m.type or "grip",
                total = m.total or 0, done = m.done or 0, updated = m.updated,
            }
        end
    end
    return out
end

--- Load a full project (with per-clip keyframes) by slug, or nil if not found.
---@param slug string
---@return table|nil
---@nodiscard
function P.load(slug)
    if not slug or slug == "" then return nil end
    return readJson(DIR .. slug .. ".json")
end

--- Persist a project to disk and refresh its index entry. Stamps `slug`/`updated`
--- on the table. Returns the slug used (derived from name when not already set).
--- The whole `project` table is written verbatim, so any additive fields (the
--- `gunworks` config + `stages` blocks for a gunworks project) persist losslessly.
---@param project table  -- grip: { name, weapon, namePrefix, mod, tag, useAll, clips, perClip }; gunworks: + type, gunworks, stages
---@return string slug
function P.save(project)
    local slug = project.slug
    if not slug or slug == "" then slug = slugify(project.name) end
    project.slug = slug
    if not project.type or project.type == "" then project.type = "grip" end
    project.updated = getTimestampMs()
    local done, _, total = P.progress(project)
    writeJson(DIR .. slug .. ".json", project)
    local idx = readIndex()
    if not idx.meta[slug] then idx.order[#idx.order + 1] = slug end
    idx.meta[slug] = {
        name = project.name, weapon = project.weapon, type = project.type,
        total = total, done = done, updated = project.updated,
    }
    writeJson(INDEX, idx)
    return slug
end

--- Drop a project from the index so it no longer lists/loads. The orphaned
--- <slug>.json is left on disk (Kahlua cannot delete files) but is unreachable.
---@param slug string
---@return boolean removed
function P.delete(slug)
    if not slug or slug == "" then return false end
    local idx = readIndex()
    if not idx.meta[slug] then return false end
    idx.meta[slug] = nil
    for i = #idx.order, 1, -1 do
        if idx.order[i] == slug then table.remove(idx.order, i) end
    end
    writeJson(INDEX, idx)
    return true
end
