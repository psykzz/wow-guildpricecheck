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

-- TSM's public API does not expose a per-item last-scan/age value, so we can't
-- truly compare freshness both ways. Auctionator's GetAuctionAgeByItemLink
-- returns whole days since the item was last seen on the AH (nil if never
-- seen or seen more than 21 days ago). Only prefer Auctionator over TSM when
-- its data is within this many days old; otherwise fall back to TSM since its
-- own freshness is unknown.
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

-- Resolves the best available price for an item, preferring Auctionator's
-- data when it's fresh (see ns.AUCTIONATOR_FRESHNESS_THRESHOLD_DAYS above)
-- and falling back to TSM, then to stale Auctionator data.
-- Returns price, disenchant price, and age in days (disenchant/age are only
-- populated when the chosen price came from Auctionator).
local function ResolvePrice(itemLink)
    local tsmPrice = nil
    if TSM_API then
        tsmPrice = TSM_API.GetCustomPriceValue("DBMinBuyout", TSM_API.ToItemString(itemLink))
    end

    local auctionatorPrice, auctionatorDisenchant, auctionatorAge = nil, nil, nil
    if Auctionator and Auctionator.API and Auctionator.API.v1 then
        auctionatorPrice = Auctionator.API.v1.GetAuctionPriceByItemLink(addonName, itemLink)
        auctionatorDisenchant = Auctionator.API.v1.GetDisenchantPriceByItemLink(addonName, itemLink)
        auctionatorAge = Auctionator.API.v1.GetAuctionAgeByItemLink(addonName, itemLink)
    end

    if auctionatorPrice and auctionatorAge and auctionatorAge <= ns.AUCTIONATOR_FRESHNESS_THRESHOLD_DAYS then
        return auctionatorPrice, auctionatorDisenchant, auctionatorAge
    elseif tsmPrice then
        return tsmPrice, nil, nil
    else
        return auctionatorPrice, auctionatorDisenchant, auctionatorAge
    end
end

local function FormatPriceResponse(itemLink, price, disenchant, age)
    local response = string.format("Price for %s: %s", itemLink, ns.FormatMoney(price))
    if age ~= nil then
        response = response .. string.format(" (Disenchanted: %s - Age: %s)", ns.FormatMoney(disenchant), age)
    end
    return response
end

local function SendPriceReply(itemLink, response)
    MarkItemAnswered(itemLink)
    ns.SendChatMessage(response, "GUILD")
end

-- Builds and sends the reply for a single item query, unless another leader
-- has already answered it (see the dedupe/backoff comment above).
local function ReplyToItemQuery(itemLink)
    if WasItemRecentlyAnswered(itemLink) then return end

    if ns.IsItemSoulbound(itemLink) then
        SendPriceReply(itemLink, string.format("No price available for %s. Soulbound item.", itemLink))
        return
    end

    local price, disenchant, age = ResolvePrice(itemLink)
    if not price then
        SendPriceReply(itemLink, string.format("No price available for %s. No market data", itemLink))
        return
    end

    SendPriceReply(itemLink, FormatPriceResponse(itemLink, price, disenchant, age))
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

local function HandleGuildQuery(message)
    if HandlePotentialReplyEcho(message) then return end
    if not message:find("^%?") or not ns.IsLeader() then return end

    for itemLink in message:gmatch(ITEM_LINK_PATTERN) do
        if not WasItemRecentlyAnswered(itemLink) then
            -- Small jitter gives a competing leader's reply (if any) a
            -- chance to arrive first and suppress this one, mirroring the
            -- PING/PONG jitter used for presence.
            local delay = RandomJitterSeconds(PRICE_REPLY_JITTER_MIN_SECONDS, PRICE_REPLY_JITTER_MAX_SECONDS)
            C_Timer.After(delay, function() ReplyToItemQuery(itemLink) end)
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

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        print("|cff00ff00GuildPriceCheck Loaded:|r Listening for ?[Item] in Guild Chat.")
        ns.SendPresence("PING")
    elseif event == "PLAYER_LOGOUT" then
        ns.SendPresence("LEAVE")
    elseif event == "PLAYER_REGEN_ENABLED" then
        ns.ThrottledSendPresence("PING")
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = ...
        ns.HandleAddonMessage(prefix, message, channel, sender)
    elseif event == "CHAT_MSG_GUILD" then
        local message = ...
        HandleGuildQuery(message)
    end
end)

function ns.HandleAddonMessage(prefix, message, channel, sender)
    sender = ns.NormalizeName(sender)
    local myName = ns.NormalizeName(UnitName("player"))
    if prefix ~= ns.PREFIX or sender == myName then return end

    local msgType, rank, guid, version = strsplit(":", message)
    version = version or "0.0.0"

    if msgType == "LEAVE" then
        ns.OnlineAddonUsers[sender] = nil
    else
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
