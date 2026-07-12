-- Anim Forge UI theme: a single source of truth for colours, spacing, and the
-- small set of draw helpers the hub + widgets share. Pure presentation -- no
-- engine coupling, no external textures (everything is drawn rects + built-in
-- fonts), so it loads standalone and the rest of the editor depends on it.
--
-- Aesthetic: a dark "field-manual" surface with ONE warm accent (amber). Web-UI
-- practice adapted to ISUI: layered surfaces, hairline dividers, a clear text
-- hierarchy (primary / secondary / muted), and semantic done/edited/danger hues.
--
-- ISUIElement draw arg order (mirrors the rest of this mod):
--   self:drawRect(x, y, w, h, a, r, g, b)        -- ALPHA first
--   self:drawRectBorder(x, y, w, h, a, r, g, b)
--   self:drawText(text, x, y, r, g, b, a, font)  -- rgb then alpha
AnimForge = AnimForge or {}
AnimForge.AnimForgeTheme = AnimForge.AnimForgeTheme or {}
local T = AnimForge.AnimForgeTheme

-- Colours as {r, g, b, a}. Alpha defaults to 1 when a helper omits it.
T.col = {
    bg0           = { 0.07, 0.08, 0.10, 1 },   -- window backdrop
    surface       = { 0.11, 0.12, 0.15, 1 },   -- cards / content area
    surfaceRaised = { 0.15, 0.16, 0.20, 1 },   -- rows / inputs / ghost buttons
    border        = { 0.30, 0.32, 0.38, 1 },   -- card + control borders
    hair          = { 0.20, 0.21, 0.26, 1 },   -- 1px dividers
    accent        = { 0.85, 0.62, 0.22, 1 },   -- primary actions + active nav
    accentHover   = { 0.94, 0.71, 0.30, 1 },   -- primary hover
    accentSoft    = { 0.85, 0.62, 0.22, 0.18 },-- active-nav fill wash
    accentText    = { 0.08, 0.07, 0.05, 1 },   -- text on the accent fill
    text          = { 0.92, 0.93, 0.95, 1 },   -- primary text
    text2         = { 0.70, 0.72, 0.78, 1 },   -- secondary text / labels
    muted         = { 0.50, 0.52, 0.58, 1 },   -- hints / disabled / placeholders
    done          = { 0.27, 0.74, 0.40, 1 },   -- checklist complete
    edited        = { 0.90, 0.66, 0.20, 1 },   -- has edits, not signed off
    danger        = { 0.84, 0.30, 0.30, 1 },   -- destructive / overwrite
    ok            = { 0.45, 0.85, 0.55, 1 },   -- success toast
}

-- Spacing scale (px) + the standard control row height.
T.sp  = { xs = 4, s = 8, m = 12, l = 16, xl = 24 }
T.row = 24

-- Fonts: built-ins only. Large = mode title, Medium = section, Small = body.
T.font = { title = UIFont.Large, section = UIFont.Medium, body = UIFont.Small }

-- ------------------------------------------------------------- primitives ---
-- All take the drawing element `e` (any ISUIElement) so they can be called from
-- a widget's prerender. Colours are theme tables; an explicit `a` overrides the
-- table's alpha.

function T.fill(e, x, y, w, h, c, a)
    c = c or T.col.surface
    e:drawRect(x, y, w, h, a or c[4] or 1, c[1], c[2], c[3])
end

function T.stroke(e, x, y, w, h, c, a)
    c = c or T.col.border
    e:drawRectBorder(x, y, w, h, a or c[4] or 1, c[1], c[2], c[3])
end

function T.text(e, str, x, y, c, font)
    c = c or T.col.text
    e:drawText(str, x, y, c[1], c[2], c[3], c[4] or 1, font or T.font.body)
end

function T.textCentre(e, str, x, y, c, font)
    c = c or T.col.text
    e:drawTextCentre(str, x, y, c[1], c[2], c[3], c[4] or 1, font or T.font.body)
end

function T.textRight(e, str, x, y, c, font)
    c = c or T.col.text
    e:drawTextRight(str, x, y, c[1], c[2], c[3], c[4] or 1, font or T.font.body)
end

-- A 1px horizontal hairline divider.
function T.hairline(e, x, y, w, c)
    T.fill(e, x, y, w, 1, c or T.col.hair)
end

-- A filled, bordered surface "card".
function T.card(e, x, y, w, h, fillc, strokec)
    T.fill(e, x, y, w, h, fillc or T.col.surface)
    T.stroke(e, x, y, w, h, strokec or T.col.border)
end

-- A section header: small-caps-ish label in secondary text + a hairline under it.
-- Returns the y just below the divider so callers can flow content.
function T.sectionHeader(e, x, y, w, label)
    T.text(e, label, x, y, T.col.text2, T.font.body)
    local fh = getTextManager():getFontHeight(T.font.body)
    T.hairline(e, x, y + fh + 3, w, T.col.hair)
    return y + fh + 3 + T.sp.s
end

-- A small status square: "done" (green) / "edited" (amber) / hollow (to-do).
function T.badge(e, x, y, size, state)
    local c = T.col.surfaceRaised
    if state == "done" then c = T.col.done
    elseif state == "edited" then c = T.col.edited end
    T.fill(e, x, y, size, size, c, 0.92)
    T.stroke(e, x, y, size, size, { 0, 0, 0, 1 })
end

-- ------------------------------------------------------------- buttons ------
-- Stylers mutate an existing ISButton's colour fields (the engine's fade blends
-- backgroundColor -> backgroundColorMouseOver on hover, giving free feedback).

local function applyBtn(btn, bg, hover, border, fg)
    btn.backgroundColor          = { r = bg[1],     g = bg[2],     b = bg[3],     a = bg[4] or 1 }
    btn.backgroundColorMouseOver = { r = hover[1],  g = hover[2],  b = hover[3],  a = hover[4] or 1 }
    btn.borderColor              = { r = border[1], g = border[2], b = border[3], a = border[4] or 1 }
    btn.textColor                = { r = fg[1],     g = fg[2],     b = fg[3],     a = fg[4] or 1 }
    return btn
end

-- Primary call-to-action: amber fill, dark text.
function T.stylePrimary(btn)
    return applyBtn(btn, T.col.accent, T.col.accentHover, T.col.accent, T.col.accentText)
end

-- Secondary / neutral action: raised surface, hairline border, secondary text.
function T.styleGhost(btn)
    return applyBtn(btn, T.col.surfaceRaised, T.col.border, T.col.hair, T.col.text2)
end

-- Destructive / overwrite action.
function T.styleDanger(btn)
    return applyBtn(btn, { 0.28, 0.12, 0.12, 1 }, { 0.46, 0.18, 0.18, 1 }, T.col.danger, T.col.text)
end

-- Disable look (paired with btn:setEnable(false)).
function T.styleDisabled(btn)
    return applyBtn(btn, { 0.12, 0.12, 0.14, 1 }, { 0.12, 0.12, 0.14, 1 }, T.col.hair, T.col.muted)
end

return T
