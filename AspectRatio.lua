local ADDON_NAME, ns = ...

-- Base IDs (Hawk, Monkey, Cheetah, Pack, Beast, Wild, Viper, Dragonhawk) give localized names.
local ASPECT_SPELL_IDS = { 13165, 13163, 5118, 13159, 13161, 20043, 34074, 61846 }
local ASPECT_NAMES_EN = {
    "Aspect of the Hawk", "Aspect of the Monkey", "Aspect of the Cheetah", "Aspect of the Pack",
    "Aspect of the Beast", "Aspect of the Wild", "Aspect of the Viper", "Aspect of the Dragonhawk",
    "Aspect of the Fox", "Aspect of the Iron Hawk",
}
local FALLBACK_ICON = "Interface\\Icons\\Spell_Nature_RavenForm"
local SOUND_THROTTLE = 10

local DEFAULTS = { combatOnly = false, sound = true, hideMounted = true, point = "CENTER", x = 0, y = 150 }

-- Per-content choice: "any", "off", or a localized aspect name.
local CONTEXTS = {
    { key = "world", label = "Open world", default = "any" },
    { key = "city", label = "City / Inn (resting)", default = "off" },
    { key = "dungeon", label = "Dungeon", default = "any" },
    { key = "raid", label = "Raid", default = "any" },
    { key = "pvp", label = "Battleground / Arena", default = "any" },
}

local db
local aspectNames, aspectIDs = {}, {}
local knownList, knownByName = {}, {}
local knowsAspect = false
local bestIcon = FALLBACK_ICON
-- Active aspect name, false when none, nil when unknown.
local cachedActive
local shown = false
local lastSound = 0
local unlocked, testing = false, false

local function Readable(v)
    return not (issecretvalue and issecretvalue(v))
end

local function Unpack(ok, ...)
    if ok then return ... end
end

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    return Unpack(pcall(fn, ...))
end

local function SpellInfo(spell)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = SafeCall(C_Spell.GetSpellInfo, spell)
        if type(info) == "table" then return info.name, info.spellID, info.iconID end
        return nil
    end
    local name, _, icon, _, _, _, id = SafeCall(GetSpellInfo, spell)
    return name, id, icon
end

local function IsKnown(id)
    if not id then return false end
    if C_SpellBook and SafeCall(C_SpellBook.IsSpellKnown, id) == true then return true end
    if SafeCall(IsPlayerSpell, id) == true then return true end
    if SafeCall(IsSpellKnown, id) == true then return true end
    return false
end

local function IsAspectName(name)
    return aspectNames[name] or name:find("^Aspect of ") ~= nil
end

local function AspectSpellName(spellID)
    if not Readable(spellID) or type(spellID) ~= "number" then return nil end
    local name = SpellInfo(spellID)
    if not (Readable(name) and type(name) == "string") then return nil end
    if aspectIDs[spellID] or IsAspectName(name) then return name end
end

---------------------------------------------------------------------------
-- Reminder frame
---------------------------------------------------------------------------
local frame = CreateFrame("Frame", "AspectRatioFrame", UIParent)
frame:SetSize(56, 56)
frame:SetFrameStrata("HIGH")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")
frame:EnableMouse(false)
frame:Hide()

local border = frame:CreateTexture(nil, "BACKGROUND")
border:SetPoint("TOPLEFT", -3, 3)
border:SetPoint("BOTTOMRIGHT", 3, -3)
border:SetColorTexture(1, 0.2, 0.1, 0.9)

local icon = frame:CreateTexture(nil, "ARTWORK")
icon:SetAllPoints()
icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
icon:SetTexture(FALLBACK_ICON)

local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
label:SetPoint("TOP", frame, "BOTTOM", 0, -6)
label:SetTextColor(1, 0.3, 0.2)

local pulse = border:CreateAnimationGroup()
pulse:SetLooping("BOUNCE")
local fade = pulse:CreateAnimation("Alpha")
fade:SetFromAlpha(1)
fade:SetToAlpha(0.2)
fade:SetDuration(0.5)
fade:SetSmoothing("IN_OUT")

frame:SetScript("OnShow", function() pulse:Play() end)
frame:SetScript("OnHide", function() pulse:Stop() end)
frame:SetScript("OnDragStart", function(self)
    if unlocked then self:StartMoving() end
end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint()
    db.point, db.x, db.y = point, x, y
end)

local function ApplyPosition()
    frame:ClearAllPoints()
    frame:SetPoint(db.point, UIParent, db.point, db.x, db.y)
end

