-- Searchable, icon-rendering item picker: a filter field over a scrolling list whose rows show
-- each item's icon + display name. Single- or multi-select (click toggles / selects). Reused for
-- the reload gun picker and the test-rig gun selector so choosing a weapon/part is visual + fast.

require "ISUI/ISPanel"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextEntryBox"

AnimForgePicker = ISPanel:derive("AnimForgePicker")

--- opts = { multiSelect = bool, onSelect = fn(target, fullType, isSelected), target = obj }
function AnimForgePicker:new(x, y, w, h, opts)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    opts = opts or {}
    o.multiSelect = opts.multiSelect == true
    o.onSelect = opts.onSelect
    o.target = opts.target
    o.items = {}          -- { { fullType, name, tex }, ... }
    o.selectedSet = {}    -- fullType -> true
    o.background = false
    o._lastFilter = nil
    return o
end

function AnimForgePicker:createChildren()
    local fh = 20
    self.filter = ISTextEntryBox:new("", 0, 0, self.width, fh)
    self.filter:initialise(); self.filter:instantiate()
    self.filter:setClearButton(true)
    self.filter:setPlaceholderText("Search...")
    self:addChild(self.filter)

    self.list = ISScrollingListBox:new(0, fh + 2, self.width, self.height - fh - 2)
    self.list:initialise(); self.list:instantiate()
    self.list.itemheight = 24
    self.list.font = UIFont.Small
    self.list.drawBorder = true
    local picker = self
    self.list.doDrawItem = function(lb, y, item, alt) return picker:drawItem(lb, y, item, alt) end
    self.list:setOnMouseDownFunction(self, AnimForgePicker.onItemPicked)
    self:addChild(self.list)
end

-- Reposition the filter + list for the current size (call after setWidth/setHeight to fill a column).
function AnimForgePicker:reflow()
    if not self.filter then return end
    local fh = 20
    self.filter:setWidth(self.width)
    self.list:setY(fh + 2)
    self.list:setWidth(self.width)
    self.list:setHeight(self.height - fh - 2)
    -- re-sync the scrollbar to the resized list (its geometry was fixed at instantiate() from the
    -- creation size), so it hides when content fits instead of showing a stale, too-short bar.
    if self.list.vscroll then
        self.list.vscroll:setHeight(self.list:getHeight())
        self.list.vscroll:setX(self.list:getWidth() - self.list.vscroll:getWidth())
    end
end

--- items = { { fullType = "NA.G36C", name = "G36C", tex = Texture|nil }, ... }
function AnimForgePicker:setItems(items)
    self.items = items or {}
    self._lastFilter = nil   -- force a refilter next prerender
end

function AnimForgePicker:setSelectedList(fts)
    self.selectedSet = {}
    if fts then for i = 1, #fts do self.selectedSet[fts[i]] = true end end
end

function AnimForgePicker:getSelectedList()
    local out = {}
    for ft, v in pairs(self.selectedSet) do if v then out[#out + 1] = ft end end
    table.sort(out)
    return out
end

function AnimForgePicker:isSelected(ft)
    return self.selectedSet[ft] == true
end

function AnimForgePicker:refilter()
    local q = (self.filter:getInternalText() or ""):lower()
    self.list:clear()
    self.list:setScrollHeight(0)   -- clear() does NOT reset it; addItem accumulates, so reset each pass
    for i = 1, #self.items do
        local it = self.items[i]
        if q == "" or it.name:lower():find(q, 1, true) or it.fullType:lower():find(q, 1, true) then
            self.list:addItem(it.name, it)
        end
    end
    -- hide the scrollbar entirely when content fits (vanilla only stops drawing it, but the child still
    -- occupies the right gutter and eats clicks there).
    if self.list.vscroll then
        self.list.vscroll:setVisible(self.list:getScrollHeight() > self.list:getHeight())
    end
end

function AnimForgePicker:prerender()
    local t = self.filter:getInternalText()
    if t ~= self._lastFilter then
        self._lastFilter = t
        self:refilter()
    end
    ISPanel.prerender(self)
end

-- Resolve (and cache) a row's icon on first draw. Rows from big lists (mod/base items) ship without a
-- texture to avoid instantiating thousands of items up front; only the ~visible rows resolve here.
local function rowTex(data)
    if data.tex ~= nil then return data.tex or nil end
    local inst = instanceItem(data.fullType)
    data.tex = (inst and inst:getTex()) or false   -- false = resolved, no icon (don't retry)
    return data.tex or nil
end

function AnimForgePicker:drawItem(lb, y, item, alt)
    local data = item.item
    local h = lb.itemheight
    if self:isSelected(data.fullType) then
        lb:drawRect(0, y, lb:getWidth(), h - 1, 0.85, 0.35, 0.30, 0.55)
    end
    local iconSz = h - 6
    local tex = rowTex(data)
    if tex then
        lb:drawTextureScaledAspect(tex, 3, y + 3, iconSz, iconSz, 1, 1, 1, 1)
    end
    lb:drawText(data.name, iconSz + 9, y + 4, 0.9, 0.9, 0.9, 1, lb.font)
    return y + h
end

-- Built-in click handler passes the clicked row's data item.
function AnimForgePicker:onItemPicked(item)
    if not item then return end
    local ft = item.fullType
    if self.multiSelect then
        self.selectedSet[ft] = (not self.selectedSet[ft]) and true or nil
    else
        self.selectedSet = { [ft] = true }
    end
    if self.onSelect and self.target then
        self.onSelect(self.target, ft, self.selectedSet[ft] == true)
    end
end

return AnimForgePicker
