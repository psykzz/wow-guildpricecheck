local addonName, ns = ...

ns.VERSION = GetAddOnMetadata(addonName, "Version"):match("^([0-9.]+)") or "0.0.0"

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
        local message, sender = ...

        if not message:find("^%?") or not ns.IsLeader() then return  end

        for itemLink in message:gmatch("(|c.-|h.-|h|r)") do
            local price = nil
            local disenchant = nil
            local age = nil

            if TSM_API then
                price = TSM_API.GetCustomPriceValue("DBMinBuyout", TSM_API.ToItemString(itemLink))
            end

            if not price and Auctionator and Auctionator.API and Auctionator.API.v1 then
                price = Auctionator.API.v1.GetAuctionPriceByItemLink(addonName, itemLink)
                disenchant = Auctionator.API.v1.GetDisenchantPriceByItemLink(addonName, itemLink)
                age = Auctionator.API.v1.GetAuctionAgeByItemLink(addonName, itemLink)
            end

            if ns.IsItemSoulbound(itemLink) then
                local response = string.format("No price available for %s. Soulbound item.", itemLink)
                ns.SendChatMessage(response, "GUILD")
                return
            end

            if not price then
                local response = string.format("No price available for %s. No market data", itemLink)
                ns.SendChatMessage(response, "GUILD")
                return
            end
            local extra = string.format(" (Disenchanted: %s | Age: %s)", ns.FormatMoney(disenchant), age)
            local response = string.format("Price for %s: %s", itemLink, ns.FormatMoney(price))
            if age ~= nil then
                   response = response .. extra 
            end
            ns.SendChatMessage(response, "GUILD")
        end
    end
end)

function ns.HandleAddonMessage(prefix, message, channel, sender)
    if prefix ~= ns.PREFIX or sender == UnitName("player") then return end

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
            C_Timer.After(math.random(1, 15) / 10, function() ns.SendPresence("PONG") end)
        end
    end
end

