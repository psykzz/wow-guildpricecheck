local addonName, ns = ...

-- Compat: GetAddOnMetadata was moved to C_AddOns on this client; some clients
-- may still expose the old global too, so prefer C_AddOns but fall back.
local GetAddOnMetadataCompat = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local versionMeta = GetAddOnMetadataCompat and GetAddOnMetadataCompat(addonName, "Version")
ns.VERSION = (versionMeta and versionMeta:match("^([0-9.]+)")) or "0.0.0"

-- Try to use Ace3 comm if available, fall back to addon messages
ns.AceComm = (LibStub and LibStub:GetLibrary("AceComm-3.0", true) ~= nil) and LibStub("AceComm-3.0") or nil

if ns.AceComm then
    ns.AceComm:RegisterComm(ns.PREFIX, function(prefix, message, channel, sender)
        ns.HandleAddonMessage(prefix, message, channel, sender)
    end)
else
    C_ChatInfo.RegisterAddonMessagePrefix(ns.PREFIX)
end

ns.OnlineAddonUsers = {}     -- [name] = { name = string, rank = index, guid = string, version = string }

local MAX_USAGE_ENTRIES = 20

if type(GuildPriceCheckDB) ~= "table" then
    GuildPriceCheckDB = {}
end
if type(GuildPriceCheckDB.usage) ~= "table" then
    GuildPriceCheckDB.usage = {}
end
if type(GuildPriceCheckDB.auctionatorPriceTimestamps) ~= "table" then
    GuildPriceCheckDB.auctionatorPriceTimestamps = {}
end

ns.UsageHistory = GuildPriceCheckDB.usage
while #ns.UsageHistory > MAX_USAGE_ENTRIES do
    table.remove(ns.UsageHistory, 1)
end

local hookedAuctionatorSetPrice = {}

local function HookAuctionatorSetPrice(target)
    if type(target) ~= "table" or type(target.SetPrice) ~= "function"
        or hookedAuctionatorSetPrice[target.SetPrice] then
        return
    end

    local originalSetPrice = target.SetPrice
    local hookedSetPrice = function(self, dbKey, ...)
        local result = originalSetPrice(self, dbKey, ...)
        if dbKey ~= nil then
            GuildPriceCheckDB.auctionatorPriceTimestamps[tostring(dbKey)] = time()
        end
        return result
    end

    hookedAuctionatorSetPrice[hookedSetPrice] = true
    target.SetPrice = hookedSetPrice
end

local function HookAuctionatorPriceTimestamps()
    if not Auctionator then return end
    HookAuctionatorSetPrice(Auctionator.DatabaseMixin)
    HookAuctionatorSetPrice(Auctionator.Database)
end

HookAuctionatorPriceTimestamps()

function ns.RecordUsage(request, reply)
    table.insert(ns.UsageHistory, {
        timestamp = request.timestamp or time(),
        channel = request.channel or "Guild",
        user = request.user or "Unknown",
        message = request.message,
        reply = reply,
    })

    while #ns.UsageHistory > MAX_USAGE_ENTRIES do
        table.remove(ns.UsageHistory, 1)
    end

    if ns.RefreshUsage then
        ns.RefreshUsage()
    end
end

-- TSM's public API does not expose a per-item last-scan/age value, so we can't
-- truly compare freshness both ways. Only prefer Auctionator over TSM when its
-- data is within this many days old; otherwise fall back to TSM since its own
-- freshness is unknown.
ns.AUCTIONATOR_FRESHNESS_THRESHOLD_DAYS = 1

