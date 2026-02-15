local addonName, ns = ...

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_GUILD")

local function FormatMoney(amount)
    if not amount or amount <= 0 then return "0c" end
    local gold = math.floor(amount / 10000)
    local silver = math.floor((amount % 10000) / 100)
    local copper = amount % 100
    local str = ""
    if gold > 0 then str = str .. gold .. "g " end
    if silver > 0 then str = str .. silver .. "s " end
    if copper > 0 then str = str .. copper .. "c" end
    return str
end

local function IsItemSoulbound(itemLink)
    local _, _, _, _, _, _, _, _, _, _, _, _, _, bindType = GetItemInfo(itemLink)
    if bindType == 1 or bindType == 4 then return true end
    
    local scanner = CreateFrame("GameTooltip", "GPCScanningTooltip", nil, "GameTooltipTemplate")
    scanner:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanner:SetHyperlink(itemLink)
    for i = 1, scanner:NumLines() do
        local text = _G["GPCScanningTooltipTextLeft"..i]:GetText()
        if text == ITEM_SOULBOUND then return true end
    end
    return false
end

frame:SetScript("OnEvent", function(self, event, message, sender)
    if not message:find("^%?") then return end

    for itemLink in message:gmatch("(|c.-|h.-|h|r)") do
        if Auctionator and Auctionator.API and Auctionator.API.v1 then
            local price = Auctionator.API.v1.GetAuctionPriceByItemLink(addonName, itemLink)
            
            if price then
                if not IsItemSoulbound(itemLink) then
                    local response = string.format("Price for %s: %s", 
                        itemLink, FormatMoney(price))
                    
                    SendChatMessage(response, "GUILD")
                end
            end
        end
    end
end)

print("|cff00ff00GuildPriceCheck Loaded:|r Listening for ?[Item] in Guild Chat.")