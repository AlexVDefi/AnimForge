-- Anim Forge editor: the hub window (nav rail + per-mode content) and open/close.
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
require "AnimForge/AnimEditorPanel"
require "AnimForge/AnimEditorOverlay"
require "AnimForge/AnimEditorBrowser"
require "AnimForge/AnimEditorReloadFx"

local GW = AnimForge.Browser.GW
local closeBrowser = AnimForge.Browser.closeBrowser
local openBrowser = AnimForge.Browser.openBrowser
local selectClipInEditor = AnimForge.Browser.selectClipInEditor
local animPlayer = AnimForge.EditCore.animPlayer
local forceClip = AnimForge.EditCore.forceClip
local loadProject = AnimForge.EditCore.loadProject
local loadReloadsFromCache = AnimForge.EditCore.loadReloadsFromCache
local newProject = AnimForge.EditCore.newProject
local projectProgress = AnimForge.EditCore.projectProgress
local readJsonFile = AnimForge.EditCore.readJsonFile
local rfxEditableReloads = AnimForge.EditCore.rfxEditableReloads
local rfxGroupedReloads = AnimForge.EditCore.rfxGroupedReloads
local saveProject = AnimForge.EditCore.saveProject
local setClipPaused = AnimForge.EditCore.setClipPaused
local openReloadFx = AnimForge.ReloadFx.openReloadFx
local AE = AnimForge.AnimEdit
local AP = AnimForge.AnimProjects

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
local STYLE_OPTS = { "attachment", "sprite" }

-- The task modes (drive the nav, the landing tiles, and routing). `pose` = the mode
-- embeds the pose editor; `setup` = it shows a setup form.
local MODES = {
    grip      = { label = "New grip set",     group = "Create", pose = true,
                  purpose = "Make a custom gun's held + aim animation set.",
                  how = "Name it, pick the weapon family + target mod, Create, then pose each clip from the Browser.",
                  whenDone = "Sign off every clip (green), then Export set to your mod." },
    reload    = { label = "New reload",         group = "Create", pose = false,
                  purpose = "Build a Gunworks reload (load / rack / unload stages).",
                  how = "Name the set + archetype + mod and Create; then per stage pick its animation (vanilla or a custom clip your mod loaded), tweak the pose + duration, and fill the gun config.",
                  whenDone = "Add the gun fullType, then Export reload pack -> mod. With the watcher running it builds + goes live instantly - open Reload attachments to tune it." },
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
                  whenDone = "Save to mod - with the Anim Forge watcher running the retimed markers go live instantly, no reboot needed." },
    testrig   = { label = "Equipment", navLabel = "Equipment", group = "Quick", pose = false,
                  purpose = "Equip a gun from your mod + toggle its attachments on the player.",
                  how = "Pick a weapon and Equip; tick attachments to fit. The gun stays equipped while you pose in any mode.",
                  whenDone = "Switch to a pose or reload mode - the equipped gun + parts show on the character." },
}
local MODE_ORDER = { "grip", "reload", "emote", "open", "resume", "duplicate", "override", "reloadfx", "testrig" }

-- Modes that only make sense with Gunworks (SWMG) installed; hidden from the nav rail + landing
-- launcher when it is not active.
local GUNWORKS_MODES = { reload = true, reloadfx = true }

---@param key string
---@return boolean
local function modeAvailable(key)
    if not GUNWORKS_MODES[key] then return true end
    local mods = getActivatedMods()
    if mods and mods:contains("SWMG") then return true end
    return false
end