-- Dedupe/backoff for guild price replies: since leader election can briefly
-- diverge (see ns.IsLeader), more than one client may believe it's the
-- leader for a given query. To reduce duplicate answers, replies are sent
-- after a small random delay, and any reply seen (ours or another leader's)
-- for a given item link suppresses further replies to that item for a short
-- window.
ns.RecentlyAnsweredItems = {}
local ANSWER_DEDUPE_WINDOW_SECONDS = 5
local PRICE_REPLY_JITTER_MIN_SECONDS = 0.1
local PRICE_REPLY_JITTER_MAX_SECONDS = 0.5
local PONG_JITTER_MIN_SECONDS = 0.1
local PONG_JITTER_MAX_SECONDS = 1.5
local PRICE_PROTOCOL_VERSION = 1
local PRICE_COLLECTION_WINDOW_SECONDS = 0.75
local EARLY_PRICE_CANDIDATE_TTL_SECONDS = 2
local MAX_EARLY_PRICE_CANDIDATES = 128
local pendingPriceQueries = {}
local earlyPriceCandidates = {}
local AGE_UNIT_SECONDS = {m = 60, h = 3600, d = 86400}
local AGE_UNIT_SUFFIXES = {m = "m", h = "h", d = "d"}

local ITEM_LINK_PATTERN = "(|c.-|h.-|h|r)"

local function MarkItemAnswered(itemLink)
    ns.RecentlyAnsweredItems[itemLink] = GetTime()
end

local function WasItemRecentlyAnswered(itemLink)
    local answeredAt = ns.RecentlyAnsweredItems[itemLink]
    return answeredAt ~= nil and (GetTime() - answeredAt) < ANSWER_DEDUPE_WINDOW_SECONDS
end

local function RandomJitterSeconds(minSeconds, maxSeconds)
    return minSeconds + math.random() * (maxSeconds - minSeconds)
end

local function NormalizeAuctionatorAge(ageValue, ageUnit)
    if type(ageValue) ~= "number" or ageValue ~= ageValue
        or ageValue < 0 or ageValue >= math.huge then
        return nil, "?"
    end

    if ageUnit == "d" then
        return math.floor(ageValue + 0.5), "d"
    end
    if ageUnit ~= "s" then return nil, "?" end

    local ageMinutes = math.floor(ageValue / 60 + 0.5)
    if ageMinutes < 60 then
        return ageMinutes, "m"
    end
    return math.floor(ageValue / 3600 + 0.5), "h"
end

local function IsUsablePrice(price)
    return type(price) == "number" and price == price and price > 0 and price < math.huge
end

local function GetAuctionatorPriceTimestamp(dbKey)
    if dbKey == nil then return nil end
    return GuildPriceCheckDB.auctionatorPriceTimestamps[tostring(dbKey)]
end

local function GetAuctionatorPriceAge(itemLink)
    local utilities = Auctionator and Auctionator.Utilities
    if not utilities then return nil end

    local dbKeys
    utilities.DBKeyFromLink(itemLink, function(keys)
        dbKeys = keys
    end)

    local timestamp
    if dbKeys then
        timestamp = GetAuctionatorPriceTimestamp(dbKeys[1])
        if not timestamp and #dbKeys > 2 then
            timestamp = GetAuctionatorPriceTimestamp(dbKeys[2])
        end
    else
        timestamp = GetAuctionatorPriceTimestamp(utilities.BasicDBKeyFromLink(itemLink))
    end

    if type(timestamp) == "number" then
        local ageSeconds = time() - timestamp
        if ageSeconds >= 0 and ageSeconds < math.huge then
            return ageSeconds, "s"
        end
    end

    local ageDays = Auctionator.API.v1.GetAuctionAgeByItemLink(addonName, itemLink)
    if type(ageDays) == "number" and ageDays >= 0 and ageDays < math.huge then
        return ageDays, "d"
    end
end

-- Resolves the best available price for an item, preferring Auctionator's
-- data when it's fresh (see ns.AUCTIONATOR_FRESHNESS_THRESHOLD_DAYS above)
-- and falling back to TSM, then to stale Auctionator data.
-- The disenchant value is sourced independently from Auctionator. Auction age
-- is available only when an Auctionator price is selected. Auctionator age is
-- captured at scan processing time when possible, with its day-based API as a
-- fallback for prices scanned before this hook was installed.
local function ResolvePrice(itemLink)
    local tsmPrice = nil
    if TSM_API then
        tsmPrice = TSM_API.GetCustomPriceValue("DBMinBuyout", TSM_API.ToItemString(itemLink))
    end

    local auctionatorPrice, auctionatorDisenchant = nil, nil
    local auctionatorAge, auctionatorAgeUnit
    if Auctionator and Auctionator.API and Auctionator.API.v1 then
        auctionatorPrice = Auctionator.API.v1.GetAuctionPriceByItemLink(addonName, itemLink)
        auctionatorDisenchant = Auctionator.API.v1.GetDisenchantPriceByItemLink(addonName, itemLink)
        auctionatorAge, auctionatorAgeUnit = GetAuctionatorPriceAge(itemLink)
    end

    if not IsUsablePrice(tsmPrice) then tsmPrice = nil end
    if not IsUsablePrice(auctionatorPrice) then auctionatorPrice = nil end

    local auctionatorAgeSeconds
    if type(auctionatorAge) == "number" then
        local secondsPerUnit = auctionatorAgeUnit == "s" and 1
            or AGE_UNIT_SECONDS[auctionatorAgeUnit]
        if secondsPerUnit then
            auctionatorAgeSeconds = auctionatorAge * secondsPerUnit
        end
    end

    local price, source, age, ageUnit
    if auctionatorPrice and auctionatorAgeSeconds
        and auctionatorAgeSeconds <= ns.AUCTIONATOR_FRESHNESS_THRESHOLD_DAYS * 86400 then
        price, source = auctionatorPrice, "Auctionator"
        age, ageUnit = NormalizeAuctionatorAge(auctionatorAge, auctionatorAgeUnit)
    elseif tsmPrice then
        price, source = tsmPrice, "TSM"
    else
        price, source = auctionatorPrice, auctionatorPrice and "Auctionator" or nil
        if source then
            age, ageUnit = NormalizeAuctionatorAge(auctionatorAge, auctionatorAgeUnit)
        end
    end

    return {
        price = price,
        source = source,
        age = age,
        ageUnit = ageUnit or "?",
        disenchant = auctionatorDisenchant,
    }
end

local function BuildQueryID(message, sender, itemLink)
    local value = (sender or "") .. "\001" .. message .. "\001" .. itemLink
    local hash = 5381
    for index = 1, #value do
        hash = (hash * 33 + value:byte(index)) % 2147483647
    end
    return string.format("%08x", hash)
end

local function GetLocalElectionData()
    local _, _, rank = GetGuildInfo("player")
    return {
        name = ns.NormalizeName(UnitName("player")),
        version = ns.VERSION,
        rank = tonumber(rank) or 99,
        guid = UnitGUID("player") or "",
    }
end

local function WithElectionData(candidate, electionData)
    return {
        name = electionData.name,
        version = electionData.version,
        rank = electionData.rank,
        guid = electionData.guid,
        price = candidate.price,
        source = candidate.source,
        age = candidate.age,
        ageUnit = candidate.ageUnit,
    }
end

local function SendPriceCandidate(queryID, candidate)
    if not candidate or not IsUsablePrice(candidate.price) or not candidate.source then
        return
    end

    local electionData = GetLocalElectionData()
    if electionData.guid == "" then return end

    local ageUnit = candidate.ageUnit or "?"
    local ageValue = "?"
    if AGE_UNIT_SECONDS[ageUnit] then
        if type(candidate.age) ~= "number" or candidate.age < 0 then return end
        ageValue = tostring(math.floor(candidate.age + 0.5))
    elseif ageUnit ~= "?" then
        return
    end

    local payload = string.format(
        "PRICE:%d:%s:%s:%s:%s:%s:%d:%d:%s",
        PRICE_PROTOCOL_VERSION,
        queryID,
        electionData.version,
        candidate.source,
        ageUnit,
        ageValue,
        math.floor(candidate.price),
        electionData.rank,
        electionData.guid
    )
    ns.SendAddonMessage(ns.PREFIX, payload, "GUILD")
end

local function CandidateAgeInSeconds(candidate)
    local secondsPerUnit = AGE_UNIT_SECONDS[candidate.ageUnit]
    if not secondsPerUnit or type(candidate.age) ~= "number" then return nil end
    return candidate.age * secondsPerUnit
end

local function IsBetterPriceCandidate(candidate, current)
    if not current then return true end

    if candidate.ageUnit == "d" and current.ageUnit == "d" then
        if candidate.age ~= current.age then
            return candidate.age < current.age
        end
    elseif candidate.ageUnit ~= "d" and current.ageUnit ~= "d" then
        local candidateAge = CandidateAgeInSeconds(candidate)
        local currentAge = CandidateAgeInSeconds(current)
        if candidateAge ~= nil and currentAge ~= nil and candidateAge ~= currentAge then
            return candidateAge < currentAge
        end
    end

    return ns.IsHigherPriorityCandidate(candidate, current)
end

local function PruneEarlyPriceCandidates(now)
    for index = #earlyPriceCandidates, 1, -1 do
        if now - earlyPriceCandidates[index].receivedAt > EARLY_PRICE_CANDIDATE_TTL_SECONDS then
            table.remove(earlyPriceCandidates, index)
        end
    end
end

local function CacheEarlyPriceCandidate(queryID, candidate)
    local now = GetTime()
    PruneEarlyPriceCandidates(now)

    for index, entry in ipairs(earlyPriceCandidates) do
        if entry.queryID == queryID and entry.candidate.name == candidate.name then
            earlyPriceCandidates[index] = {
                queryID = queryID,
                candidate = candidate,
                receivedAt = now,
            }
            return
        end
    end

    if #earlyPriceCandidates >= MAX_EARLY_PRICE_CANDIDATES then
        table.remove(earlyPriceCandidates, 1)
    end
    table.insert(earlyPriceCandidates, {
        queryID = queryID,
        candidate = candidate,
        receivedAt = now,
    })
end

local function MergeEarlyPriceCandidates(queryID, arbitration)
    PruneEarlyPriceCandidates(GetTime())
    for index = #earlyPriceCandidates, 1, -1 do
        local entry = earlyPriceCandidates[index]
        if entry.queryID == queryID then
            if IsBetterPriceCandidate(entry.candidate, arbitration.bestCandidate) then
                arbitration.bestCandidate = entry.candidate
            end
            table.remove(earlyPriceCandidates, index)
        end
    end
end

local function FormatAge(age, ageUnit)
    local suffix = AGE_UNIT_SUFFIXES[ageUnit]
    if type(age) ~= "number" or not suffix then return nil end
    return string.format("%d%s", math.floor(age + 0.5), suffix)
end

local function FormatPriceResponse(itemLink, price, disenchant, age, ageUnit)
    local response = string.format("Price for %s: %s", itemLink, ns.FormatMoney(price))
    if disenchant ~= nil then
        response = response .. string.format(" (Disenchanted: %s", ns.FormatMoney(disenchant))
        local formattedAge = FormatAge(age, ageUnit)
        if formattedAge then
            response = response .. string.format(" - Age: %s", formattedAge)
        end
        response = response .. ")"
    else
        local formattedAge = FormatAge(age, ageUnit)
        if formattedAge then
            response = response .. string.format(" (Age: %s)", formattedAge)
        end
    end
    return response
end

local function SendPriceReply(itemLink, response, request)
    MarkItemAnswered(itemLink)
    ns.SendChatMessage(response, "GUILD")
    ns.RecordUsage(request, response)
end

-- Builds and sends the reply for a single item query, unless another leader
-- has already answered it (see the dedupe/backoff comment above).
local function ReplyToItemQuery(itemLink, request, candidate, disenchant)
    if WasItemRecentlyAnswered(itemLink) then return end

    if ns.IsItemSoulbound(itemLink) then
        SendPriceReply(itemLink, string.format("No price available for %s. Soulbound item.", itemLink), request)
        return
    end

    if not candidate or not candidate.price then
        SendPriceReply(itemLink, string.format("No price available for %s. No market data", itemLink), request)
        return
    end

    SendPriceReply(itemLink, FormatPriceResponse(
        itemLink,
        candidate.price,
        disenchant,
        candidate.age,
        candidate.ageUnit
    ), request)
end

local function StartPriceArbitration(queryID, itemLink, request, localCandidate)
    if pendingPriceQueries[queryID] then return end

    local electionData = GetLocalElectionData()
    local arbitration = {
        itemLink = itemLink,
        request = request,
        disenchant = localCandidate.disenchant,
        bestCandidate = localCandidate.price
            and WithElectionData(localCandidate, electionData)
            or nil,
    }
    pendingPriceQueries[queryID] = arbitration
    MergeEarlyPriceCandidates(queryID, arbitration)

    C_Timer.After(PRICE_COLLECTION_WINDOW_SECONDS, function()
        if pendingPriceQueries[queryID] ~= arbitration then return end
        pendingPriceQueries[queryID] = nil

        local delay = RandomJitterSeconds(PRICE_REPLY_JITTER_MIN_SECONDS, PRICE_REPLY_JITTER_MAX_SECONDS)
        C_Timer.After(delay, function()
            ReplyToItemQuery(
                itemLink,
                request,
                arbitration.bestCandidate,
                arbitration.disenchant
            )
        end)
    end)
end

local function HandlePriceCandidate(message, channel, sender)
    if channel ~= "GUILD" then return end

    local protocolVersion, queryID, version, source, ageUnit, ageValue, priceValue, rankValue, guid =
        message:match("^PRICE:(%d+):([%da-f]+):([^:]+):([^:]+):([mhd?]):([^:]+):(%d+):(%d+):([^:]+)$")
    if protocolVersion ~= tostring(PRICE_PROTOCOL_VERSION)
        or not version:match("^%d+%.%d+%.%d+$")
        or (source ~= "Auctionator" and source ~= "TSM")
        or not sender
        or not guid:match("^[%w%-]+$") then
        return
    end

    local age
    if ageUnit == "?" then
        if ageValue ~= "?" then return end
    else
        age = tonumber(ageValue)
        if not AGE_UNIT_SECONDS[ageUnit] or not age or age < 0 or age > 1000000 then
            return
        end
    end

    local price, rank = tonumber(priceValue), tonumber(rankValue)
    if not price or price <= 0 or price >= math.huge or not rank or rank > 99 then
        return
    end

    local arbitration = pendingPriceQueries[queryID]
    local candidate = {
        name = sender,
        version = version,
        rank = rank,
        guid = guid,
        source = source,
        age = age,
        ageUnit = ageUnit,
        price = price,
    }
    if not arbitration then
        if ns.IsLeader() then
            CacheEarlyPriceCandidate(queryID, candidate)
        end
        return
    end

    if IsBetterPriceCandidate(candidate, arbitration.bestCandidate) then
        arbitration.bestCandidate = candidate
    end
end

-- True if this guild chat message is one of our (or another leader's) price
-- replies, in which case we mark its item(s) as answered instead of treating
-- it as a new query.
local function HandlePotentialReplyEcho(message)
    if not (message:find("^Price for ") or message:find("^No price available for ")) then
        return false
    end

    for itemLink in message:gmatch(ITEM_LINK_PATTERN) do
        MarkItemAnswered(itemLink)
    end
    return true
end

local function HandleGuildQuery(message, sender)
    if HandlePotentialReplyEcho(message) then return end
    if not message:find("^%?") then return end

    local isLeader = ns.IsLeader()

    local request = {
        timestamp = time(),
        channel = "Guild",
        user = sender or "Unknown",
        message = message,
    }

    for itemLink in message:gmatch(ITEM_LINK_PATTERN) do
        if not WasItemRecentlyAnswered(itemLink) then
            local queryID = BuildQueryID(message, sender, itemLink)
            local localCandidate = ResolvePrice(itemLink)

            if isLeader then
                StartPriceArbitration(queryID, itemLink, request, localCandidate)
            end

            SendPriceCandidate(queryID, localCandidate)
        end
    end
end

-- --- Main Event Handler ---

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_GUILD")
if not ns.AceComm then
    frame:RegisterEvent("CHAT_MSG_ADDON")
end
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

local hasShownLoadedMessage = false

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        local isInitialLogin = ...
        if isInitialLogin and not hasShownLoadedMessage then
            print("|cff00ff00GuildPriceCheck Loaded:|r Listening for ?[Item] in Guild Chat.")
            hasShownLoadedMessage = true
        end
        ns.SendPresence("PING")
    elseif event == "PLAYER_LOGOUT" then
        ns.SendPresence("LEAVE")
    elseif event == "PLAYER_REGEN_ENABLED" then
        ns.ThrottledSendPresence("PING")
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = ...
        ns.HandleAddonMessage(prefix, message, channel, sender)
    elseif event == "CHAT_MSG_GUILD" then
        local message, sender = ...
        HandleGuildQuery(message, sender)
    end
end)

function ns.HandleAddonMessage(prefix, message, channel, sender)
    sender = ns.NormalizeName(sender)
    local myName = ns.NormalizeName(UnitName("player"))
    if prefix ~= ns.PREFIX or sender == myName then return end

    if message:find("^PRICE:") then
        HandlePriceCandidate(message, channel, sender)
        return
    end

    local msgType, rank, guid, version = strsplit(":", message)
    version = version or "0.0.0"

    if msgType == "LEAVE" then
        ns.OnlineAddonUsers[sender] = nil
    elseif msgType == "PING" or msgType == "PONG" then
        ns.OnlineAddonUsers[sender] = {
            name = sender,
            rank = tonumber(rank) or 99,
            guid = guid,
            version = version,
        }

        if msgType == "PING" then
            local delay = RandomJitterSeconds(PONG_JITTER_MIN_SECONDS, PONG_JITTER_MAX_SECONDS)
            C_Timer.After(delay, function() ns.SendPresence("PONG") end)
        end
    end
end
