-- Test rig: equip a weapon on the player + toggle its attachments, so you can pose/animate against a
-- real gun + parts. Two columns that fill to the bottom of the panel: the LEFT column is a searchable
-- weapon list; picking a weapon populates the RIGHT column with that weapon's available attachments,
-- each a click-to-toggle row (attaching auto-equips the selected weapon so there is something to mount
-- on). Used embedded in the hub's Test-rig task AND inside TestRigWindow, a poppable window that stays
-- open while you work in the other panels.

require "ISUI/ISPanel"
require "ISUI/ISComboBox"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISCollapsableWindow"
require "AnimForge/AnimForgeTheme"
require "AnimForge/AnimForgePicker"

AnimForgeTestRig = ISPanel:derive("AnimForgeTestRig")

function AnimForgeTestRig:new(x, y, w, h)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self); self.__index = self
    o.background = false
    o.selectedGun = nil
    o.attachByFt = {}
    return o
end

function AnimForgeTestRig:createChildren()
    local T = AnimForge.AnimForgeTheme
    self.modLbl = ISLabel:new(0, 0, 16, "Gun mod", 0.7, 0.72, 0.78, 1, UIFont.Small, true)
    self.modLbl:initialise(); self:addChild(self.modLbl)
    self.modCombo = ISComboBox:new(0, 0, 10, 22, self, AnimForgeTestRig.onModChange)
    self.modCombo:initialise(); self:addChild(self.modCombo)
    self.equipBtn = ISButton:new(0, 0, 10, 22, "Equip", self, AnimForgeTestRig.onEquip)
    self.equipBtn:initialise(); self:addChild(self.equipBtn); T.stylePrimary(self.equipBtn)
    self.equipBtn.tooltip = "Give + equip the selected weapon on the player."
    self.unequipBtn = ISButton:new(0, 0, 10, 22, "Unequip", self, AnimForgeTestRig.onUnequip)
    self.unequipBtn:initialise(); self:addChild(self.unequipBtn); T.styleGhost(self.unequipBtn)
    self.unequipBtn.tooltip = "Clear the player's hands."

    self.gunLbl = ISLabel:new(0, 0, 16, "Weapon (search, click to pick)", 0.7, 0.72, 0.78, 1, UIFont.Small, true)
    self.gunLbl:initialise(); self:addChild(self.gunLbl)
    self.attachLbl = ISLabel:new(0, 0, 16, "Attachments (click to toggle)", 0.7, 0.72, 0.78, 1, UIFont.Small, true)
    self.attachLbl:initialise(); self:addChild(self.attachLbl)

    self.gunPicker = AnimForgePicker:new(0, 0, 10, 10,
        { multiSelect = false, target = self, onSelect = AnimForgeTestRig.onGunSelect })
    self.gunPicker:initialise(); self:addChild(self.gunPicker)
    self.attachPicker = AnimForgePicker:new(0, 0, 10, 10,
        { multiSelect = true, target = self, onSelect = AnimForgeTestRig.onAttachToggle })
    self.attachPicker:initialise(); self:addChild(self.attachPicker)

    self:layout()
    self:refresh()
end

-- Two equal columns filling to the bottom: mod combo + weapon list (left), equip buttons + attachment
-- list (right).
function AnimForgeTestRig:layout()
    local gap = 8
    local colW = math.floor((self.width - gap) / 2)
    local x2 = colW + gap
    self.modLbl:setX(0); self.modLbl:setY(0)
    self.modCombo:setX(0); self.modCombo:setY(16); self.modCombo:setWidth(colW)
    local bw = math.floor((colW - gap) / 2)
    self.equipBtn:setX(x2); self.equipBtn:setY(16); self.equipBtn:setWidth(bw)
    self.unequipBtn:setX(x2 + bw + gap); self.unequipBtn:setY(16); self.unequipBtn:setWidth(colW - bw - gap)
    local labelY = 44
    self.gunLbl:setX(0); self.gunLbl:setY(labelY)
    self.attachLbl:setX(x2); self.attachLbl:setY(labelY)
    local listY = labelY + 18
    local listH = math.max(60, self.height - listY)
    self.gunPicker:setX(0); self.gunPicker:setY(listY); self.gunPicker:setWidth(colW); self.gunPicker:setHeight(listH)
    self.gunPicker:reflow()
    self.attachPicker:setX(x2); self.attachPicker:setY(listY); self.attachPicker:setWidth(colW); self.attachPicker:setHeight(listH)
    self.attachPicker:reflow()
end

function AnimForgeTestRig:modId()
    return self.modCombo and self.modCombo:getOptionData(self.modCombo.selected) or nil
end

