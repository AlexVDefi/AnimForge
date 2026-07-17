-- Anim Forge editor: the pose panel (embedded pose view) + its keyframe timeline bar.
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

local KF_EPS = AnimForge.EditCore.KF_EPS
local getClipLen = AnimForge.EditCore.getClipLen
local getClipTime = AnimForge.EditCore.getClipTime
local setClipPaused = AnimForge.EditCore.setClipPaused
local setClipTime = AnimForge.EditCore.setClipTime
local AE = AnimForge.AnimEdit
local T = AnimForge.AnimForgeTheme

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


AnimForge.EditPanel = {
    TIMELINE_POP_W = TIMELINE_POP_W
}
