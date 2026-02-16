local addonName, ns = ...

local function ShowStatus()
    local myName = UnitName("player")
    local electedLeader = "Unknown"

    -- Determine who the leader is for the status printout
    -- (Uses the same logic as your IsLeader function)
    local candidates = {}
    local _, _, myRank = GetGuildInfo("player")
    table.insert(candidates, { name = myName, rank = myRank or 99, guid = UnitGUID("player") })

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

    if candidates[1] then electedLeader = candidates[1].name end

    print("|cffffff00--- GPC Network Status ---|r")
    print(string.format("Current Leader: |cff00ff00%s|r", electedLeader))

    -- Print list of all peers
    for name, data in pairs(ns.OnlineAddonUsers) do
        local isLeader = (name == electedLeader)
        local color = ns.GetStatusColor(false, isLeader)

        print(string.format("|c%s[%s]|r - Rank Index: %d (%s)",
            color, name, data.rank, ns.IsPlayerActuallyOnline(name) and "online" or "offline"))
    end

    -- Show self
    local myColor = ns.GetStatusColor(true, myName == electedLeader)
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
        if ns.SendPresence then ns.SendPresence("PING") end
    else
        print("GuildPriceCheck Usage:")
        print("  /gpc status - See online peers and elected leader")
        print("  /gpc ping   - Force a network refresh")
    end
end
