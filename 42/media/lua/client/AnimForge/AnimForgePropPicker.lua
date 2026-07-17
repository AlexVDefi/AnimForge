-- Tabbed, searchable, favouritable item picker for the reload-attachment marker editor.
--
-- The reload markers place an item into the off-hand / right-hand slot (a magazine, ramrod, paper
-- cartridge, ...). This widget lets you pick that item from four sources via tabs -- the selected
-- weapon's own attachments, every item in the reload's mod, any base-game item (search-gated so the
-- thousands of rows stay snappy), and a Favourites list you curate -- all searchable, with a per-row
-- star to favourite/unfavourite. Favourites persist to AnimForge/prop_favorites.json so the 3-4 props
-- you iterate on stay one click away across sessions.
--
-- Used both as an embedded panel and inside PropPickerWindow (a poppable, resizable window).

require "ISUI/ISPanel"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISButton"
require "ISUI/ISCollapsableWindow"
require "AnimForge/AnimForgeTheme"

AnimForgePropPicker = ISPanel:derive("AnimForgePropPicker")

local TAB_ORDER = { "weapon", "mod", "base", "fav" }
local TAB_LABEL = { weapon = "Weapon", mod = "Mod", base = "Base", fav = "Favourites" }

-- ---- favourites (shared, persisted) --------------------------------------------------------------
local FAV_FILE = "AnimForge/prop_favorites.json"
local favSet = nil

local function loadFavs()
    if favSet then return favSet end
    favSet = {}
    local ok, data = pcall(function() return AnimForge.EditCore.readJsonFile(FAV_FILE) end)
    if ok and type(data) == "table" and type(data.favorites) == "table" then
        for i = 1, #data.favorites do favSet[data.favorites[i]] = true end
    end
    return favSet
end

local function saveFavs()
    local list = {}
    for ft, on in pairs(favSet or {}) do if on then list[#list + 1] = ft end end
    table.sort(list)
    local w = getFileWriter(FAV_FILE, true, false)
    if w then w:write(AnimForge.JSON.encode({ favorites = list })); w:close() end
end

-- Resolve + cache a row's icon on first draw (big lists ship without one to avoid instantiating
-- thousands of items). false = resolved, no icon.
local function rowTex(data)
    if data.tex ~= nil then return data.tex or nil end
    local inst = instanceItem(data.fullType)
    data.tex = (inst and inst:getTex()) or false
    return data.tex or nil
end

-- Favourite star textures -- the same ones the crafting / build menus use for favouriting.
local _starOn, _starOff
local function starTex(on)
    if on then
        if not _starOn then _starOn = getTexture("media/ui/FavoriteStarChecked.png") end
        return _starOn
    end
    if not _starOff then _starOff = getTexture("media/ui/FavoriteStarUnchecked.png") end
    return _starOff
end

-- Width the vertical scrollbar reserves when it is actually showing (content overflows), else 0.
-- Mirrors ISScrollingListBox's own test, so the star sits just left of the bar and never under it (and
-- its click zone never collides with the scrollbar).
local function sbarWidth(lb)
    if lb.vscroll and lb.vscroll:getHeight() < lb:getScrollHeight() then return lb.vscroll:getWidth() end
    return 0
end

--- opts = { onPick = fn(target, fullType), target = obj, contextFn = fn() -> modId, gunFullType }
function AnimForgePropPicker:new(x, y, w, h, opts)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self); self.__index = self
    opts = opts or {}
    o.onPick = opts.onPick
    o.target = opts.target
    o.contextFn = opts.contextFn
    o.includeClear = opts.includeClear == true   -- prepend a "(clear / empty hand)" row
    o.tab = "weapon"
    o.pickedFT = nil
    o.background = false
    o._lastFilter = nil
    o._rows = {}
    loadFavs()
    return o
end

