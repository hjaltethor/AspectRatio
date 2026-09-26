local _, ns = ...

local ROW_HEIGHT = 34

function ns.CreateOptions()
    if not (Settings and Settings.RegisterCanvasLayoutCategory) then return end
    local db = ns.db

    local panel = CreateFrame("Frame")

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("AspectRatio")

    local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetText("Choose which aspect you want to be reminded about in each type of content.")

    local current = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    current:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -12)

    local dropdowns = {}
    for i, ctx in ipairs(ns.CONTEXTS) do
        local label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("TOPLEFT", current, "BOTTOMLEFT", 0, -24 - (i - 1) * ROW_HEIGHT)
        label:SetWidth(180)
        label:SetJustifyH("LEFT")
        label:SetText(ctx.label)

        local dropdown = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
        dropdown:SetPoint("LEFT", label, "RIGHT", 10, 0)
        dropdown:SetWidth(240)
        dropdown:SetupMenu(function(_, root)
            local function IsSelected(value)
                return ns.ResolveChoice(db.aspects[ctx.key]) == value
            end
            local function SetSelected(value)
                db.aspects[ctx.key] = value
                ns.Update()
            end
            root:CreateRadio("Any aspect", IsSelected, SetSelected, "any")
            root:CreateRadio("No reminder", IsSelected, SetSelected, "off")
            root:CreateDivider()
            for _, aspect in ipairs(ns.GetKnownAspects()) do
                root:CreateRadio(("|T%s:16|t %s"):format(aspect.icon, aspect.name), IsSelected, SetSelected, aspect.name)
            end
        end)
        dropdowns[#dropdowns + 1] = dropdown
    end

    local checkTop = -24 - #ns.CONTEXTS * ROW_HEIGHT - 12
    local checkboxes = {}
    local function Checkbox(text, key)
        local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", current, "BOTTOMLEFT", -4, checkTop - #checkboxes * 28)
        local cbLabel = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        cbLabel:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        cbLabel:SetText(text)
        cb:SetScript("OnClick", function(self)
            db[key] = self:GetChecked() and true or false
            ns.Update()
        end)
        cb.key = key
        checkboxes[#checkboxes + 1] = cb
    end
    Checkbox("Only remind in combat", "combatOnly")
    Checkbox("Play warning sound", "sound")
    Checkbox("Hide while mounted", "hideMounted")

    local Refresh
    local buttonTop = checkTop - #checkboxes * 28 - 12
    local function Button(text, x, onClick)
        local btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        btn:SetSize(130, 22)
        btn:SetPoint("TOPLEFT", current, "BOTTOMLEFT", x, buttonTop)
        btn:SetText(text)
        btn:SetScript("OnClick", function() onClick(); Refresh() end)
        return btn
    end
    local unlockBtn = Button("Unlock", 0, function() ns.SetUnlocked(not ns.IsUnlocked()) end)
    local testBtn = Button("Test", 140, function() ns.SetTesting(not ns.IsTesting()) end)
    Button("Reset position", 280, ns.ResetPosition)

    local contextLabels = {}
    for _, ctx in ipairs(ns.CONTEXTS) do contextLabels[ctx.key] = ctx.label end

    Refresh = function()
        current:SetText("Current content: |cffffffff" .. contextLabels[ns.CurrentContext()] .. "|r")
        for _, dropdown in ipairs(dropdowns) do dropdown:GenerateMenu() end
        for _, cb in ipairs(checkboxes) do cb:SetChecked(db[cb.key]) end
        unlockBtn:SetText(ns.IsUnlocked() and "Lock" or "Unlock")
        testBtn:SetText(ns.IsTesting() and "Stop test" or "Test")
    end
    panel:SetScript("OnShow", Refresh)

    local category = Settings.RegisterCanvasLayoutCategory(panel, "AspectRatio")
    Settings.RegisterAddOnCategory(category)
    ns.OpenOptions = function()
        Settings.OpenToCategory(category:GetID())
    end
end
