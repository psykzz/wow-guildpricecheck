local _, ns = ...

local function ShowStatus()
    local myName = ns.NormalizeName(UnitName("player"))
    local electedLeader = "Unknown"

    local candidates, myRank = ns.GetElectionCandidates()
    myRank = myRank or 99

    if candidates[1] then electedLeader = candidates[1].name end

    print("|cffffff00--- GPC Network Status ---|r")
    print(string.format("Current Leader: |cff00ff00%s|r", electedLeader))

    for name, data in pairs(ns.OnlineAddonUsers) do
        local isLeader = (name == electedLeader)
        local color = ns.GetStatusColor(false, isLeader)

        print(string.format("|c%s[%s]|r - Rank: %d, Version: %s (%s)",
            color, name, data.rank, data.version or "unknown", ns.IsPlayerActuallyOnline(name) and "online" or "offline"))
    end

    local myColor = ns.GetStatusColor(true, myName == electedLeader)
    print(string.format("|c%s[%s] (You)|r - Rank: %d, Version: %s",
        myColor, myName, myRank, ns.VERSION))
    print("|cffffff00--------------------------|r")
end

SLASH_GPC1 = "/gpc"
SlashCmdList["GPC"] = function(msg)
    local cmd = msg:lower():trim()
    if cmd == "status" then
        ShowStatus()
    elseif cmd == "ping" then
        print("Sending manual network ping...")
        if ns.SendPresence then ns.SendPresence("PING") end
    else
        print("GuildPriceCheck Usage:")
        print("  /gpc status - See online peers and elected leader")
        print("  /gpc ping   - Force a network refresh")
    end
end
