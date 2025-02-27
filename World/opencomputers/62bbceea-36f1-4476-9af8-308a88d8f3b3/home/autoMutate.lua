local action = require('action')
local database = require('database')
local gps = require('gps')
local scanner = require('scanner')
local config = require('config')
local emptySlot

-- =================== MINOR FUNCTIONS ======================

local function findEmpty()
    local farm = database.getFarm()

    for slot = 1, config.workingFarmArea, 2 do
        local crop = farm[slot]
        if crop.name == 'air' or crop.name == 'emptyCrop' then
            emptySlot = slot
            return true
        end
    end
    return false
end

local function checkChild(slot, crop)
    if crop.isCrop and crop.name ~= 'emptyCrop' then

        if crop.name == 'air' then
            action.placeCropStick(2)
        elseif scanner.isWeed(crop, 'storage') then
            action.deweed()
            action.placeCropStick()
        elseif config.keepDuplicated or (not database.existInStorage(crop)) then
            action.transplant(gps.workingSlotToPos(slot), gps.storageSlotToPos(database.nextStorageSlot()))
            action.placeCropStick(2)
            database.addToStorage(crop)
        else
            action.deweed()
            action.placeCropStick()
        end
    end
end

local function checkParent(slot, crop)
    if crop.isCrop and crop.name ~= 'air' and crop.name ~= 'emptyCrop' then
        if scanner.isWeed(crop, 'working') then
            action.deweed()
            database.updateFarm(slot, {
                isCrop = true,
                name = 'emptyCrop'
            })
        end
    end
end

-- ====================== THE LOOP ======================

local function spreadOnce()
    for slot = 1, config.workingFarmArea, 1 do

        -- Terminal Condition
        if #database.getStorage() >= config.storageFarmArea then
            print('autoSpread: Storage Full!')
            return false
        end

        -- Scan
        gps.go(gps.workingSlotToPos(slot))
        local crop = scanner.scan()

        if slot % 2 == 0 then
            checkChild(slot, crop)
        else
            checkParent(slot, crop)
        end

        if action.needCharge() then
            action.charge()
        end
    end
    return true
end

-- ======================== MAIN ========================

local function init()
    database.resetStorage()
    database.scanFarm()
    action.restockAll()

    print(string.format('Rodando o programa de mutantes'))
end

local function main()
    init()

    -- Loop
    while spreadOnce() do
        action.restockAll()
    end

    -- Finish
    if config.cleanUp then
        action.cleanUp()
    end

    print('autoMutate finalizado!')
end

main()
