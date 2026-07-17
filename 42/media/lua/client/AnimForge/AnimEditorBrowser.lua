-- Anim Forge editor: the animation browser (live 3D thumbnail grid) + Gunworks helpers.
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

local applyBone = AnimForge.EditCore.applyBone
local clipEdited = AnimForge.EditCore.clipEdited
local forceClip = AnimForge.EditCore.forceClip
local loadModClipsFromCache = AnimForge.EditCore.loadModClipsFromCache
local loadProject = AnimForge.EditCore.loadProject
local newProject = AnimForge.EditCore.newProject
local projectProgress = AnimForge.EditCore.projectProgress
local saveProject = AnimForge.EditCore.saveProject
local setClipDone = AnimForge.EditCore.setClipDone
local setClipPaused = AnimForge.EditCore.setClipPaused
local setClipTime = AnimForge.EditCore.setClipTime
local AE = AnimForge.AnimEdit

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
    animId = "", fullTypes = "", style = "attachment", propItem = "",
    spriteLoaded = "", spriteUnloaded = "", build = "42.13",
    luaNamespace = "", mod = "", shortRackAfterInsert = false,
    visualMag = false, magInsertPc = 0.55, magEjectPc = 0.45,
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
    -- Magazine unload is the load motion in reverse (mag eject); preview it reversed so it matches
    -- the baked node's m_AnimReverse instead of looking identical to the load stage.
    local p = getPlayer()
    local ap = p and p:getAnimationPlayer()
    if ap then
        pcall(function() ap:setForcedEditClipReversed(key == "unload" and AE.gw.archetype == "magazine") end)
    end
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

-- Seed (or clear) the visual-mag part markers into the load + unload stage events from config.
-- Routing-safe: each marker is authored into its OWN stage's `events`, which wire-gunworks bakes
-- into that stage's own node XML (never a shared flat list). gwPartToGun (load) moves the mag from
-- the off-hand onto the gun; gwPartToHand (unload) reverses it; gwSetProp shows/hides it at the edges.
function GW.applyVisualMag()
    local cfg = AE.gw.config
    local MAG_EVENTS = { gwSetProp = true, gwPartToGun = true, gwPartToHand = true }
    local function stripMag(events)
        local out = {}
        for i = 1, #(events or {}) do
            if not MAG_EVENTS[events[i].event] then out[#out + 1] = events[i] end
        end
        return out
    end
    local load = AE.gw.stages.load
    local unload = AE.gw.stages.unload
    if load then load.events = stripMag(load.events) end
    if unload then unload.events = stripMag(unload.events) end
    if not cfg.visualMag or AE.gw.archetype ~= "magazine" then return end
    local mag = cfg.propItem
    if not mag or mag == "" then return end
    if load then
        load.events[#load.events + 1] = { event = "gwSetProp", timePc = 0.08, value = mag }
        load.events[#load.events + 1] = { event = "gwPartToGun", timePc = cfg.magInsertPc or 0.55, value = mag }
    end
    if unload then
        unload.events[#unload.events + 1] = { event = "gwPartToHand", timePc = cfg.magEjectPc or 0.45, value = mag }
        unload.events[#unload.events + 1] = { event = "gwSetProp", timePc = 0.92, value = "" }
    end
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
    -- The watcher resolves the target mod from block.mod; without it the auto-bake logs
    -- "mod 'None' not found" and silently skips wire-gunworks (no node -> never in the picker).
    if cfg.mod and cfg.mod ~= "" then block.mod = cfg.mod end
    if cfg.style and cfg.style ~= "" then block.style = cfg.style end
    if cfg.luaNamespace and cfg.luaNamespace ~= "" then block.luaNamespace = cfg.luaNamespace end
    if cfg.shortRackAfterInsert then block.shortRackAfterInsert = true end
    if cfg.propItem and cfg.propItem ~= "" then block.prop = { item = cfg.propItem } end
    if cfg.style == "sprite" then
        block.sprite = { loaded = cfg.spriteLoaded, unloaded = cfg.spriteUnloaded }
    elseif cfg.style == "attachment" and cfg.propItem and cfg.propItem ~= "" then
        -- Magazine detaches as a WeaponPart: the mag item is both the off-hand prop and the
        -- part swapped on the gun (a minimal magPart = { itemType }).
        block.magItem = cfg.propItem
        block.attachments = { magPart = { itemType = cfg.propItem } }
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
    local writer = getFileWriter("AnimForge/anim_edit.json", true, false)
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
        style = cfg.style or "attachment", propItem = (cfg.prop and cfg.prop.item) or "",
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
    loadModClipsFromCache()   -- keep the "Mods" tab in sync with the cached discovery list
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


AnimForge.Browser = {
    GW = GW,
    closeBrowser = closeBrowser,
    openBrowser = openBrowser,
    selectClipInEditor = selectClipInEditor
}
