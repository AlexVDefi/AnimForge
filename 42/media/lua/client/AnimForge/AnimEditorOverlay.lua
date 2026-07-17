-- Anim Forge editor: the full-screen bone-node + drag-gizmo overlay.
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

local animPlayer = AnimForge.EditCore.animPlayer
local ensureDelta = AnimForge.EditCore.ensureDelta
local evalKf = AnimForge.EditCore.evalKf
local getClipTime = AnimForge.EditCore.getClipTime
local setPos = AnimForge.EditCore.setPos
local setRot = AnimForge.EditCore.setRot
local AE = AnimForge.AnimEdit

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

