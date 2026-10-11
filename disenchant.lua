local _, ns = ...

-- Probability data is adapted from Disenchantry's MIT-licensed
-- DisenchantResults.lua; see THIRD-PARTY-NOTICES.txt.
local uncommon = {
    {5,15,10940,10938,nil,80,20,20,80,1,2,1,2},
    {16,20,10940,10939,10978,75,20,20,75,2,3,1,2},
    {21,25,10940,10998,10978,75,15,15,75,4,6,1,2},
    {26,30,11083,11082,11084,75,20,20,75,1,2,1,2},
    {31,35,11083,11134,11138,75,20,20,75,2,5,1,2},
    {36,40,11137,11135,11139,75,20,20,75,1,2,1,2},
    {41,45,11137,11174,11177,75,20,20,75,2,5,1,2},
    {46,50,11176,11175,11178,75,20,20,75,1,2,1,2},
    {51,55,11176,16202,14343,75,20,22,75,2,5,1,2},
    {56,60,16204,16203,14344,75,20,22,75,1,2,1,2},
    {61,65,16204,16203,14344,75,20,22,75,2,5,2,3},
}

local outland = {
    {79,79,22445,22447,22448,75,22,22,75,1,2,1,2},
    {80,99,22445,22447,22448,75,22,22,75,2,3,2,3},
    {100,120,22445,22446,22449,75,22,22,75,2,5,1,2},
}

local northrend = {
    {130,151,34054,34056,34053,75,22,22,75,2,3,1,2},
    {152,200,34054,34055,34052,75,22,22,75,4,7,1,2},
}

local rareClassic = {
    {1,25,10978}, {26,30,11084}, {31,35,11138}, {36,40,11139},
    {41,45,11177}, {46,50,11178}, {51,55,14343}, {56,80,14344,20725},
}

local epicRows = {
    [0] = {
        {40,45,11177,2,4}, {46,50,11178,2,4}, {51,55,14343,2,4},
        {56,60,20725,1,1}, {61,88,20725,1,2},
    },
    [1] = {{90,100,22450,1,2}, {101,164,22450,1,2}},
    [2] = {{185,199,34057,1,2}, {200,284,34057,1,1}},
}

local function FindRow(rows, level)
    for _, row in ipairs(rows or {}) do
        if level >= row[1] and level <= row[2] then
            return row
        end
    end
end

local function GetExpansion(level, expansion, isForever)
    if isForever or (WOW_PROJECT_CLASSIC and WOW_PROJECT_ID == WOW_PROJECT_CLASSIC) then
        return 0
    end

    if type(expansion) ~= "number" or expansion == 254 or expansion < 0 then
        return level <= 65 and 0 or nil
    end

    return expansion
end

local function GetOutcomes(item, itemInfo)
    local level, quality, classID = itemInfo[4], itemInfo[3], itemInfo[12]
    if type(level) ~= "number" or level <= 0 then
        local getDetailedLevel = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo
        level = getDetailedLevel and getDetailedLevel(item)
    end
    if type(level) ~= "number" or level <= 0 then return nil end

    local itemClasses = Enum and Enum.ItemClass or {}
    local isWeapon = classID == (itemClasses.Weapon or 2)
    if not isWeapon and classID ~= (itemClasses.Armor or 4) then return nil end

    local buildVersion = GetBuildInfo and GetBuildInfo()
    local isForever = type(buildVersion) == "string" and buildVersion:match("^1%.60%.") ~= nil
    if not isForever and WOW_PROJECT_ID ~= nil and WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
        return nil
    end

    local expansion = GetExpansion(level, itemInfo[15], isForever)
    if expansion == nil then return nil end

    local itemQualities = Enum and Enum.ItemQuality or {}
    local uncommonQuality = itemQualities.Uncommon or 2
    local rareQuality = itemQualities.Rare or 3
    local epicQuality = itemQualities.Epic or 4

    if quality == uncommonQuality then
        local rows = expansion == 0 and uncommon or expansion == 1 and outland or expansion == 2 and northrend
        local row = FindRow(rows, level)
        if not row then return nil end

        local dustChance = row[isWeapon and 8 or 6]
        local essenceChance = row[isWeapon and 9 or 7]
        local essenceID = row[4]
        if isForever and isWeapon and level >= 21 and level <= 30 then
            essenceID = 10939
        end

        local outcomes = {
            {itemID = row[3], chance = dustChance, minQuantity = row[10], maxQuantity = row[11]},
            {itemID = essenceID, chance = essenceChance, minQuantity = row[12], maxQuantity = row[13]},
        }
        if row[5] then
            outcomes[#outcomes + 1] = {
                itemID = row[5],
                chance = 100 - dustChance - essenceChance,
            }
        end
        return outcomes
    elseif quality == rareQuality then
        local rows = expansion == 0 and rareClassic
            or expansion == 1 and {{66,99,22448,20725}, {100,115,22449,22450}}
            or expansion == 2 and {{130,166,34053}, {167,200,34052}}
        local row = FindRow(rows, level)
        if not row then return nil end
        if row[4] then
            return {
                {itemID = row[3], chance = 99.5},
                {itemID = row[4], chance = 0.5},
            }
        end
        return {{itemID = row[3], chance = 100}}
    elseif quality == epicQuality then
        local row = FindRow(epicRows[expansion], level)
        if row then
            return {{
                itemID = row[3],
                chance = 100,
                minQuantity = row[4],
                maxQuantity = row[5],
            }}
        end
    end
end

local function GetMaterialPrice(callerID, itemID)
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if not api then return nil end

    local ok, price
    if type(api.GetAuctionPriceByItemID) == "function" then
        ok, price = pcall(api.GetAuctionPriceByItemID, callerID, itemID)
    elseif type(api.GetAuctionPriceByItemLink) == "function" then
        ok, price = pcall(api.GetAuctionPriceByItemLink, callerID, "item:" .. itemID)
    else
        return nil
    end

    if not ok then error(price, 0) end
    if type(price) == "number" and price > 0 and price < math.huge then
        return price
    end
end

local function CalculateDisenchantValue(callerID, item)
    local getItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not getItemInfo then return nil end

    local itemInfo = {getItemInfo(item)}
    local outcomes = GetOutcomes(item, itemInfo)
    if not outcomes then return nil end

    local total = 0
    for _, outcome in ipairs(outcomes) do
        if outcome.chance > 0 then
            local price = GetMaterialPrice(callerID, outcome.itemID)
            if not price then return nil end
            local minQuantity = outcome.minQuantity or 1
            local maxQuantity = outcome.maxQuantity or minQuantity
            total = total + (outcome.chance / 100) * ((minQuantity + maxQuantity) / 2) * price
        end
    end

    if total > 0 then
        return math.floor(total)
    end
end

local api = Auctionator and Auctionator.API and Auctionator.API.v1
if api and not ns.AuctionatorDisenchantPatched then
    local function PatchPriceMethod(methodName)
        local original = api[methodName]
        if type(original) ~= "function" then return end

        api[methodName] = function(callerID, item)
            local price = original(callerID, item)
            if type(price) == "number" and price > 0 then
                return price
            end
            return CalculateDisenchantValue(callerID, item)
        end
    end

    PatchPriceMethod("GetDisenchantPriceByItemLink")
    PatchPriceMethod("GetDisenchantPriceByItemID")
    ns.AuctionatorDisenchantPatched = true
end