---------------------------------------------------------------------------
-- Aspect detection
---------------------------------------------------------------------------
local function RefreshKnownAspects()
    wipe(aspectNames)
    wipe(aspectIDs)
    wipe(knownList)
    wipe(knownByName)
    knowsAspect = false
    bestIcon = nil

    local candidates = {}
    for _, id in ipairs(ASPECT_SPELL_IDS) do
        aspectIDs[id] = true
        local name = SpellInfo(id)
        if type(name) == "string" then candidates[#candidates + 1] = name end
    end
    for _, name in ipairs(ASPECT_NAMES_EN) do candidates[#candidates + 1] = name end

    for _, candidate in ipairs(candidates) do
        aspectNames[candidate] = true
        local name, id, iconID = SpellInfo(candidate)
        if type(name) == "string" and type(id) == "number" then
            aspectNames[name] = true
            aspectIDs[id] = true
            if IsKnown(id) and not knownByName[name] then
                knowsAspect = true
                knownByName[name] = iconID or FALLBACK_ICON
                knownList[#knownList + 1] = { name = name, icon = knownByName[name] }
                bestIcon = bestIcon or iconID
            end
        end
    end
    bestIcon = bestIcon or FALLBACK_ICON
end

local function FromPlayer(aura)
    local src = aura.sourceUnit
    if Readable(src) and type(src) == "string" then
        return src == "player" or UnitIsUnit(src, "player")
    end
    local own = aura.isFromPlayerOrPlayerPet
    if Readable(own) and type(own) == "boolean" then return own end
    return true
end

-- Some clients put aspects on the stance bar, which stays readable in combat.
local function StanceAspect()
    local count = SafeCall(GetNumShapeshiftForms)
    if not Readable(count) or type(count) ~= "number" then return nil end
    for i = 1, count do
        local _, active, _, spellID = SafeCall(GetShapeshiftFormInfo, i)
        if Readable(active) and active then
            local name = AspectSpellName(spellID)
            if name then return name end
        end
    end
end

-- Returns the active aspect name, false for none, or nil when aura data is restricted.
local function AspectActive()
    local stance = StanceAspect()
    if stance then return stance end

    local api = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if api then
        local uncertain = false
        for i = 1, 255 do
            local ok, aura = pcall(api, "player", i, "HELPFUL")
            if not ok or not Readable(aura) then uncertain = true; break end
            if aura == nil then break end
            local name = aura.name
            local nameOK = Readable(name) and type(name) == "string"
            local aspect
            if nameOK then
                aspect = IsAspectName(name) and name
            else
                aspect = AspectSpellName(aura.spellId)
            end
            if aspect then
                if FromPlayer(aura) then return aspect end
            elseif not nameOK then
                uncertain = true
            end
        end
        if not uncertain then return false end
    end

    local byID = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
    if byID then
        for id in pairs(aspectIDs) do
            local ok, aura = pcall(byID, id)
            if ok and Readable(aura) and aura then
                local name = AspectSpellName(id)
                if name then return name end
            end
        end
    end
    return nil
end

local function CurrentContext()
    local inInstance, instanceType = IsInInstance()
    if inInstance then
        if instanceType == "party" then return "dungeon" end
        if instanceType == "raid" then return "raid" end
        if instanceType == "pvp" or instanceType == "arena" then return "pvp" end
    end
    if IsResting() then return "city" end
    return "world"
end

-- Falls back to "any" when the chosen aspect isn't known (e.g. not learned yet).
local function ResolveChoice(choice)
    if choice == "off" then return "off" end
    if choice ~= "any" and knownByName[choice] then return choice end
    return "any"
end

---------------------------------------------------------------------------
-- Update loop
---------------------------------------------------------------------------
local function ShouldRemind()
    if not knowsAspect then return false end
    local active = AspectActive()
    if active ~= nil then cachedActive = active end

    if UnitIsDeadOrGhost("player") or UnitOnTaxi("player") then return false end
    if UnitInVehicle and UnitInVehicle("player") then return false end
    if db.hideMounted and IsMounted() then return false end
    if db.combatOnly and not InCombatLockdown() then return false end

    local desired = ResolveChoice(db.aspects[CurrentContext()])
    if desired == "off" or cachedActive == nil then return false end
    if desired == "any" then return cachedActive == false, desired end
    return cachedActive ~= desired, desired
end

local function Update()
    if not db then return end
    if unlocked or testing then
        icon:SetTexture(bestIcon)
        label:SetText(unlocked and "Drag to move\n/aspect lock" or "No Aspect!")
        frame:Show()
        return
    end

    local remind, desired = ShouldRemind()
    if remind and not shown and db.sound then
        local now = GetTime()
        if now - lastSound >= SOUND_THROTTLE then
            lastSound = now
            PlaySound(SOUNDKIT.RAID_WARNING, "Master")
        end
    end
    shown = remind
    if desired == "any" then
        icon:SetTexture(bestIcon)
        label:SetText("No Aspect!")
    elseif desired then
        icon:SetTexture(knownByName[desired])
        label:SetText("Use " .. desired)
    end
    frame:SetShown(remind)
end

local function SetUnlocked(value)
    unlocked = value
    frame:EnableMouse(value)
    Update()
end

local function ResetPosition()
    db.point, db.x, db.y = DEFAULTS.point, DEFAULTS.x, DEFAULTS.y
    ApplyPosition()
end

ns.CONTEXTS = CONTEXTS
ns.CurrentContext = CurrentContext
ns.ResolveChoice = ResolveChoice
ns.Update = Update
ns.SetUnlocked = SetUnlocked
ns.ResetPosition = ResetPosition
ns.GetKnownAspects = function() return knownList end
ns.IsUnlocked = function() return unlocked end
ns.IsTesting = function() return testing end
ns.SetTesting = function(value) testing = value; Update() end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        local _, class = UnitClass("player")
        if class ~= "HUNTER" then
            self:UnregisterAllEvents()
            return
        end

        AspectRatioDB = AspectRatioDB or {}
        db = AspectRatioDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = v end
        end
        if type(db.aspects) ~= "table" then db.aspects = {} end
        for _, ctx in ipairs(CONTEXTS) do
            if db.aspects[ctx.key] == nil then db.aspects[ctx.key] = ctx.default end
        end
        ns.db = db
        ApplyPosition()
        RefreshKnownAspects()
        ns.CreateOptions()

        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("SPELLS_CHANGED")
        self:RegisterEvent("PLAYER_REGEN_DISABLED")
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        self:RegisterEvent("PLAYER_DEAD")
        self:RegisterEvent("PLAYER_ALIVE")
        self:RegisterEvent("PLAYER_UNGHOST")
        self:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
        self:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
        self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        self:RegisterEvent("PLAYER_UPDATE_RESTING")
        self:RegisterUnitEvent("UNIT_AURA", "player")
        self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
        C_Timer.NewTicker(1, Update)
    elseif event == "SPELLS_CHANGED" then
        RefreshKnownAspects()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...
        local name = AspectSpellName(spellID)
        if name then cachedActive = name end
    elseif event == "PLAYER_DEAD" then
        cachedActive = false
    end
    Update()
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffabd473AspectRatio|r: " .. msg)
end

local function OnOff(v) return v and "|cff00ff00on|r" or "|cffff0000off|r" end

SLASH_ASPECTRATIO1 = "/aspect"
SLASH_ASPECTRATIO2 = "/aspectratio"
SlashCmdList.ASPECTRATIO = function(msg)
    if not db then
        Print("only active on hunters.")
        return
    end
    local cmd = (msg or ""):lower():match("^%s*(%S*)")
    if cmd == "" and ns.OpenOptions then
        ns.OpenOptions()
    elseif cmd == "unlock" then
        SetUnlocked(true)
        Print("unlocked. Drag the icon, then type /aspect lock.")
    elseif cmd == "lock" then
        SetUnlocked(false)
        Print("locked.")
    elseif cmd == "combat" then
        db.combatOnly = not db.combatOnly
        Print("combat only: " .. OnOff(db.combatOnly))
    elseif cmd == "sound" then
        db.sound = not db.sound
        Print("sound: " .. OnOff(db.sound))
    elseif cmd == "mount" then
        db.hideMounted = not db.hideMounted
        Print("hide while mounted: " .. OnOff(db.hideMounted))
    elseif cmd == "test" then
        testing = not testing
        Print("test mode: " .. OnOff(testing))
    elseif cmd == "reset" then
        ResetPosition()
        Print("position reset.")
    else
        Print("commands:")
        Print("/aspect - open options")
        Print("/aspect unlock | lock - move the reminder")
        Print("/aspect combat - only remind in combat (" .. OnOff(db.combatOnly) .. ")")
        Print("/aspect sound - toggle warning sound (" .. OnOff(db.sound) .. ")")
        Print("/aspect mount - hide while mounted (" .. OnOff(db.hideMounted) .. ")")
        Print("/aspect test - toggle test display")
        Print("/aspect reset - reset position")
    end
    Update()
end
