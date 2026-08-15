-- Fire computer: wireless commands, bottom pulse fire, relay assemble
local PROTOCOL = "cannon"
local HOSTNAME = "fire"
local FIRE_SIDE = "bottom"
local AFTER_ASSEMBLE = 0.25 -- 5 ticks
local FIRE_PULSE = 0.25 -- 5 ticks held, then disassemble
local SIDES = { "top", "bottom", "left", "right", "front", "back" }

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

local function getRelay()
    return peripheral.find("redstone_relay")
end

local function setRelay(on)
    local relay = getRelay()
    if not relay then
        print("No redstone relay")
        return false
    end
    local value = on and 15 or 0
    for _, side in ipairs(SIDES) do
        relay.setAnalogOutput(side, value)
    end
    print(on and "Assemble ON" or "Assemble OFF")
    return true
end

local function fireShot()
    print("Assemble, wait 5, fire, wait 5, disassemble")
    if not setRelay(true) then
        return
    end
    sleep(AFTER_ASSEMBLE)
    print("Fire pulse " .. FIRE_SIDE)
    rs.setAnalogOutput(FIRE_SIDE, 15)
    sleep(FIRE_PULSE)
    rs.setAnalogOutput(FIRE_SIDE, 0)
    setRelay(false)
end

if not openWireless() then
    print("No wireless modem")
    return
end

rednet.host(PROTOCOL, HOSTNAME)
if getRelay() then
    print("Fire ready. Relay found. Fire via " .. FIRE_SIDE)
else
    print("Fire ready, but no relay yet. Right-click the wired modem on the relay.")
end

while true do
    local sender, message = rednet.receive(PROTOCOL)
    if sender and type(message) == "string" then
        if message == "disassemble" then
            setRelay(false)
        elseif message == "fire" then
            fireShot()
        elseif message == "reload" then
            -- turtles handle this
        else
            print("Unknown command: " .. message)
        end
    end
end