-- Nav entries: a Menu (launcher) shortcut, then grouped headers + one row per available mode. Built
-- on open so the Gunworks-only modes reflect whether SWMG is currently active (an empty group's
-- header is dropped too).
---@return table
local function buildNavDefs()
    local groups = { "Create", "Open", "Quick" }
    local defs = { { key = "home", label = "< Menu" } }
    for gi = 1, #groups do
        local g = groups[gi]
        local rows = {}
        for ki = 1, #MODE_ORDER do
            local key = MODE_ORDER[ki]
            if MODES[key].group == g and modeAvailable(key) then
                rows[#rows + 1] = { key = key, label = MODES[key].navLabel or MODES[key].label }
            end
        end
        if #rows > 0 then
            defs[#defs + 1] = { header = g }
            for ri = 1, #rows do defs[#defs + 1] = rows[ri] end
        end
    end
    return defs
end

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
    if not modeAvailable(o.mode) then o.mode = "home" end   -- last mode became Gunworks-only + SWMG left
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

-- Short, readable label for a reload clip in the stage selector.
local function reloadClipLabel(clip)
    return (clip:gsub("^Bob_Reload_", ""):gsub("^Bob_", ""))
end

-- The clips a reload stage can use: THIS mod's own custom clips first (what "use a custom animation"
-- means -- from mod_clips.json, filtered to the reload's target mod so you don't drown in every other
-- mod's clips), then every vanilla reload base clip (across all archetypes). Each row is
-- { clip = <force-play name>, label = <short display>, mod = <bool> }.
local function reloadClipChoices(modId)
    local out, seen = {}, {}
    for i = 1, #(AE.modClipNames or {}) do
        local clip = AE.modClipNames[i]
        local meta = AE.modClips[clip]
        if clip and not seen[clip] and meta and (not modId or modId == "" or meta.mod == modId) then
            seen[clip] = true
            out[#out + 1] = { clip = clip, label = reloadClipLabel(clip) .. "  (mod)", mod = true }
        end
    end
    local vanilla = {}
    local arch = AnimForge.AnimCategories and AnimForge.AnimCategories.reloadArchetypes
    if arch then
        for _, a in pairs(arch) do
            for _, s in pairs(a.stages or {}) do
                if s.baseClip and not seen[s.baseClip] then seen[s.baseClip] = true; vanilla[#vanilla + 1] = s.baseClip end
            end
        end
    end
    table.sort(vanilla)
    for i = 1, #vanilla do out[#out + 1] = { clip = vanilla[i], label = reloadClipLabel(vanilla[i]) } end
    return out
end

-- Populate a combo with the active gun mods (option text = display name, data = mod id).
function AnimForgeWindow:populateModCombo(combo)
    combo:clear()
    local names, ids = AnimForge.Mods.gunModChoices()
    if #names == 0 then
        combo:addOptionWithData("(enable a gun mod)", nil, "Enable a gun mod alongside Anim Forge, then reopen.")
    else
        for i = 1, #names do combo:addOptionWithData(names[i], ids[i], nil) end
        combo.selected = 1
    end
end

-- The mod id stored on the combo's selected option (or "").
function AnimForgeWindow:selectedModId(combo)
    if not combo or not combo.selected then return "" end
    return combo:getOptionData(combo.selected) or ""
end

-- Select the combo option whose data matches modId.
function AnimForgeWindow:selectModInCombo(combo, modId)
    if not combo or not modId or modId == "" or not combo.options then return end
    for i = 1, #combo.options do
        if combo:getOptionData(i) == modId then combo.selected = i; return end
    end
end

-- Populate a combo with a mod's weapon fullTypes (option text = data = fullType).
function AnimForgeWindow:populateGunCombo(combo, modId)
    combo:clear()
    local guns = (modId and modId ~= "") and AnimForge.Mods.weaponsForMod(modId) or {}
    if #guns == 0 then
        combo:addOptionWithData("(no weapons found)", nil, nil)
    else
        for i = 1, #guns do combo:addOptionWithData(guns[i], guns[i], nil) end
        combo.selected = 1
    end
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
    self.nav:setEntries(buildNavDefs())

    -- scrollable content container: all mode widgets + the pose editor live in here. Created + added
    -- BEFORE the header band so the header (added after) draws ON TOP of it. Combos inside the content
    -- clear the scroll stencil mid-render, so rows scrolled up past the content's top edge can bleed
    -- upward; the opaque header band drawn on top hides that bleed.
    self.headerH = HEADER_H
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

    -- opaque header band, added AFTER content so it renders over any upward bleed. It paints the bg0
    -- backdrop for the band plus the header extras (grip progress + auto-bake watcher status); the
    -- help-text panel is a child added just after, so it sits on top of this fill.
    local win = self
    self.headerBg = ISPanel:new(self.contentX, th, self.contentW, HEADER_H)
    self.headerBg.background = false
    self.headerBg:initialise(); self:addChild(self.headerBg)
    self.headerBg.prerender = function(s)
        s:drawRect(0, 0, s:getWidth(), s:getHeight(), 1, T.col.bg0[1], T.col.bg0[2], T.col.bg0[3])
        win:drawHeaderExtras(s)
    end

    -- instructional header text (window child, above the scroll area). Height is set per-mode by
    -- layoutHeader() from the paginated text; HEADER_H is only the initial band.
    self.header = HelpHeader:new(self.contentX + T.sp.m, th + T.sp.xs, self.contentW - T.sp.m * 2, HEADER_H - T.sp.s)
    self.header:initialise(); self:addChild(self.header)

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
    -- ---- landing launcher: a 2-col tile per available mode ----
    do
        local tileH = 54
        local tiles = {}
        for i = 1, #MODE_ORDER do
            if modeAvailable(MODE_ORDER[i]) then tiles[#tiles + 1] = MODE_ORDER[i] end
        end
        for i = 1, #tiles do
            local key = tiles[i]
            local c = (i - 1) % 2
            local r = math.floor((i - 1) / 2)
            local tx = x
            if c ~= 0 then tx = x2 end
            local b = self:mkButton(tx, y + r * (tileH + gap), hw, tileH,
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
        self.gripMod = self:add("grip", self:mkCombo(x2, y + 16, hw, {}, nil,
            "Active gun mod the set exports into (auto-detected)."))
        self:add("grip", self:mkLabel(x, y + 44, "Weapon"))
        self.gripWeapon = self:add("grip", self:mkCombo(x, y + 60, hw, AnimForge.AnimCategories.order, AE.weapon,
            "Weapon family whose grip/aim clips you'll pose."))
        self.gripCreate = self:add("grip", self:mkButton(x2, y + 58, hw, 24, "Create", AnimForgeWindow.onGripCreate,
            T.styleGhost, "Create the set + open the Browser to pose each clip."))
        self:populateModCombo(self.gripMod)
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
            "No reloads found. Run 'pz-anim-forge scan' first, then reopen this.", T.col.muted))
    end
    -- ---- test rig: two-column equip + attachment panel (also poppable) ----
    do
        self.rigPopBtn = self:add("testrig", self:mkButton(x, y, 120, 22, "Pop out",
            AnimForgeWindow.onRigPopOut, T.styleGhost,
            "Open the test rig in its own window that stays open while you work in the other panels."))
        self.rigPanel = AnimForgeTestRig:new(x, y + 28, w, 200)
        self.rigPanel:initialise(); self.rigPanel:instantiate()
        self.content:addChild(self.rigPanel)
        self.rigPanel:setVisible(false)
        self:add("testrig", self.rigPanel)
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
    self.rMod = create(self:mkCombo(x2, y + 16, hw, {}, nil,
        "Active gun mod the reload pack exports into (auto-detected)."))
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
        -- base-animation selector: vanilla load/rack/unload clips + any custom clips the mod loaded.
        row.clip = post(self:mkCombo(x + 78, sy + 2, w - 158 - (x + 78) - 6, {}, nil,
            "Base animation for this stage: a vanilla reload clip, or a custom clip your mod loaded."))
        row.clip.onChange = AnimForgeWindow.onReloadStageClip
        row.dur   = post(self:mkField(w - 158, sy + 2, 44, "", "auto", true,
            "Stage duration in seconds (blank = vanilla default)."))
        row.edit  = post(self:mkButton(w - 100, sy, 100, 22, "Edit pose", AnimForgeWindow.onReloadEditStage,
            T.styleGhost, "Load this stage's clip into the pose editor."))
        self.rStageRows[i] = row
        sy = sy + 26
    end

    -- Clean base clips + Edit attachments, side by side under the stage rows.
    -- Clean base: bake despiked shared copies of the stock reload clips into the mod and set them as the
    -- stage base clips, so the pose preview + the shipped reload use a jitter-free base (the off-hand prop
    -- stops jumping on the vanilla spike keyframes). Auto-runs for magazine reloads.
    self.rCleanBase = post(self:mkButton(x, sy + 2, hw, 22, "Clean base clips",
        AnimForgeWindow.onReloadCleanBase, T.styleGhost,
        "Bake despiked copies of the stock reload clips into the mod + use them as the base, so the "
        .. "off-hand prop follows the hand without the vanilla spike jitter. Idempotent; auto-runs for "
        .. "magazine reloads."))
    -- Edit attachments: open the Reload Attachments editor bound to THIS project (shared markers), so
    -- retimed mag/prop gun<->hand markers show up per stage here and survive a reopen.
    self.rEditAttach = post(self:mkButton(x2, sy + 2, hw, 22, "Edit attachments",
        AnimForgeWindow.onReloadEditAttachments, T.styleGhost,
        "Open the Reload Attachments editor for this reload (retime the mag / prop gun<->hand markers). "
        .. "It shares this reload's markers, so edits show in the per-stage counts above. Export first."))
    sy = sy + 30

    -- ---- config grid (post-create), single column: each field full width ----
    local cy = sy + 8
    -- Guns: searchable, icon-rendering picker (replaces the free-text fullType field). Multi-select.
    post(self:mkLabel(x, cy, "guns (search, click to select)"))
    local PICKER_H = 132
    self.rGunPicker = AnimForgePicker:new(x, cy + 16, w, PICKER_H,
        { multiSelect = true, onSelect = AnimForgeWindow.onReloadGunPicked, target = self })
    self.rGunPicker:initialise()
    self.content:addChild(self.rGunPicker)
    self.rGunPicker:setVisible(false)
    post(self.rGunPicker)

    local cy2 = cy + 16 + PICKER_H + T.sp.s
    local function cfgField(rowI, label, value, ph, tip)
        local ry = cy2 + rowI * 26
        post(self:mkLabel(x, ry + 3, label))
        return post(self:mkField(x + lblW, ry, w - lblW, value, ph, false, tip))
    end
    self.rNamespace = cfgField(0, "lua namespace", AE.gw.config.luaNamespace, "MyMod",
        "Lua require dir under media/lua/shared (default = mod name).")
    self.rProp = cfgField(1, "off-hand prop", AE.gw.config.propItem, "NA.STANAG_MAG_ATTACHMENT",
        "Off-hand prop / magazine item (attachment style: the part that detaches from the gun).")
    self.rBuild = cfgField(2, "build", AE.gw.config.build, "42.13", "Mod build subfolder (e.g. 42.13).")
    local syc = cy2 + 3 * 26
    post(self:mkLabel(x, syc + 3, "style"))
    self.rStyle = post(self:mkCombo(x + lblW, syc, 120, STYLE_OPTS, AE.gw.config.style,
        "attachment = the magazine detaches as a part; sprite = swap the whole gun sprite."))
    self.rStyle.onChange = AnimForgeWindow.updateReloadStyleFields
    self.rShort = ISTickBox:new(x + lblW + 130, syc + 2, 18, 18, "", self, nil)
    self.rShort:initialise(); self.content:addChild(self.rShort); self.rShort:setVisible(false)
    self.rShort:addOption("short rack after insert"); self.rShort:setSelected(1, AE.gw.config.shortRackAfterInsert == true)
    self.rShort.tooltip = "Mag-fed: play a short rack after inserting a partial mag."
    post(self.rShort)
    local sl5 = cy2 + 4 * 26
    self.rSpriteLLabel = post(self:mkLabel(x, sl5 + 3, "sprite loaded"))
    self.rSpriteL = post(self:mkField(x + lblW, sl5, w - lblW, AE.gw.config.spriteLoaded, "Mod.GunLoaded", false,
        "style=sprite: gun sprite while loaded."))
    local sl6 = cy2 + 5 * 26
    self.rSpriteULabel = post(self:mkLabel(x, sl6 + 3, "sprite unloaded"))
    self.rSpriteU = post(self:mkField(x + lblW, sl6, w - lblW, AE.gw.config.spriteUnloaded, "Mod.GunEmpty", false,
        "style=sprite: gun sprite while unloaded."))

    -- visual mag reload: one checkbox that seeds the mag detach/attach markers onto the load + unload
    -- stages at default timings. Shares the sprite rows (sprite style shows the sprite fields, magazine
    -- attachment style shows this instead - updateReloadStyleFields toggles which is visible). Fine-tune
    -- the seeded timings later in 'Reload attachments'.
    local vmy = cy2 + 4 * 26
    self.rVisualMag = ISTickBox:new(x, vmy, 18, 18, "", self, AnimForgeWindow.onVisualMagToggle)
    self.rVisualMag:initialise(); self.content:addChild(self.rVisualMag); self.rVisualMag:setVisible(false)
    self.rVisualMag:addOption("visual mag reload (mag moves gun <-> hand)")
    self.rVisualMag:setSelected(1, AE.gw.config.visualMag == true)
    self.rVisualMag.tooltip = "Seed markers so the magazine visibly detaches to the hand + re-attaches, at default timings. Uses the off-hand prop item as the mag. Fine-tune the timing later in 'Reload attachments'. Position the mag by posing Bip01_Prop2 in the pose editor."
    post(self.rVisualMag)

    -- Back button lives in the band above the embedded pose editor (only shown while
    -- editing a stage), so it never overlaps the config grid or the pose view.
    self.rBackBtn = self:add("reload", self:mkButton(x, y + 2, 130, 22, "< Back to stages", AnimForgeWindow.onReloadBack, T.styleGhost))

    self:populateModCombo(self.rMod)
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

-- Populate the "Edit reload attachments" task with the reloads the scan cached (refreshed each time
-- the task is opened).
function AnimForgeWindow:refreshReloadFx()
    loadReloadsFromCache()
    local groups = rfxGroupedReloads()
    for i = 1, #self.rfxRows do
        local b = self.rfxRows[i]
        local g = groups[i]
        if g then
            local ns = #g.stages
            local stagesTxt = (ns == 1) and tostring(g.stages[1].stage or "1 stage") or (ns .. " stages")
            b:setTitle("Edit   " .. tostring(g.mod) .. " . " .. tostring(g.animId)
                .. "    (" .. stagesTxt .. ")   "
                .. g.markerCount .. (g.markerCount == 1 and " marker" or " markers"))
            b.reload = g
            b:setVisible(true)
        else
            b.reload = nil
            b:setVisible(false)
        end
    end
    if self.rfxEmpty then self.rfxEmpty:setVisible(#groups == 0) end
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
        if self.headerBg then self.headerBg:setVisible(false) end
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
        if self.headerBg then self.headerBg:setVisible(true) end
        self.content:setVisible(true)
        if self.minBtn then self.minBtn:setTitle("-") end
        self:switchMode(self.mode)   -- restores the mode's widgets + footer + header layout
    end
end

-- Poll the auto-baker heartbeat: the watcher rewrites AnimForge/watcher_status.json every ~2s while
-- it runs, so a fresh timestamp means Save/Export will auto-bake. Throttled to ~1/s; result cached on
-- self.watcherLive for the header pill + the export toast.
function AnimForgeWindow:pollWatcher()
    local nowMs = getTimestampMs()
    if self.watcherPollAt and (nowMs - self.watcherPollAt) < 1000 then return self.watcherLive end
    self.watcherPollAt = nowMs
    local ok, data = pcall(readJsonFile, "AnimForge/watcher_status.json")
    self.watcherLive = (ok and data and data.ts and (nowMs / 1000 - data.ts) < 6) and true or false
    return self.watcherLive
end

-- Drawn on the opaque header band (on top of the scroll content): the auto-bake status pill (top
-- right, always) and the grip mode's progress count (bottom right). Coords are band-local.
function AnimForgeWindow:drawHeaderExtras(s)
    local bw, bh = s:getWidth(), s:getHeight()
    self:pollWatcher()
    local label = self.watcherLive and "Auto-bake: LIVE" or "Auto-bake: OFF"
    local c = self.watcherLive and T.col.ok or T.col.edited
    local fnt = T.font.body
    local tw = getTextManager():MeasureStringX(fnt, label)
    local pw = tw + 16
    local px = bw - pw - T.sp.s
    T.fill(s, px, T.sp.xs, pw, 16, c)
    T.text(s, label, px + 8, T.sp.xs, T.col.accentText, fnt)
    -- Persistent restart-needed badge (left of the auto-bake pill): a build this session wrote brand-new
    -- reload nodes that only enter the engine's boot file map on a restart. Clears itself on reboot (this
    -- Lua state is recreated), which is exactly when the nodes become loadable.
    if AE.restartPending then
        local rl = "Restart to load new reload"
        local rtw = getTextManager():MeasureStringX(fnt, rl)
        local rpw = rtw + 16
        local rpx = px - rpw - T.sp.xs
        T.fill(s, rpx, T.sp.xs, rpw, 16, T.col.danger)
        T.text(s, rl, rpx + 8, T.sp.xs, T.col.accentText, fnt)
    end
    if self.mode == "grip" and AE.project then
        local done, edited, total = projectProgress()
        local txt = done .. "/" .. total .. " done" .. (edited > done and ("  +" .. (edited - done) .. " edited") or "")
        T.textRight(s, txt, bw - T.sp.s, bh - 16, (done >= total and total > 0) and T.col.done or T.col.text2)
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
    if self.headerBg then self.headerBg:setHeight(self.headerH) end
    self.content:setY(cy)
    self.content:setHeight(self.height - cy - FOOTER_H)
    if self.openList and self.modList then
        local listH = self.content:getHeight() - (self.bodyY + 20) - T.sp.s
        self.openList:setHeight(listH); self.modList:setHeight(listH)
    end
end

function AnimForgeWindow:switchMode(key)
    self:hideAll()
    pcall(function() AnimForge.EditCore.rfxEndPosePreview() end)   -- restore gun/props if leaving a reload pose
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
    if key == "testrig" then self:refreshRig() end

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
        -- Save only after the set is created. Shown while posing too, so one button always saves.
        if AE.project and AE.project.type == "gunworks" then
            prim = "Save changes"
        end
    end
    if key == "reload" then
        self.primaryBtn.tooltip = "Save everything you changed in this reload - bone poses AND attachment "
            .. "markers - and bake it into the mod. One button; it pulls in your current pose and any open "
            .. "attachments edits, so you never have to pick which save."
    else
        self.primaryBtn.tooltip = nil
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
    local mod = self:selectedModId(self.gripMod)
    if name == "" or mod == "" then self.toast:set("Enter a set name and pick a target mod first.", "danger"); return end
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
    local mod = self:selectedModId(self.rMod)
    if name == "" or mod == "" then
        self.toast:set("Enter a set name (animId) and pick a target mod first.", "danger"); return
    end
    local key = ARCHETYPE_ORDER[self.rArch.selected or 1]
    if AE.gw.archetypeKey ~= key or not AE.gw.order or #AE.gw.order == 0 then
        if not GW.seedArchetype(key) then self.toast:set("Unknown archetype.", "danger"); return end
    end
    self.reloadEditing = nil
    self:syncReloadConfig()                 -- form -> AE.gw.config
    AE.gw.config.animId = name; AE.gw.config.mod = mod
    GW.applyVisualMag()                     -- seed mag markers into load/unload stage events
    local proj = GW.buildProject(name)
    proj.slug = (AE.project and AE.project.type == "gunworks") and AE.project.slug or nil
    local slug = AP.save(proj)
    AE.project = { name = name, slug = slug, weapon = AE.gw.archetypeKey, type = "gunworks" }
    self:refreshReload()
    -- Magazine reloads jitter the off-hand prop on the vanilla base's spike keyframes; bake clean base
    -- clips up front (silent, no-op without a watcher) so the preview + reload are smooth from the start.
    if AE.gw.archetype == "magazine" then self:bakeCleanBase(true) end
    self.toast:set("Created set '" .. name .. "'. Edit each stage + config, then Export.", "ok")
end

-- The gun picker toggled a weapon; keep config.fullTypes in sync with the current selection.
function AnimForgeWindow:onReloadGunPicked(fullType, isSelected)
    AE.gw.config.fullTypes = table.concat(self.rGunPicker:getSelectedList(), ", ")
end

-- Visual-mag checkbox toggled: seed the default mag markers (when turned on and none exist yet) or
-- strip them (when turned off), persist, and refresh the per-stage counts. This is the deliberate seed
-- action now that export no longer re-derives markers - so toggling it never clobbers retimed markers.
function AnimForgeWindow:onVisualMagToggle(optionIndex, selected)
    self:syncReloadConfig()      -- pull the new checkbox state (+ rest of the form) into cfg
    GW.applyVisualMag()          -- seed-if-empty when on; strip when off
    if AE.project and AE.project.type == "gunworks" then
        local savedActive = AE.gw.activeStage   -- persist without wiping pose deltas (stale AE.deltas)
        if not self.reloadEditing then AE.gw.activeStage = nil end
        AP.save(GW.buildProject(AE.project.name))
        AE.gw.activeStage = savedActive
    end
    self:refreshReload()
end

-- Sprite fields (rows 4-5) and the visual-mag controls share the same rows, mutually exclusive:
-- sprite style shows the sprite pair; attachment style on a magazine shows the visual-mag controls.
function AnimForgeWindow:updateReloadStyleFields()
    local style = comboText(self.rStyle)
    local sprite = style == "sprite"
    local visMag = (style == "attachment") and AE.gw.archetype == "magazine"
    if self.rSpriteLLabel then self.rSpriteLLabel:setVisible(sprite) end
    if self.rSpriteL then self.rSpriteL:setVisible(sprite) end
    if self.rSpriteULabel then self.rSpriteULabel:setVisible(sprite) end
    if self.rSpriteU then self.rSpriteU:setVisible(sprite) end
    if self.rVisualMag then self.rVisualMag:setVisible(visMag) end
    self:updateScroll()
end

-- ---- test rig: size the two-column panel to fill the content, then refresh it ----
function AnimForgeWindow:refreshRig()
    if not self.rigPanel then return end
    local top = self.rigPanel:getY()
    self.rigPanel:setHeight(math.max(120, self.content:getHeight() - top - T.sp.s))   -- fill to bottom
    self.rigPanel:layout()
    self.rigPanel:refresh()
end

-- Pop the test rig into its own resizable window that stays open across panel switches.
function AnimForgeWindow:onRigPopOut()
    if self.rigWin then self.rigWin:removeFromUIManager(); self.rigWin = nil end
    self.rigWin = TestRigWindow:new(self:getRight() + 8, self:getY())
    self.rigWin:initialise(); self.rigWin:instantiate(); self.rigWin:addToUIManager()
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
            row.label:setVisible(on); row.clip:setVisible(on)
            row.dur:setVisible(on); row.edit:setVisible(on)
            if key then
                local s = AE.gw.stages[key] or {}
                -- per-stage attachment-marker count: reflects edits made in the Reload Attachments
                -- editor (the markers live in this same project), so the two surfaces stay visibly in sync.
                local nmk = (s.markers and #s.markers) or 0
                row.label:setName(key .. (nmk > 0 and ("  (" .. nmk .. " mk)") or ""))
                self:populateStageClipCombo(row.clip, s.baseClip)
                row.clip.stageKey = key
                row.dur:setText(s.duration and tostring(s.duration) or "")
                row.edit.stageKey = key
                row.dur.stageKey = key
            end
        end
        -- reflect AE.gw.config in the form (after create / load / back round-trip)
        local c = AE.gw.config
        self.rAnimId:setText(c.animId or ""); self:selectModInCombo(self.rMod, c.mod)
        self.rGunPicker:setItems(AnimForge.Mods.gunInfos(self:selectedModId(self.rMod)))
        local guns = {}
        if c.fullTypes and c.fullTypes ~= "" then
            local parts = luautils.split(c.fullTypes, ",")
            for i = 1, #parts do local t = parts[i]:gsub("%s+", ""); if t ~= "" then guns[#guns + 1] = t end end
        end
        self.rGunPicker:setSelectedList(guns)
        self.rNamespace:setText(c.luaNamespace or "")
        self.rProp:setText(c.propItem or ""); self.rBuild:setText(c.build or "42.13")
        self.rSpriteL:setText(c.spriteLoaded or ""); self.rSpriteU:setText(c.spriteUnloaded or "")
        self.rStyle:select(c.style or "none")
        self.rShort:setSelected(1, c.shortRackAfterInsert == true)
        self.rVisualMag:setSelected(1, c.visualMag == true)
        if AE.gw.archetypeKey then
            for i = 1, #ARCHETYPE_ORDER do
                if ARCHETYPE_ORDER[i] == AE.gw.archetypeKey then self.rArch.selected = i end
            end
        end
        self:updateReloadStyleFields()
    end
    self:configFooter()
    self:updateScroll()
end

-- Fill a stage's base-animation selector with the vanilla + mod clip choices and select the current
-- one (kept selectable even if it is a custom clip not in the standard lists).
function AnimForgeWindow:populateStageClipCombo(combo, currentClip)
    combo:clear()
    local choices = reloadClipChoices(AE.gw.config and AE.gw.config.mod)
    local sel, found = 1, false
    for i = 1, #choices do
        combo:addOptionWithData(choices[i].label, choices[i].clip)
        if choices[i].clip == currentClip then sel = i; found = true end
    end
    if currentClip and not found then
        combo:addOptionWithData(reloadClipLabel(currentClip), currentClip)
        sel = #choices + 1
    end
    combo.selected = sel
end

-- Change a stage's base animation from its selector. Carries any pose keyframes over to the new clip
-- so edits are not orphaned, persists, and toasts the change.
function AnimForgeWindow:onReloadStageClip(combo)
    local key = combo and combo.stageKey
    local s = key and AE.gw.stages[key]
    local clip = combo and combo:getOptionData(combo.selected)
    if not s or not clip or s.baseClip == clip then return end
    local old = s.baseClip
    s.baseClip = clip
    if old and old ~= clip and AE.keyframes[old] then
        AE.keyframes[clip] = AE.keyframes[old]
        s.keyframes = AE.keyframes[clip]
    end
    if AE.project and AE.project.type == "gunworks" then saveProject() end
    self.toast:set("Stage '" .. key .. "' clip -> " .. reloadClipLabel(clip), "ok")
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
    pcall(function() AnimForge.EditCore.rfxEndPosePreview() end)   -- clear the stage's previewed props
    self.reloadEditing = nil
    self:refreshReload()
end

-- pull the reload config form into AE.gw.config
function AnimForgeWindow:syncReloadConfig()
    local c = AE.gw.config
    c.animId = self.rAnimId:getInternalText()
    c.fullTypes = table.concat(self.rGunPicker:getSelectedList(), ", ")
    c.mod = self:selectedModId(self.rMod)
    c.luaNamespace = self.rNamespace:getInternalText()
    c.propItem = self.rProp:getInternalText()
    c.build = self.rBuild:getInternalText()
    c.style = comboText(self.rStyle) or "attachment"
    c.spriteLoaded = self.rSpriteL:getInternalText()
    c.spriteUnloaded = self.rSpriteU:getInternalText()
    c.shortRackAfterInsert = self.rShort:isSelected(1)
    c.visualMag = self.rVisualMag:isSelected(1)   -- seeds markers at default timings (magInsertPc/magEjectPc)
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
        AE.mod = self:selectedModId(self.gripMod); AE.namePrefix = self.gripName:getInternalText()
        local done, _, total = projectProgress()
        if not AE.project then self.toast:set("Create the set first.", "danger"); return end
        if total > 0 and done < total then self.toast:set("Tip: " .. done .. "/" .. total .. " clips signed off. Exporting anyway.", "edited") end
        if self.pose:onSaveSet() then self.toast:set("Exported '" .. AE.namePrefix .. "' -> " .. AE.mod .. ". Run the Anim Forge watcher (or pz-anim-forge bake-set + wire-set) to build.", "ok") end
    elseif key == "override" then
        AE.panel:onSave(); self.toast:set("Saved single .x for '" .. AE.clip .. "'. Run the Anim Forge watcher to build.", "ok")
    elseif key == "emote" then
        self:exportEmote()
    elseif key == "duplicate" then
        self:doDuplicate()
    elseif key == "reload" then
        self:saveChanges()
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
    local writer = getFileWriter("AnimForge/anim_edit.json", true, false)
    writer:write(AnimForge.JSON.encode(data)); writer:close()
    self.toast:set("Wrote emote '" .. nm .. "' -> " .. mod .. ". Run 'pz-anim-forge wire-emote' to build.", "ok")
end

-- The ONE save for the reload editor. Pull any in-progress edits from BOTH surfaces into the project -
-- the active pose (if you're posing a stage) and the attachment markers (if the Reload Attachments
-- window is open) - then bake the whole pack (clips with poses + nodes with markers + registration Lua).
-- So it never matters what you changed or which window you're in: this saves it.
function AnimForgeWindow:saveChanges()
    if self.reloadEditing then GW.captureActiveStage() end
    if AE.rfx.window and AE.rfx.window.captureMarkersToProject then
        AE.rfx.window:captureMarkersToProject()
    end
    self:exportReload()
end

function AnimForgeWindow:exportReload()
    self:syncReloadConfig()
    local c = AE.gw.config
    if c.animId == "" or c.fullTypes == "" or not c.mod or c.mod == "" then
        self.toast:set("Need animId, gun fullType, and target mod.", "danger"); return
    end
    for _, key in ipairs(AE.gw.order or {}) do
        if not (AE.gw.stages[key] and AE.gw.stages[key].baseClip) then
            self.toast:set("Stage '" .. key .. "' has no base clip. Seed an archetype.", "danger"); return
        end
    end
    -- NB: no applyVisualMag here. The project owns the markers now, so export bakes exactly what is in
    -- stages[].markers (including any timing you dialed in the Reload Attachments editor). Seeding the
    -- default mag markers is a deliberate act (create, or the visual-mag checkbox) - never a side effect
    -- of export, which used to reset your retimed markers to defaults.
    GW.captureActiveStage()
    local ts = getTimestampMs()
    GW.saveJson(ts)
    local name = c.animId ~= "" and c.animId or "gunworks"
    local slug = AP.save(GW.buildProject(name))
    AE.project = { name = name, slug = slug, weapon = AE.gw.archetypeKey, type = "gunworks" }
    local nReg = GW.registerLive()   -- live-register now so the reload animates without a restart
    self:pollWatcher()
    if self.watcherLive then
        self.gwBuildTs = ts          -- prerender polls gw_build_result.json for THIS build finishing
        self.gwBuildPoll = 0
        self.gwBuildTries = 0
        local regTxt = nReg > 0 and (" (registered " .. nReg .. (nReg == 1 and " gun" or " guns") .. ")") or ""
        self.toast:set("Exported reload '" .. name .. "' -> " .. c.mod .. ". Building + going live"
            .. regTxt .. "...", "ok")
    else
        self.toast:set("Exported reload '" .. name .. "' -> " .. c.mod
            .. ". No watcher running - start the auto-baker or run wire-gunworks to build.", "edited")
    end
end

-- After "Export reload pack" the watcher builds the pack, refreshes the picker cache, and nudges the
-- engine; it publishes gw_build_result.json keyed by the export ts. Poll for it, then refresh the
-- reloadfx picker so the new reload appears in "Reload attachments" with no restart. Gives up after a
-- few seconds so a missing watcher never leaves the poll spinning.
function AnimForgeWindow:pollGwBuild()
    if not self.gwBuildTs then return end
    self.gwBuildPoll = (self.gwBuildPoll or 0) + 1
    if self.gwBuildPoll < 15 then return end
    self.gwBuildPoll = 0
    self.gwBuildTries = (self.gwBuildTries or 0) + 1
    local ok, r = pcall(readJsonFile, "AnimForge/gw_build_result.json")
    if ok and r and r.ts == self.gwBuildTs then
        self.gwBuildTs = nil
        if r.ok then
            loadReloadsFromCache()   -- pull the freshly baked node into the reloadfx picker cache
            if self.mode == "reloadfx" then self:refreshReloadFx() end
            -- Hot-reload each re-baked clip's MOTION into the live model (PZ's own anims file-watcher
            -- never fires for mod dirs), so a re-exported reload plays its real motion with no restart.
            -- Uses the Anim Forge AnimationPlayer patch; silently no-ops (restart still works) if absent.
            local p = getPlayer()
            local ap = p and p:getAnimationPlayer()
            if ap and ap.reloadEditAnimClip and type(r.clips) == "table" then
                for i = 1, #r.clips do
                    pcall(function() ap:reloadEditAnimClip(r.clips[i]) end)
                end
            end
            -- Restart is genuinely needed when this build wrote NODE files that were not present at the
            -- last boot (never entered the engine's activeFileMap, so they cannot hot-load). The Python
            -- build reports those as newNodes; we also remember any animId flagged this session, because a
            -- re-export of the same new set (file now exists on disk) would otherwise look loadable. That
            -- per-session table lives only in this Lua state, which resets on the very restart it asks for.
            local aid = r.animId or "?"
            local newCount = (type(r.newNodes) == "table") and #r.newNodes or 0
            AE.exportedNew = AE.exportedNew or {}
            local needsRestart = newCount > 0 or AE.exportedNew[aid] or (not r.liveReload)
            if needsRestart then
                AE.exportedNew[aid] = true
                AE.restartPending = true
                self.toast:set("Built '" .. tostring(r.animId) .. "' - RESTART the game to load its new "
                    .. "animation nodes (they weren't reserved at boot). Tip: name a set to match a "
                    .. "preseeded stub to skip this.", "edited", 9)
            else
                self.toast:set("Built '" .. tostring(r.animId) .. "' - live, no restart. Open "
                    .. "'Reload attachments' to tune the timing.", "ok")
            end
        else
            self.toast:set("Reload build failed: " .. tostring(r.error or "see the watcher log") .. ".", "danger")
        end
    elseif self.gwBuildTries >= 30 then
        self.gwBuildTs = nil   -- ~7s with no matching result: assume the watcher is down, stop waiting
    end
end

-- ---- clean base clips (despike the stock reload base so the off-hand prop stops jittering) ----

-- The project's distinct stock (non-clean) base clips - the ones worth despiking into a clean copy.
---@return string[]
function AnimForgeWindow:stockBaseClips()
    local out, seen = {}, {}
    for _, key in ipairs(AE.gw.order or {}) do
        local s = AE.gw.stages[key]
        local bc = s and s.baseClip
        if bc and bc ~= "" and not bc:find("_afclean", 1, true) and not seen[bc] then
            seen[bc] = true
            out[#out + 1] = bc
        end
    end
    return out
end

-- Ask the watcher to bake despiked "clean" copies of the project's stock base clips into the mod; the
-- poll below retargets each stage's baseClip to its clean copy on success. `silent` suppresses the
-- toasts (used by the auto-run on create). Returns true when a request was written.
function AnimForgeWindow:bakeCleanBase(silent)
    self:syncReloadConfig()
    local mod = AE.gw.config.mod
    if not mod or mod == "" then
        if not silent then self.toast:set("Pick a target mod first.", "danger") end
        return false
    end
    local clips = self:stockBaseClips()
    if #clips == 0 then
        if not silent then self.toast:set("Base clips are already clean.", "ok") end
        return false
    end
    self:pollWatcher()
    if not self.watcherLive then
        if not silent then
            self.toast:set("No watcher running - start the auto-baker, then Clean base clips.", "edited")
        end
        return false
    end
    local ts = getTimestampMs()
    local writer = getFileWriter("AnimForge/clean_base_request.json", true, false)
    if not writer then return false end
    writer:write(AnimForge.JSON.encode({ ts = ts, mod = mod, baseClips = clips }))
    writer:close()
    self.cleanBaseTs = ts
    self.cleanBasePoll = 0
    self.cleanBaseTries = 0
    if not silent then self.toast:set("Baking clean base clips...", "ok") end
    return true
end

function AnimForgeWindow:onReloadCleanBase()
    self:bakeCleanBase(false)
end

-- Build a Reload-FX attachments group straight from the in-editor project (AE.gw), so attachments can be
-- edited on a set that has NOT been exported yet (no baked node in the scan cache). Each stage previews
-- on its baseClip (the clean base is present at boot) and carries the project's markers; openReloadFx
-- binds back to this same project, so marker edits mirror the set editor and save via "Save changes".
local GW_STAGE_LABEL = { load = "Load", loadShort = "LoadShort", rack = "Rack", unload = "Unload" }
local function gwProjectAttachGroup()
    if not (AE.project and AE.project.type == "gunworks") then return nil end
    if not (AE.gw and AE.gw.config and AE.gw.order and AE.gw.stages) then return nil end
    local cfg = AE.gw.config
    if not cfg.animId or cfg.animId == "" then return nil end
    local propItems = (cfg.propItem and cfg.propItem ~= "") and { cfg.propItem } or {}
    local stages = {}
    for i = 1, #AE.gw.order do
        local key = AE.gw.order[i]
        local s = AE.gw.stages[key]
        if s and s.baseClip then
            local markers = {}
            for j = 1, #(s.markers or {}) do
                local m = s.markers[j]
                markers[j] = { event = m.event, timePc = m.timePc or 0, value = m.value or "" }
            end
            stages[#stages + 1] = {
                mod = cfg.mod, animId = cfg.animId,
                stage = GW_STAGE_LABEL[key] or key,
                clip = s.baseClip, baseClip = s.baseClip,
                markers = markers, propItems = propItems,
            }
        end
    end
    if #stages == 0 then return nil end
    return { mod = cfg.mod, animId = cfg.animId, propItems = propItems, stages = stages }
end

-- Open the Reload Attachments editor for the reload currently loaded in the set editor. Prefers its baked
-- node in the scan cache (exported set -> real posed clip preview); for a set that has not been exported
-- yet it falls back to a group built from the live project, so you can place attachment markers straight
-- after Create. openReloadFx binds to this project either way (shared markers), so edits there show up in
-- the per-stage marker counts here and save through the one "Save changes".
function AnimForgeWindow:onReloadEditAttachments()
    self:syncReloadConfig()
    local animId, mod = AE.gw.config.animId, AE.gw.config.mod
    if not animId or animId == "" then
        self.toast:set("Create the reload first.", "danger"); return
    end
    -- NB: no captureActiveStage here - it is only reachable from the stages screen (not while posing),
    -- where AE.deltas is stale and a capture would wipe the active stage's pose deltas. Markers live in
    -- AE.gw.stages already; the attachments editor binds to that.
    loadReloadsFromCache()
    local groups = rfxGroupedReloads()
    local match
    for i = 1, #groups do
        if groups[i].animId == animId and (not mod or mod == "" or groups[i].mod == mod) then
            match = groups[i]; break
        end
    end
    if not match then
        match = gwProjectAttachGroup()   -- not exported yet: edit attachments straight from the live project
    end
    if not match then
        self.toast:set("Create the set first, then Edit attachments.", "danger"); return
    end
    openReloadFx(match)
end

-- Poll for the clean-base bake result (keyed by the request ts). On success retarget each stage's
-- baseClip to its clean copy (carrying keyframes across the rename), persist, refresh the base-clip
-- pickers + mod-clip cache, and try to hot-load the clean clips so the preview is clean this session.
-- A brand-new clip may need one restart to first load; the toast says so.
function AnimForgeWindow:pollCleanBase()
    if not self.cleanBaseTs then return end
    self.cleanBasePoll = (self.cleanBasePoll or 0) + 1
    if self.cleanBasePoll < 15 then return end
    self.cleanBasePoll = 0
    self.cleanBaseTries = (self.cleanBaseTries or 0) + 1
    local ok, r = pcall(readJsonFile, "AnimForge/clean_base_result.json")
    if ok and r and r.ts == self.cleanBaseTs then
        self.cleanBaseTs = nil
        if r.ok and type(r.mapping) == "table" then
            for _, key in ipairs(AE.gw.order or {}) do
                local s = AE.gw.stages[key]
                local clean = s and s.baseClip and r.mapping[s.baseClip]
                if clean then
                    local old = s.baseClip
                    if AE.keyframes[old] and not AE.keyframes[clean] then
                        AE.keyframes[clean] = AE.keyframes[old]
                    end
                    s.baseClip = clean
                    if s.keyframes then AE.keyframes[clean] = s.keyframes end
                end
            end
            -- Persist the retargeted baseClips. buildProject captures AE.deltas onto the active stage,
            -- but on the stages screen AE.deltas is stale ({}) and would wipe that stage's pose deltas;
            -- only allow the capture while actually posing (AE.deltas is valid then).
            if AE.project and AE.project.type == "gunworks" then
                local savedActive = AE.gw.activeStage
                if not self.reloadEditing then AE.gw.activeStage = nil end
                AP.save(GW.buildProject(AE.project.name))
                AE.gw.activeStage = savedActive
            end
            pcall(function() AnimForge.EditCore.loadModClipsFromCache() end)
            -- hot-load the clean clips' motion (PZ's own anims watcher never fires for mod dirs);
            -- a brand-new clip that boot never scanned can't load live, hence the "restart" hint.
            local p = getPlayer()
            local ap = p and p:getAnimationPlayer()
            if ap and ap.reloadEditAnimClip then
                for _, clean in pairs(r.mapping) do
                    pcall(function() ap:reloadEditAnimClip(clean) end)
                end
            end
            if self.reloadEditing then GW.loadStage(self.reloadEditing) end   -- re-force the clean clip if posing
            self:refreshReload()
            self.toast:set("Clean base clips baked (" .. tostring(#(r.clips or {}))
                .. "). If the preview still jitters, restart once to load them.", "ok")
        else
            self.toast:set("Clean base bake failed: " .. tostring(r.error or "see the watcher log") .. ".", "danger")
        end
    elseif self.cleanBaseTries >= 30 then
        self.cleanBaseTs = nil
    end
end

-- ---- live frame: content card, toast, primary-enable ----
function AnimForgeWindow:prerender()
    ISCollapsableWindow.prerender(self)
    if self.uiCollapsed then return end   -- minimized: only the title bar draws
    local th = self:titleBarHeight()
    -- backdrop behind header + footer (the scroll content panel paints its own surface). The header
    -- band is repainted opaque on top by self.headerBg (with its extras) so scrolled rows never show
    -- above it; here we only lay down the backdrop + footer.
    T.fill(self, self.contentX, th, self.contentW, self.height - th, T.col.bg0)
    -- footer divider + toast (clipped so a long status never slides under the right-side buttons)
    local fy = self.height - FOOTER_H
    T.hairline(self, self.contentX + T.sp.s, fy, self.contentW - T.sp.s * 2)
    local tx = self.contentX + T.sp.m
    local rightLimit = self.contentX + self.contentW
    if self.secondaryBtn and self.secondaryBtn:isVisible() then rightLimit = self.secondaryBtn:getX() - T.sp.s
    elseif self.primaryBtn and self.primaryBtn:isVisible() then rightLimit = self.primaryBtn:getX() - T.sp.s end
    self.toast:render(self, tx, fy + 16, math.max(40, rightLimit - tx))
    self:pollGwBuild()
    self:pollCleanBase()
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
    pcall(function() AnimForge.EditCore.rfxEndPosePreview() end)   -- restore gun/props if posing a reload stage
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

AnimForge.Hub = {
    closePanel = closePanel,
    openPanel = openPanel
}
