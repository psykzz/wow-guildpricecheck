local _, ns = ...

ns.PREFIX = "GPCL_SYNC"

-- compat
local C_ChatInfo_SendChatMessage = C_ChatInfo.SendChatMessage or SendChatMessage
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

function ns.CompareVersions(v1, v2)
    -- Returns: -1 if v1 < v2, 0 if equal, 1 if v1 > v2
    local p1_1, p1_2, p1_3 = v1:match("^(%d+)%.(%d+)%.(%d+)")
    local p2_1, p2_2, p2_3 = v2:match("^(%d+)%.(%d+)%.(%d+)")

    p1_1, p1_2, p1_3 = tonumber(p1_1) or 0, tonumber(p1_2) or 0, tonumber(p1_3) or 0
    p2_1, p2_2, p2_3 = tonumber(p2_1) or 0, tonumber(p2_2) or 0, tonumber(p2_3) or 0

    if p1_1 ~= p2_1 then return p1_1 > p2_1 and 1 or -1 end
    if p1_2 ~= p2_2 then return p1_2 > p2_2 and 1 or -1 end
    if p1_3 ~= p2_3 then return p1_3 > p2_3 and 1 or -1 end
    return 0
end

-- Normalizes a player name to "Name-Realm" form so OnlineAddonUsers keys and
-- comparisons are consistent regardless of whether the caller (chat events,
-- addon messages, etc.) supplied a realm-qualified name.
function ns.NormalizeName(name)
    if not name then return name end
    if name:find("-") then return name end
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName():gsub("%s+", "")
    return name .. "-" .. realm
end

-- Builds the sorted list of leader-election candidates (self + online addon
-- users), used by both ns.IsLeader() and the /gpc status display so their
-- notion of "who is leader" can never drift apart.
function ns.GetElectionCandidates()
    local myName = ns.NormalizeName(UnitName("player"))
    local myGUID = UnitGUID("player")
    local _, _, myRank = GetGuildInfo("player")

    local candidates = {}
    table.insert(candidates, { name = myName, rank = myRank or 99, guid = myGUID, version = ns.VERSION })

    for name, data in pairs(ns.OnlineAddonUsers) do
        local isOnline = ns.IsPlayerActuallyOnline(name)
        if isOnline then
            table.insert(candidates, { name = name, rank = data.rank, guid = data.guid, version = data.version })
        end
    end

    table.sort(candidates, function(a, b)
        -- Filter out users with older versions - they should never be elected
        local aIsNewer = ns.CompareVersions(a.version, b.version) >= 0
        local bIsNewer = ns.CompareVersions(b.version, a.version) >= 0

        if aIsNewer and not bIsNewer then return true end
        if bIsNewer and not aIsNewer then return false end

        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.guid < b.guid
    end)

    return candidates, myRank
end

function ns.IsLeader()
    -- Fail closed: if we're not in a guild, or our own rank hasn't loaded
    -- yet, we can't safely determine our place in the election, so assume
    -- we're not the leader rather than risking duplicate replies from
    -- everyone in this state simultaneously (e.g. on a mass reconnect).
    if not IsInGuild() then return false end

    local _, _, myRank = GetGuildInfo("player")
    if not myRank then return false end

    local candidates = ns.GetElectionCandidates()
    return candidates[1].guid == UnitGUID("player")
end

ns.ThrottledGuildPresenceUpdate = ns.CreateThrottledFunction(function()
    if IsInGuild() then
        C_GuildInfo.GuildRoster()
    end
end, 10)

function ns.SendAddonMessage(prefix, message, channel, target)
    if ns.AceComm then
        ns.AceComm:SendCommMessage(prefix, message, channel, target)
    else
        C_ChatInfo.SendAddonMessage(prefix, message, channel, target)
    end
end

function ns.SendPresence(msgType)
    if not IsInGuild() then return end
    local _, _, rankIndex = GetGuildInfo("player")
    local guid = UnitGUID("player")
    local payload = string.format("%s:%d:%s:%s", msgType, rankIndex or 99, guid, ns.VERSION)

    ns.SendAddonMessage(ns.PREFIX, payload, "GUILD")

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

    targetName = ns.NormalizeName(targetName)

    local numMembers = GetNumGuildMembers()
    for i = 1, numMembers do
        local fullName, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)

        if fullName == targetName then
            return isOnline
        end
    end

    return false
end
