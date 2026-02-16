local addonName, ns = ...

ns.PREFIX = "GPCL_SYNC"

-- compat
local C_ChatInfo_SendChatMessage = C_ChatInfo.SendChatMessage or SendChatMessage -- Fallback for older WoW versions
local C_Item_GetItemInfo = C_Item.GetItemInfo or GetItemInfo

function ns.SendChatMessage(message, channel)
    return C_ChatInfo_SendChatMessage(message, channel)
end

function ns.GetItemInfo(itemLink)
    return C_Item_GetItemInfo(itemLink)
end

function ns.CreateThrottledFunction(func, duration)
    local lastUsage = 0
    return function(...)
        local now = GetTime()
        if (now - lastUsage) >= duration then
            lastUsage = now
            return func(...)
        end
    end
end

function ns.IsLeader()
    if not IsInGuild() then return true end

    local myName = UnitName("player")
    local myGUID = UnitGUID("player")
    local _, _, myRank = GetGuildInfo("player")
    if not myRank then return true end

    local candidates = {}
    table.insert(candidates, { name = myName, rank = myRank, guid = myGUID })

    for name, data in pairs(ns.OnlineAddonUsers) do
        local isOnline = ns.IsPlayerActuallyOnline(name)
        if isOnline then
            table.insert(candidates, { name = name, rank = data.rank, guid = data.guid })
        end
    end

    table.sort(candidates, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.guid < b.guid
    end)

    return candidates[1].guid == myGUID
end

ns.ThrottledGuildPresenceUpdate = ns.CreateThrottledFunction(function()
    if IsInGuild() then
        C_GuildInfo.GuildRoster()
    end
end, 10)

function ns.SendPresence(msgType)
    if not IsInGuild() then return end
    local _, _, rankIndex = GetGuildInfo("player")
    local guid = UnitGUID("player")
    local payload = string.format("%s:%d:%s", msgType, rankIndex or 99, guid)
    C_ChatInfo.SendAddonMessage(ns.PREFIX, payload, "GUILD")

    -- Additionally request roster information to validate "pongs" are online still.
    ns.ThrottledGuildPresenceUpdate()
end

ns.ThrottledSendPresence = ns.CreateThrottledFunction(ns.SendPresence, 30)

function ns.FormatMoney(amount)
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

function ns.IsItemSoulbound(itemLink)
    local _, _, _, _, _, _, _, _, _, _, _, _, _, bindType = ns.GetItemInfo(itemLink)
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

function ns.GetStatusColor(isMe, isLeader)
    if isLeader then return "ff00ff00" end -- Green for Leader
    if isMe then return "ff00ffff" end     -- Cyan for You
    return "ffffffff"                      -- White for Others
end


function ns.IsPlayerActuallyOnline(targetName)
    if not IsInGuild() then return false end
    
    -- Ensure we have the full name (Name-Realm) for comparison
    -- If targetName is just "Character", we need to handle that
    local myRealm = GetRealmName():gsub("%s+", "")
    if not targetName:find("-") then
        targetName = targetName .. "-" .. myRealm
    end

    local numMembers = GetNumGuildMembers()
    for i = 1, numMembers do
        -- GetGuildRosterInfo returns:
        -- fullName, rankName, rankIndex, level, classDisplayName, zone, 
        -- publicNote, officerNote, isOnline, status, classFileName
        local fullName, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        
        if fullName == targetName then
            return isOnline
        end
    end
    
    return false
end