function AnimForgeTestRig:populateMods()
    self.modCombo:clear()
    local names, ids = AnimForge.Mods.gunModChoices()
    if #names == 0 then
        self.modCombo:addOptionWithData("(no gun mods active)", nil)
    else
        for i = 1, #names do self.modCombo:addOptionWithData(names[i], ids[i]) end
        self.modCombo.selected = 1
    end
end

-- Full refresh: mod list -> weapon list -> attachments for the selected weapon.
function AnimForgeTestRig:refresh()
    self:populateMods()
    self.gunPicker:setItems(AnimForge.Mods.gunInfos(self:modId()))
    self:refreshAttachments()
end

function AnimForgeTestRig:onModChange()
    self.selectedGun = nil
    self.gunPicker:setItems(AnimForge.Mods.gunInfos(self:modId()))
    self.gunPicker:setSelectedList({})
    self:refreshAttachments()
end

function AnimForgeTestRig:onGunSelect(ft)
    self.selectedGun = ft
    self:refreshAttachments()
end

-- Populate the right column with the selected weapon's attachments + reflect which are currently on it
-- (only when that weapon is the one actually equipped).
function AnimForgeTestRig:refreshAttachments()
    local infos = self.selectedGun and AnimForge.Mods.attachmentInfos(self:modId(), self.selectedGun) or {}
    self.attachByFt = {}
    for i = 1, #infos do self.attachByFt[infos[i].fullType] = infos[i].partType end
    self.attachPicker:setItems(infos)
    local attached = {}
    local p = getPlayer()
    local gun = p and p:getPrimaryHandItem()
    if gun and instanceof(gun, "HandWeapon") and self.selectedGun and gun:getFullType() == self.selectedGun then
        for i = 1, #infos do
            local existing = gun:getWeaponPart(infos[i].partType)
            if existing and existing:getFullType() == infos[i].fullType then attached[#attached + 1] = infos[i].fullType end
        end
    end
    self.attachPicker:setSelectedList(attached)
end

-- Equip the selected weapon if it is not already the one in hand; returns the equipped HandWeapon.
function AnimForgeTestRig:equipSelected()
    local p = getPlayer()
    if not p or not self.selectedGun then return nil end
    local gun = p:getPrimaryHandItem()
    if gun and instanceof(gun, "HandWeapon") and gun:getFullType() == self.selectedGun then return gun end
    local newGun = p:getInventory():AddItem(self.selectedGun)
    if not newGun then return nil end
    p:setPrimaryHandItem(newGun)
    if newGun:isTwoHandWeapon() then p:setSecondaryHandItem(newGun) end
    p:resetEquippedHandsModels()
    return newGun
end

function AnimForgeTestRig:onEquip()
    if self:equipSelected() then self:refreshAttachments() end
end

function AnimForgeTestRig:onUnequip()
    local p = getPlayer(); if not p then return end
    p:setPrimaryHandItem(nil); p:setSecondaryHandItem(nil); p:resetEquippedHandsModels()
    self:refreshAttachments()
end

-- Toggle the clicked attachment on the equipped weapon (auto-equips the selected weapon first, so
-- there is a gun to mount on). `sel` is the picker's new selected state for the row.
function AnimForgeTestRig:onAttachToggle(ft, sel)
    local partType = self.attachByFt and self.attachByFt[ft]
    if not partType then return end
    local gun = self:equipSelected()
    if not gun then return end
    local existing = gun:getWeaponPart(partType)
    if sel then
        if existing then gun:detachWeaponPart(partType) end
        gun:attachWeaponPart(instanceItem(ft))
    elseif existing and existing:getFullType() == ft then
        gun:detachWeaponPart(partType)
    end
    getPlayer():resetEquippedHandsModels()
    self:refreshAttachments()
end

-- ============================================================== TestRigWindow ==
-- A poppable, resizable window hosting the two-column test rig, so it can stay open beside the other
-- Anim Forge panels while you pose against the equipped weapon.
TestRigWindow = ISCollapsableWindow:derive("TestRigWindow")

function TestRigWindow:new(x, y)
    local o = ISCollapsableWindow.new(self, x or 240, y or 130, 460, 360)
    o.title = "Equipment"
    o.resizable = true
    return o
end

function TestRigWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local th = self:titleBarHeight()
    local pad = 8
    self.rig = AnimForgeTestRig:new(pad, th + pad, self.width - pad * 2, self.height - th - pad * 2)
    self.rig:initialise(); self.rig:instantiate()
    self:addChild(self.rig)
end

function TestRigWindow:onResize()
    ISCollapsableWindow.onResize(self)
    if self.rig then
        local th = self:titleBarHeight()
        local pad = 8
        self.rig:setWidth(self.width - pad * 2)
        self.rig:setHeight(self.height - th - pad * 2)
        self.rig:layout()
    end
end

return AnimForgeTestRig