function AnimForgePropPicker:createChildren()
    local T = AnimForge.AnimForgeTheme
    self.tabH, self.searchH = 22, 20
    self.tabBtns = {}
    for i = 1, #TAB_ORDER do
        local b = ISButton:new(0, 0, 10, self.tabH, TAB_LABEL[TAB_ORDER[i]], self, AnimForgePropPicker.onTab)
        b.internal = TAB_ORDER[i]
        b:initialise(); self:addChild(b); T.styleGhost(b)
        self.tabBtns[i] = b
    end
    self.filter = ISTextEntryBox:new("", 0, 0, self.width, self.searchH)
    self.filter:initialise(); self.filter:instantiate()
    self.filter:setClearButton(true)
    self.filter:setPlaceholderText("Search...")
    self:addChild(self.filter)

    self.list = ISScrollingListBox:new(0, 0, self.width, 10)
    self.list:initialise(); self.list:instantiate()
    self.list.itemheight = 24
    self.list.font = UIFont.Small
    self.list.drawBorder = true
    local picker = self
    self.list.doDrawItem = function(lb, y, item, alt) return picker:drawItem(lb, y, item, alt) end
    self.list:setOnMouseDownFunction(self, AnimForgePropPicker.onRowPicked)
    -- click in the right-hand star gutter toggles favourite instead of selecting
    local vanillaMD = ISScrollingListBox.onMouseDown
    self.list.onMouseDown = function(lb, x, y)
        local sw = sbarWidth(lb)
        local row = lb:rowAt(x, y)
        if row and row >= 1 and row <= #lb.items and x >= lb:getWidth() - 26 - sw and x < lb:getWidth() - sw then
            local data = lb.items[row].item
            if data and data.fullType ~= "" then picker:toggleFavorite(data.fullType); return end
        end
        vanillaMD(lb, x, y)
    end
    self:addChild(self.list)

    self.hint = ISLabel:new(4, 0, self.searchH, "", 0.6, 0.62, 0.7, 1, UIFont.Small, true)
    self.hint:initialise(); self:addChild(self.hint)

    self:layout()
    self:refreshTab()
end

-- Position children for the current size (called on create + on window resize).
function AnimForgePropPicker:layout()
    local n = #TAB_ORDER
    local tw = self.width / n
    for i = 1, n do
        self.tabBtns[i]:setX(math.floor((i - 1) * tw))
        self.tabBtns[i]:setWidth(math.floor(i * tw) - math.floor((i - 1) * tw) - 2)
        self.tabBtns[i]:setY(0)
    end
    self.filter:setY(self.tabH + 2)
    self.filter:setWidth(self.width)
    local ly = self.tabH + 2 + self.searchH + 2
    self.list:setY(ly)
    self.list:setWidth(self.width)
    self.list:setHeight(self.height - ly)
    -- the scrollbar's geometry is fixed at instantiate() from the list's THEN size; re-sync it to the
    -- resized list so it hides when content fits and never overlaps the rows.
    if self.list.vscroll then
        self.list.vscroll:setHeight(self.list:getHeight())
        self.list.vscroll:setX(self.list:getWidth() - self.list.vscroll:getWidth())
    end
    self.hint:setX(6)
    self.hint:setY(ly + 6)
end

function AnimForgePropPicker:onTab(button)
    self.tab = button.internal
    self.filter:setText("")
    self._lastFilter = nil
    self:refreshTab()
end

-- Load the active tab's source rows (Weapon/Mod use the live reload context; Base is search-gated).
function AnimForgePropPicker:refreshTab()
    local T = AnimForge.AnimForgeTheme
    for i = 1, #self.tabBtns do
        local active = self.tabBtns[i].internal == self.tab
        self.tabBtns[i].backgroundColor = active
            and { r = T.col.accent[1], g = T.col.accent[2], b = T.col.accent[3], a = 0.55 }
            or { r = T.col.surfaceRaised[1], g = T.col.surfaceRaised[2], b = T.col.surfaceRaised[3], a = 1 }
    end
    local modId, gun = nil, nil
    if self.contextFn then modId, gun = self.contextFn() end
    if self.tab == "weapon" then
        self._rows = (modId and gun) and AnimForge.Mods.attachmentInfos(modId, gun) or {}
    elseif self.tab == "mod" then
        self._rows = modId and AnimForge.Mods.modItemInfos(modId) or {}
    elseif self.tab == "base" then
        self._rows = AnimForge.Mods.baseItemInfos()
    else
        self._rows = self:favoriteRows()
    end
    self._lastFilter = nil
    self:refilter()
end

