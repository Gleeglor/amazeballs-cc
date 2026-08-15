-- Cannon reload: rednet "reload" or left redstone -> payload, ram, powder, ram
local PROTOCOL = "cannon"
local BREECH_OPEN_WAIT = 0.5 -- 10 ticks
local PAYLOAD_RAMS = 1 -- just enough to free the breech for powder
local POWDER_RAMS = 2 -- push the stack together past the breech

local function findSlot(matches)
    for slot = 1, 16 do
        local item = turtle.getItemDetail(slot)
        if item and matches(item.name) then
            return slot
        end
    end
    return nil
end

local function isPowder(name)
    return string.find(name, "powder_charge", 1, true) ~= nil
end

local function isRamRod(name)
    return string.find(name, "ram_rod", 1, true) ~= nil
end

local function isWorm(name)
    return string.find(name, "worm", 1, true) ~= nil
end

local function isPayload(name)
    if isPowder(name) or isRamRod(name) or isWorm(name) then
        return false
    end
    return string.find(name, "shell", 1, true)
        or string.find(name, "shot", 1, true)
        or string.find(name, "grapeshot", 1, true)
end

local function reload()
    print("Reloading...")
    sleep(BREECH_OPEN_WAIT)

    local payload = findSlot(isPayload)
    local powder = findSlot(isPowder)
    local ramSlot = findSlot(isRamRod)
    if not payload then
        print("No payload")
        return
    end
    if not ramSlot then
        print("No ram rod")
        return
    end
    if not powder then
        print("No powder charge")
        return
    end

    turtle.select(payload)
    if not turtle.place() then
        print("Failed to place payload")
        return
    end

    turtle.select(ramSlot)
    for _ = 1, PAYLOAD_RAMS do
        turtle.place()
    end

    turtle.select(powder)
    if not turtle.place() then
        print("Failed to place powder")
        return
    end

    turtle.select(ramSlot)
    for _ = 1, POWDER_RAMS do
        turtle.place()
    end

    print("Reload done")
end

local function openWireless()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            local modem = peripheral.wrap(name)
            if modem.isWireless() then
                rednet.open(name)
                return name
            end
        end
    end
    return nil
end

local function waitRedstone()
    while true do
        os.pullEvent("redstone")
        if rs.getInput("left") then
            reload()
            while rs.getInput("left") do
                os.pullEvent("redstone")
            end
        end
    end
end

local function waitRednet()
    while true do
        local _, message = rednet.receive(PROTOCOL)
        if message == "reload" then
            reload()
        end
    end
end

if openWireless() then
    print("Waiting for reload (wireless or left)")
    parallel.waitForAny(waitRedstone, waitRednet)
else
    print("No wireless. Waiting for left signal")
    waitRedstone()
end
