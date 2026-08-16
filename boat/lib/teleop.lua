-- Held-key teleop using Reassembly wrench + motor scheduler.
local util = require("util")
local motors = require("motors")
local wrench = require("wrench")
local calibrate = require("boat_calibrate")
local pose = require("pose")
local ui = require("ui")

local teleop = {}

local MOVE = {
    [keys.w] = "surge+",
    [keys.s] = "surge-",
    [keys.a] = "yaw-",
    [keys.d] = "yaw+",
    [keys.left] = "yaw-",
    [keys.right] = "yaw+",
    [keys.j] = "yaw-",
    [keys.l] = "yaw+",
    [keys.z] = "strafe-",
    [keys.c] = "strafe+",
}

local function loadThrusters()
    local control = calibrate.load()
    if not control or not control.thrusters then
        return nil, "run calibrate first"
    end
    return control.thrusters, control
end

local function commandFromHeld(held)
    local surge, strafe, yaw = 0, 0, 0
    if held[keys.w] then
        surge = surge + 1
    end
    if held[keys.s] then
        surge = surge - 1
    end
    if held[keys.z] then
        strafe = strafe - 1
    end
    if held[keys.c] then
        strafe = strafe + 1
    end
    if held[keys.a] or held[keys.left] or held[keys.j] then
        yaw = yaw - 1
    end
    if held[keys.d] or held[keys.right] or held[keys.l] then
        yaw = yaw + 1
    end
    return util.clamp(surge, -1, 1), util.clamp(strafe, -1, 1), util.clamp(yaw, -1, 1)
end

function teleop.apply(surge, strafe, yaw, thrusters)
    local duties = wrench.fromAxes(thrusters, surge, strafe, yaw)
    local byName = wrench.dutiesByName(thrusters, duties)
    local thrByName = {}
    for _, t in ipairs(thrusters) do
        thrByName[t.name] = t
        motors.register(t.name)
        motors.setDesired(t.name, 0)
    end
    motors.applyDuties(byName, thrByName)
    motors.flush(24)
    return byName
end

function teleop.run()
    local thrusters, err = loadThrusters()
    if not thrusters then
        print(err)
        return
    end
    motors.panic(3)
    ui.setMode("teleop")
    local held = {}
    print("Teleop: W/S A/D Z/C  X stop  Q quit")
    while true do
        local craft = pose.get()
        local surge, strafe, yaw = commandFromHeld(held)
        local duties = teleop.apply(surge, strafe, yaw, thrusters)
        ui.draw({
            x = craft and craft.x,
            y = craft and craft.y,
            z = craft and craft.z,
            yaw = craft and craft.yaw,
            speed = craft and select(1, pose.speed(craft)) or 0,
            thrust = surge,
            duties = duties,
        })
        local timer = os.startTimer(0.05)
        while true do
            local e, a, b = os.pullEvent()
            if e == "timer" and a == timer then
                break
            elseif e == "key" then
                local key, isRepeat = a, b
                if key == keys.q and not isRepeat then
                    motors.panic(3)
                    return
                elseif key == keys.x and not isRepeat then
                    held = {}
                    motors.panic(3)
                elseif MOVE[key] and not isRepeat then
                    held[key] = true
                end
            elseif e == "key_up" then
                local key = a
                if MOVE[key] then
                    held[key] = nil
                end
            end
        end
        motors.flush(8)
    end
end

return teleop
