local addonName, ns = ...

C_ChatInfo.RegisterAddonMessagePrefix(ns.PREFIX)

ns.OnlineAddonUsers = {}     -- [name] = { rank = index, guid = string, lastSeen = time }

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
        ns.SendPresence("PING")
    elseif event == "PLAYER_LOGOUT" then
        ns.SendPresence("LEAVE")
    elseif event == "PLAYER_REGEN_ENABLED" then
        ns.ThrottledSendPresence("PING")
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = ...
        if prefix ~= ns.PREFIX or sender == UnitName("player") then return end

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
                C_Timer.After(math.random(1, 15) / 10, function() ns.SendPresence("PONG") end)
            end
        end
    elseif event == "CHAT_MSG_GUILD" then
        local message, sender = ...

        if not message:find("^%?") or not ns.IsLeader() then return  end

        for itemLink in message:gmatch("(|c.-|h.-|h|r)") do
            local price = nil

            if TSM_API then
                price = TSM_API.GetCustomPriceValue("DBMarket", TSM_API.ToItemString(itemLink))
            end

            if not price and Auctionator and Auctionator.API and Auctionator.API.v1 then
                price = Auctionator.API.v1.GetAuctionPriceByItemLink(addonName, itemLink)
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

            local response = string.format("Price for %s: %s", itemLink, ns.FormatMoney(price))
            ns.SendChatMessage(response, "GUILD")
        end
    end
end)

