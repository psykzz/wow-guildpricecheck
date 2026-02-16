local addonName, ns = ...

local PREFIX = "GPCL_SYNC"
C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

-- compat
local C_ChatInfo_SendChatMessage = C_ChatInfo.SendChatMessage or SendChatMessage -- Fallback for older WoW versions
local C_Item_GetItemInfo = C_Item.GetItemInfo or GetItemInfo

local LAST_SEEN_CLEANUP = 60 -- 1 minute

ns.OnlineAddonUsers = {}     -- [name] = { rank = index, guid = string, lastSeen = time }

local function CreateThrottledFunction(func, duration)
    local lastUsage = 0
    return function(...)
        local now = GetTime()
        if (now - lastUsage) >= duration then
            lastUsage = now
            return func(...)
        end
    end
end

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

local ThrottledSendPresence = CreateThrottledFunction(SendPresence, 30)

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
        local text = _G["GPCScanningTooltipTextLeft" .. i]:GetText()
        if text == ITEM_SOULBOUND then return true end
    end
    return false
end

-- --- Main Event Handler ---

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_GUILD")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        print("|cff00ff00GuildPriceCheck Loaded:|r Listening for ?[Item] in Guild Chat.")
        SendPresence("PING")
    elseif event == "PLAYER_LOGOUT" then
        SendPresence("LEAVE")
    elseif event == "PLAYER_REGEN_ENABLED" then
        ThrottledSendPresence("PING")
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = ...
        if prefix ~= PREFIX or sender == UnitName("player") then return end

        local msgType, rank, guid = strsplit(":", message)

        if msgType == "LEAVE" then
            ns.OnlineAddonUsers[sender] = nil
        else
            ns.OnlineAddonUsers[sender] = {
                rank = tonumber(rank) or 99,
                guid = guid,
                lastSeen = GetTime()
            }

            if msgType == "PING" then
                C_Timer.After(math.random(1, 15) / 10, function() SendPresence("PONG") end)
            end
        end
    elseif event == "CHAT_MSG_GUILD" then
        local message, sender = ...

        if not IsLeader() then return print("not leader") end

        if not message:find("^%?") or not IsLeader() then return end

        for itemLink in message:gmatch("(|c.-|h.-|h|r)") do
            local price = nil

            if TSM_API then
                price = TSM_API.GetCustomPriceValue("DBMarket", itemLink)
            end

            if not price and Auctionator and Auctionator.API and Auctionator.API.v1 then
                price = Auctionator.API.v1.GetAuctionPriceByItemLink(addonName, itemLink)
            end

            if IsItemSoulbound(itemLink) then
                local response = string.format("No price available for %s. Soulbound item.", itemLink)
                C_ChatInfo_SendChatMessage(response, "GUILD")
                return
            end

            if not price then
                local response = string.format("No price available for %s. No market data", itemLink)
                C_ChatInfo_SendChatMessage(response, "GUILD")
                return
            end

            local response = string.format("Price for %s: %s", itemLink, FormatMoney(price))
            C_ChatInfo_SendChatMessage(response, "GUILD")
        end
    end
end)


local function GetStatusColor(isMe, isLeader)
    if isLeader then return "ff00ff00" end -- Green for Leader
    if isMe then return "ff00ffff" end     -- Cyan for You
    return "ffffffff"                      -- White for Others
end

local function ShowStatus()
    local myName = UnitName("player")
    local electedLeader = "Unknown"

    -- Determine who the leader is for the status printout
    -- (Uses the same logic as your IsLeader function)
    local candidates = {}
    local _, _, myRank = GetGuildInfo("player")
    table.insert(candidates, { name = myName, rank = myRank or 99, guid = UnitGUID("player") })

    for name, data in pairs(ns.OnlineAddonUsers) do
        if (GetTime() - data.lastSeen) < 300 then
            table.insert(candidates, { name = name, rank = data.rank, guid = data.guid })
        end
    end

    table.sort(candidates, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.guid < b.guid
    end)

    if candidates[1] then electedLeader = candidates[1].name end

    print("|cffffff00--- GPC Network Status ---|r")
    print(string.format("Current Leader: |cff00ff00%s|r", electedLeader))

    -- Print list of all peers
    for name, data in pairs(ns.OnlineAddonUsers) do
        local isLeader = (name == electedLeader)
        local color = GetStatusColor(false, isLeader)
        local secondsAgo = math.floor(GetTime() - data.lastSeen)

        print(string.format("|c%s[%s]|r - Rank Index: %d (Seen %ds ago)",
            color, name, data.rank, secondsAgo))
    end

    -- Show self
    local myColor = GetStatusColor(true, myName == electedLeader)
    print(string.format("|c%s[%s] (You)|r - Rank Index: %d",
        myColor, myName, myRank or 99))
    print("|cffffff00--------------------------|r")
end

-- --- Slash Command Registration ---
SLASH_GPC1 = "/gpc"
SlashCmdList["GPC"] = function(msg)
    local cmd = msg:lower():trim()
    if cmd == "status" then
        ShowStatus()
    elseif cmd == "ping" then
        print("Sending manual network ping...")
        -- Explicitly call your SendPresence function from earlier
        if SendPresence then SendPresence("PING") end
    else
        print("GuildPriceCheck Usage:")
        print("  /gpc status - See online peers and elected leader")
        print("  /gpc ping   - Force a network refresh")
    end
end
