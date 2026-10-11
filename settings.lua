local addonName, ns = ...

local panel = CreateFrame("Frame", "GuildPriceCheckSettingsPanel", UIParent)
panel.name = "GuildPriceCheck"
panel:Hide()

local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -32, 16)

local content = CreateFrame("Frame", nil, scrollFrame)
content:SetSize(1, 1)
scrollFrame:SetScrollChild(content)

local title = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetText(addonName)

local about = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
about:SetJustifyH("LEFT")
about:SetWordWrap(true)
about:SetText(
    "GuildPriceCheck replies to guild messages that start with ? followed by an item link. " ..
    "The online addon client with the newest version is preferred to answer; ties are resolved " ..
    "by guild rank and then GUID, which helps prevent duplicate replies.\n\n" ..
    "Prices use fresh Auctionator data when available, then fall back to TSM's DBMinBuyout, " ..
    "and finally to older Auctionator data. Auctionator is required; TSM is optional."
)

local historyTitle = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
historyTitle:SetText("Recent Usage (last 20)")

local historyEmpty = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
historyEmpty:SetJustifyH("LEFT")
historyEmpty:SetText("No price checks have been handled by this client yet.")

local usageRows = {}

local function GetUsageRow(index)
    if usageRows[index] then
        return usageRows[index]
    end

    local row = CreateFrame("Frame", nil, content)
    row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.text:SetJustifyH("LEFT")
    row.text:SetJustifyV("TOP")
    row.text:SetWordWrap(true)
    usageRows[index] = row
    return row
end

local function RefreshUsage()
    local width = math.max(1, scrollFrame:GetWidth() - 28)
    content:SetWidth(width)
    title:ClearAllPoints()
    title:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)

    about:ClearAllPoints()
    about:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -28)
    about:SetWidth(width)

    local nextTop = -28 - math.max(about:GetStringHeight(), 1) - 20
    historyTitle:ClearAllPoints()
    historyTitle:SetPoint("TOPLEFT", content, "TOPLEFT", 0, nextTop)
    nextTop = nextTop - math.max(historyTitle:GetStringHeight(), 1) - 8

    local history = ns.UsageHistory
    local historyCount = #history
    historyEmpty:ClearAllPoints()
    if historyCount == 0 then
        historyEmpty:Show()
        historyEmpty:SetPoint("TOPLEFT", content, "TOPLEFT", 0, nextTop)
        historyEmpty:SetWidth(width)
        nextTop = nextTop - math.max(historyEmpty:GetStringHeight(), 1) - 12
    else
        historyEmpty:Hide()
    end

    for index, entry in ipairs(history) do
        local row = GetUsageRow(index)
        local timestamp = type(entry.timestamp) == "number" and entry.timestamp or time()
        row.text:SetText(string.format(
            "%s [%s] %s: %s\n>>> %s",
            date("%H:%M:%S", timestamp),
            entry.channel or "Guild",
            entry.user or "Unknown",
            entry.message or "",
            entry.reply or ""
        ))
        row.text:ClearAllPoints()
        row.text:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -6)
        row.text:SetWidth(math.max(1, width - 16))
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, nextTop)
        row:SetWidth(width)
        row:SetHeight(math.max(row.text:GetStringHeight() + 12, 24))
        row:Show()
        nextTop = nextTop - row:GetHeight() - 4
    end

    for index = historyCount + 1, #usageRows do
        usageRows[index]:Hide()
    end

    content:SetHeight(math.max(scrollFrame:GetHeight(), -nextTop + 12))
end

scrollFrame:SetScript("OnSizeChanged", RefreshUsage)
panel:SetScript("OnShow", RefreshUsage)
ns.RefreshUsage = RefreshUsage

local category
if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(category)
elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
end

function ns.OpenSettings()
    if category and Settings and Settings.OpenToCategory then
        local categoryID = category.GetID and category:GetID() or category.ID
        Settings.OpenToCategory(categoryID)
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end
