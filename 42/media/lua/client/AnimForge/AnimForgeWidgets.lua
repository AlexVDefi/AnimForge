-- Reusable themed widgets for the Anim Forge hub. Each is a thin ISUI subclass
-- styled via AnimForgeTheme, so the hub + mode screens compose them instead of
-- hand-drawing every control. No external textures -- all self-drawn.
--
--   NavRail     - left navigation: grouped, self-drawn rows with an accent
--                 active-bar + hover feedback (web sidebar nav).
--   FieldRow    - a labelled text input with helper/validation line (web form field).
--   HelpHeader  - wrapped instructional text (title / purpose / how / when-done).
--   StatusToast - a transient status line that fades after a few seconds.
require "ISUI/ISPanel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISRichTextPanel"
require "AnimForge/AnimForgeTheme"

local T = AnimForge.AnimForgeTheme

-- ================================================================ NavRail ==
-- A vertical nav. Entries are either a group header (kind="header") or a mode
-- (kind="mode", key, label). Self-drawn so labels left-align, headers stand
-- apart, and the active mode shows an accent left-bar + wash -- none of which
-- ISButton/ISScrollingListBox give cleanly for a fixed small nav.
NavRail = ISPanel:derive("NavRail")

local NAV_ROW_H = 26
local NAV_HDR_H = 22