-- Favourite fullTypes -> picker rows (name via a live instance; icon lazily by the list).
function AnimForgePropPicker:favoriteRows()
    local out = {}
    for ft, on in pairs(favSet or {}) do
        if on then out[#out + 1] = AnimForge.Mods.itemInfo(ft) end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

function AnimForgePropPicker:refilter()
    local q = (self.filter:getInternalText() or ""):lower()
    self.list:clear()
    self.list:setScrollHeight(0)   -- clear() does NOT reset it; addItem accumulates, so reset each pass
    -- prop markers can also clear the slot -- keep a "(clear)" row at the top, always pickable.
    if self.includeClear then
        self.list:addItem("(clear / empty hand)", { fullType = "", name = "(clear / empty hand)", tex = false })
    end
    -- Base has thousands of rows: only show them once you have typed 2+ characters.
    if self.tab == "base" and #q < 2 then
        self.hint:setName("Type 2+ letters to search base-game items.")
        self.hint:setY(self.list:getY() + (self.includeClear and self.list.itemheight + 4 or 6))
        self.hint:setVisible(true)
        self:syncScrollbar()
        return
    end
    local n = 0
    for i = 1, #self._rows do
        local it = self._rows[i]
        if q == "" or it.name:lower():find(q, 1, true) or it.fullType:lower():find(q, 1, true) then
            self.list:addItem(it.name, it)
            n = n + 1
        end
    end
    if n == 0 then
        self.hint:setName(self.tab == "fav" and "No favourites yet. Click the star on any item."
            or "No matches.")
        self.hint:setY(self.list:getY() + (self.includeClear and self.list.itemheight + 4 or 6))
        self.hint:setVisible(true)
    else
        self.hint:setVisible(false)
    end
    self:syncScrollbar()
end

-- Show the scrollbar ONLY when the content overflows. Vanilla just renders nothing when it fits, but
-- the scrollbar child still occupies the right gutter and swallows clicks (which is why the favourite
-- star there was unclickable); hiding it entirely frees that gutter for the star + row clicks.
function AnimForgePropPicker:syncScrollbar()
    if self.list.vscroll then
        self.list.vscroll:setVisible(self.list:getScrollHeight() > self.list:getHeight())
    end
end

function AnimForgePropPicker:prerender()
    local t = self.filter:getInternalText()
    if t ~= self._lastFilter then
        self._lastFilter = t
        self:refilter()
    end
    ISPanel.prerender(self)
end

function AnimForgePropPicker:drawItem(lb, y, item, alt)
    local data = item.item
    local h = lb.itemheight
    if self.pickedFT and data.fullType == self.pickedFT then
        lb:drawRect(0, y, lb:getWidth(), h - 1, 0.85, 0.35, 0.30, 0.55)
    end
    local iconSz = h - 6
    local tex = rowTex(data)
    if tex then lb:drawTextureScaledAspect(tex, 3, y + 3, iconSz, iconSz, 1, 1, 1, 1) end
    lb:drawText(data.name, iconSz + 9, y + 4, 0.9, 0.9, 0.9, 1, lb.font)
    -- favourite star (crafting-menu texture): checked when favourited, unchecked otherwise. Drawn just
    -- left of the scrollbar so it is always visible + clickable. Not on the clear row.
    if data.fullType ~= "" then
        local ss = 15
        local sx, sy = lb:getWidth() - ss - 4 - sbarWidth(lb), y + (h - ss) / 2
        local tex = starTex(favSet[data.fullType])
        if tex then lb:drawTextureScaledAspect(tex, sx, sy, ss, ss, 1, 1, 1, 1) end
    end
    return y + h
end

function AnimForgePropPicker:onRowPicked(item)
    if not item then return end
    self.pickedFT = item.fullType
    if self.onPick and self.target then self.onPick(self.target, item.fullType) end
end

function AnimForgePropPicker:toggleFavorite(ft)
    if not ft then return end
    favSet[ft] = (not favSet[ft]) and true or nil
    saveFavs()
    if self.tab == "fav" then self:refreshTab() end   -- rebuild the favourites list live
end

-- Rebuild the current tab's rows against the live context (called when the equipped gun changes).
function AnimForgePropPicker:refreshContext()
    self:refreshTab()
end

-- ============================================================ PropPickerWindow ==
-- A poppable, resizable window hosting the picker, so it can stay open beside the reload editor while
-- you iterate on which props go where.
PropPickerWindow = ISCollapsableWindow:derive("PropPickerWindow")

function PropPickerWindow:new(x, y, opts)
    local o = ISCollapsableWindow.new(self, x or 260, y or 140, 300, 380)
    o.title = "Reload props"
    o.resizable = true
    o.opts = opts or {}
    return o
end

function PropPickerWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local th = self:titleBarHeight()
    local pad = 8
    self.picker = AnimForgePropPicker:new(pad, th + pad, self.width - pad * 2, self.height - th - pad * 2, self.opts)
    self.picker:initialise(); self.picker:instantiate()
    self:addChild(self.picker)
end

function PropPickerWindow:onResize()
    ISCollapsableWindow.onResize(self)
    if self.picker then
        local th = self:titleBarHeight()
        local pad = 8
        self.picker:setWidth(self.width - pad * 2)
        self.picker:setHeight(self.height - th - pad * 2)
        self.picker:layout()
    end
end

function PropPickerWindow:refreshContext()
    if self.picker then self.picker:refreshContext() end
end

return AnimForgePropPicker
