local addonName, ns = ...

local PREFIX = "GPCL_SYNC"
C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)


-- compat
local C_ChatInfo_SendChatMessage = C_ChatInfo.SendChatMessage or SendChatMessage -- Fallback for older WoW versions
local C_Item_GetItemInfo = C_Item.GetItemInfo or GetItemInfo

local LAST_SEEN_CLEANUP = 300 -- 5 minutes

ns.OnlineAddonUsers = {} -- [name] = { rank = index, guid = string, lastSeen = time }

local function IsLeader()
    if not IsInGuild() then return true end

    local myName = UnitName("player")
    local myGUID = UnitGUID("player")
    local _, _, myRank = GetGuildInfo("player")
    if not myRank then return true end

    local candidates = {}
    table.insert(candidates, { name = myName, rank = myRank, guid = myGUID })

    for name, data in pairs(ns.OnlineAddonUsers) do
        if (GetTime() - data.lastSeen) < LAST_SEEN_CLEANUP then
            table.insert(candidates, { name = name, rank = data.rank, guid = data.guid })
        end
    end

    table.sort(candidates, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.guid < b.guid
    end)

    return candidates[1].guid == myGUID
end

local function SendPresence(msgType)
    if not IsInGuild() then return end
    local _, _, rankIndex = GetGuildInfo("player")
    local guid = UnitGUID("player")
    local payload = string.format("%s:%d:%s", msgType, rankIndex or 99, guid)
    C_ChatInfo.SendAddonMessage(PREFIX, payload, "GUILD")
end

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
    local _, _, _, _, _, _, _, _, _, _, _, _, _, bindType = C_Item_GetItemInfo(itemLink)
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

-- --- Main Event Handler ---

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_GUILD")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        print("|cff00ff00GuildPriceCheck Loaded:|r Listening for ?[Item] in Guild Chat.")
        SendPresence("PING")

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = ...
        if prefix ~= PREFIX or sender == UnitName("player") then return end

        local msgType, rank, guid = strsplit(":", message)
        ns.OnlineAddonUsers[sender] = {
            rank = tonumber(rank) or 99,
            guid = guid,
            lastSeen = GetTime()
        }

        if msgType == "PING" then
            C_Timer.After(math.random(1, 15) / 10, function() SendPresence("PONG") end)
        end

    elseif event == "CHAT_MSG_GUILD" then
        local message, sender = ...
        -- Only proceed if the message starts with "?" AND I am the elected leader
        if not message:find("^%?") or not IsLeader() then return end

        for itemLink in message:gmatch("(|c.-|h.-|h|r)") do
            if Auctionator and Auctionator.API and Auctionator.API.v1 then
                local price = Auctionator.API.v1.GetAuctionPriceByItemLink(addonName, itemLink)
                
                if price and not IsItemSoulbound(itemLink) then
                    local response = string.format("Price for %s: %s", itemLink, FormatMoney(price))
                    C_ChatInfo_SendChatMessage(response, "GUILD")
                end
            end
        end
    end
end)