function NavRail:new(x, y, w, h, onSelect, target)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self); self.__index = self
    o.background = true
    o.backgroundColor = { r = T.col.bg0[1], g = T.col.bg0[2], b = T.col.bg0[3], a = 1 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    o.entries = {}          -- { kind, key, label, y, h }
    o.activeKey = nil
    o.onSelect = onSelect   -- function(target, key)
    o.target = target
    return o
end

-- Replace the nav contents. `defs` = array of { header="..."} or { key=, label= }.
function NavRail:setEntries(defs)
    self.entries = {}
    local y = T.sp.s
    for i = 1, #defs do
        local d = defs[i]
        if d.header then
            self.entries[#self.entries + 1] = { kind = "header", label = d.header, y = y, h = NAV_HDR_H }
            y = y + NAV_HDR_H
        else
            self.entries[#self.entries + 1] = { kind = "mode", key = d.key, label = d.label, y = y, h = NAV_ROW_H }
            y = y + NAV_ROW_H
        end
    end
end

function NavRail:setActive(key) self.activeKey = key end

function NavRail:entryAt(y)
    for i = 1, #self.entries do
        local e = self.entries[i]
        if e.kind == "mode" and y >= e.y and y < e.y + e.h then return e end
    end
    return nil
end

function NavRail:onMouseDown(x, y)
    local e = self:entryAt(y)
    if e and self.onSelect then self.onSelect(self.target, e.key) end
    return true
end

function NavRail:prerender()
    ISPanel.prerender(self)
    -- right-edge hairline separating nav from content
    T.fill(self, self.width - 1, 0, 1, self.height, T.col.hair)
    local mx, my = self:getMouseX(), self:getMouseY()
    local over = self:isMouseOver()
    local pad = T.sp.m
    local fhBody = getTextManager():getFontHeight(T.font.body)
    for i = 1, #self.entries do
        local e = self.entries[i]
        if e.kind == "header" then
            T.text(self, e.label:upper(), pad, e.y + e.h - fhBody - 2, T.col.muted, T.font.body)
        else
            local active = (e.key == self.activeKey)
            local hot = over and my >= e.y and my < e.y + e.h
            if active then
                T.fill(self, 0, e.y, self.width - 1, e.h, T.col.accentSoft, T.col.accentSoft[4])
                T.fill(self, 0, e.y, 3, e.h, T.col.accent)       -- accent active-bar
            elseif hot then
                T.fill(self, 0, e.y, self.width - 1, e.h, { 1, 1, 1, 0.06 }, 0.06)
            end
            local tc = active and T.col.accent or (hot and T.col.text or T.col.text2)
            T.text(self, e.label, pad, e.y + (e.h - fhBody) / 2, tc, T.font.body)
        end
    end
end

-- =============================================================== FieldRow ==
-- A labelled text field: caption above, input below, optional helper/validation
-- line beneath. Total height is fixed (label + input + helper).
FieldRow = ISPanel:derive("FieldRow")

local FR_INPUT_H = 22

function FieldRow:new(x, y, w, label, opts)
    opts = opts or {}
    local fh = getTextManager():getFontHeight(T.font.body)
    local h = fh + 2 + FR_INPUT_H + fh + 4
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self); self.__index = self
    o.background = false
    o.labelText = label
    o.opts = opts
    o.helperText = opts.helper
    o.helperColor = T.col.muted
    o.labelH = fh
    return o
end

function FieldRow:createChildren()
    local fh = self.labelH
    self.entry = ISTextEntryBox:new(self.opts.value or "", 0, fh + 2, self.width, FR_INPUT_H)
    self.entry:initialise(); self.entry:instantiate()
    self.entry.font = T.font.body
    if self.opts.placeholder then self.entry:setPlaceholderText(self.opts.placeholder) end
    if self.opts.numbersOnly then self.entry:setOnlyNumbers(true) end
    if self.opts.clearButton ~= false then self.entry:setClearButton(true) end
    self:addChild(self.entry)
end

function FieldRow:getText() return self.entry and self.entry:getInternalText() or "" end
function FieldRow:setText(s) if self.entry then self.entry:setText(s or "") end end
function FieldRow:isFocused() return self.entry and self.entry:isFocused() end

-- Set the helper line (validation feedback). kind: nil/"muted", "danger", "ok".
function FieldRow:setHelper(text, kind)
    self.helperText = text
    self.helperColor = (kind == "danger" and T.col.danger)
        or (kind == "ok" and T.col.ok) or T.col.muted
end

function FieldRow:prerender()
    ISPanel.prerender(self)
    T.text(self, self.labelText, 0, 0, T.col.text2, T.font.body)
    if self.helperText and self.helperText ~= "" then
        T.text(self, self.helperText, 0, self.labelH + 2 + FR_INPUT_H + 2, self.helperColor, T.font.body)
    end
end

-- ============================================================= HelpHeader ==
-- Wrapped instructional text using ISRichTextPanel markup. The hub draws a card
-- behind it; this just lays out title + purpose + how + when-done.
HelpHeader = ISRichTextPanel:derive("HelpHeader")

function HelpHeader:new(x, y, w, h)
    local o = ISRichTextPanel:new(x, y, w, h)
    setmetatable(o, self); self.__index = self
    o.background = false
    o.autosetheight = true      -- paginate() sizes height to content, so nothing clips
    o.marginLeft = T.sp.m
    o.marginRight = T.sp.m
    o.marginTop = T.sp.s
    o.marginBottom = T.sp.s
    o.clip = true
    return o
end

-- title: bold accent line. purpose: one-line summary. how: the steps to follow.
-- (whenDone is accepted for call-site compatibility but intentionally not shown -- the
-- finish action is already on the primary button, and it kept the header from fitting.)
function HelpHeader:setContent(title, purpose, how, whenDone)
    local a = T.col.accent
    local s = T.col.text2
    local lines = {}
    lines[#lines + 1] = "<SIZE:large><RGB:" .. a[1] .. "," .. a[2] .. "," .. a[3] .. ">" .. (title or "")
    lines[#lines + 1] = "<SIZE:small><RGB:" .. T.col.text[1] .. "," .. T.col.text[2] .. "," .. T.col.text[3] .. "> " .. (purpose or "")
    if how and how ~= "" then
        lines[#lines + 1] = "<RGB:" .. s[1] .. "," .. s[2] .. "," .. s[3] .. ">How: " .. how
    end
    self.text = table.concat(lines, " <LINE> ")
    self:paginate()
end

-- ============================================================ StatusToast ==
-- A lightweight transient status line (not a widget; the hub draws it). Holds a
-- message + colour + expiry; fades over its last second. Time via getTimestampMs.
StatusToast = {}
StatusToast.__index = StatusToast

function StatusToast.new()
    return setmetatable({ text = "", color = T.col.muted, until_ = 0 }, StatusToast)
end

-- kind: "ok" | "edited" | "danger" | nil (muted). ttl seconds (default 4).
function StatusToast:set(text, kind, ttl)
    self.text = text or ""
    self.color = (kind == "ok" and T.col.ok) or (kind == "edited" and T.col.edited)
        or (kind == "danger" and T.col.danger) or T.col.text2
    self.until_ = getTimestampMs() + (ttl or 4) * 1000
end

-- Draw on element `e` at (x, y). Fades out over the final 800ms. `maxWidth` (optional) clips the line
-- with an ellipsis so a long status never runs under the footer buttons sitting to its right.
function StatusToast:render(e, x, y, maxWidth)
    if self.text == "" then return end
    local left = self.until_ - getTimestampMs()
    if left <= 0 then self.text = ""; return end
    local a = left < 800 and (left / 800) or 1
    local txt = self.text
    if maxWidth and maxWidth > 0 then
        local tm = getTextManager()
        if tm:MeasureStringX(T.font.body, txt) > maxWidth then
            while #txt > 1 and tm:MeasureStringX(T.font.body, txt .. "...") > maxWidth do
                txt = txt:sub(1, #txt - 1)
            end
            txt = txt .. "..."
        end
    end
    T.text(e, txt, x, y, { self.color[1], self.color[2], self.color[3], a }, T.font.body)
end

return true
