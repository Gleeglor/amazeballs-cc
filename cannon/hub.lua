-- Hub: type reload / fire / cycle. Broadcasts to every fire computer.
local PROTOCOL = "cannon"
local PULSE_SIDE = "front"
local PULSE_TIME = 0.4
-- Sequenced gearshift: 360 open, wait 2s, 360 close. Time for 360 at this RPM.
local GEARSHIFT_RPM = 64
local GEARSHIFT_DELAY = 2.0
local FIRE_EARLY = 1.5 -- 30 ticks; turtle reload is already finished
local CYCLE_WAIT = (60 / GEARSHIFT_RPM) * 2 + GEARSHIFT_DELAY + 0.25 - FIRE_EARLY

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

local function send(cmd)
    rednet.broadcast(cmd, PROTOCOL)
    print("Broadcast " .. cmd)
    return true
end

local function pulseTurtle()
    print("Pulsing " .. PULSE_SIDE)
    rs.setOutput(PULSE_SIDE, true)
    sleep(PULSE_TIME)
    rs.setOutput(PULSE_SIDE, false)
end

local function doReload()
    print("Reload")
    pulseTurtle()
    send("disassemble")
    send("reload")
end

local function doFire()
    print("Fire")
    send("fire")
end

if not openWireless() then
    print("No wireless modem")
    return
end

rednet.host(PROTOCOL, "hub")
print("Hub ready. Commands: reload  fire  cycle")

while true do
    write("> ")
    local line = read()
    if not line then
        break
    end
    line = string.lower(string.match(line, "^%s*(.-)%s*$") or "")
    if line ~= "" then
        if line == "reload" then
            doReload()
        elseif line == "fire" then
            doFire()
        elseif line == "cycle" then
            doReload()
            print("Waiting " .. CYCLE_WAIT .. "s for breech")
            sleep(CYCLE_WAIT)
            doFire()
        else
            print("Unknown. Use reload, fire, or cycle")
        end
    end
end
