-- Held-key teleop: apply on key / key_up immediately (not after a listen window).
local util = require("util")
local motors = require("motors")
local wrench = require("wrench")
local calibrate = require("boat_calibrate")
local pose = require("pose")
local ui = require("ui")

local teleop = {}

teleop.HOLD_TIMEOUT = 0.22 -- lost key_up → release
teleop.TICK = 0.05

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

local KEY_LABEL = {
    [keys.w] = "W",
    [keys.s] = "S",
    [keys.a] = "A",
    [keys.d] = "D",
    [keys.left] = "←",
    [keys.right] = "→",
    [keys.j] = "J",
    [keys.l] = "L",
    [keys.z] = "Z",
    [keys.c] = "C",
}

local function loadThrusters()
    local control = calibrate.load()
    if not control or not control.thrusters then
        return nil, nil, "run calibrate first"
    end
    return control.thrusters, control, nil
end

function teleop.commandFromHeld(held, yawSign)
    yawSign = tonumber(yawSign) or -1 -- default: fix A inverted vs hull
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
    yaw = yaw * yawSign
    return util.clamp(surge, -1, 1), util.clamp(strafe, -1, 1), util.clamp(yaw, -1, 1)
end

function teleop.apply(surge, strafe, yaw, thrusters)
    local thrByName = {}
    for _, t in ipairs(thrusters) do
        thrByName[t.name] = t
        motors.register(t.name)
    end
    local duties = wrench.fromAxes(thrusters, surge, strafe, yaw)
    local byName = wrench.dutiesByName(thrusters, duties)
    -- Idle: zero every thruster; else only set from map (applyDuties zeros missing names)
    if math.abs(surge) + math.abs(strafe) + math.abs(yaw) < 1e-6 then
        for name in pairs(thrByName) do
            motors.setDesired(name, 0)
        end
    else
        motors.applyDuties(byName, thrByName)
    end
    motors.flush(24)
    return byName
end

local function heldLabels(held)
    local parts = {}
    for k, on in pairs(held) do
        if on and KEY_LABEL[k] then
            parts[#parts + 1] = KEY_LABEL[k]
        end
    end
    table.sort(parts)
    return table.concat(parts, "")
end

local function expireHolds(held, seen, t)
    local changed = false
    for k, on in pairs(held) do
        if on then
            local last = seen[k] or 0
            if (t - last) > teleop.HOLD_TIMEOUT then
                held[k] = nil
                seen[k] = nil
                changed = true
            end
        end
    end
    return changed
end

function teleop.run()
    local thrusters, control, err = loadThrusters()
    if not thrusters then
        print(err)
        return
    end
    local yawSign = (control and control.yaw_sign) or -1
    motors.panicNow()
    motors.flush(64)
    ui.setMode("teleop")
    local held = {}
    local seen = {}
    local duties = {}
    print("Teleop: W/S A/D Z/C  X stop  Q quit")

    local function redraw()
        local craft = pose.get()
        local surge = select(1, teleop.commandFromHeld(held, yawSign))
        local actual = {}
        for _, t in ipairs(thrusters) do
            actual[t.name] = motors.readActualSpeed(t.name)
        end
        ui.draw({
            x = craft and craft.x,
            y = craft and craft.y,
            z = craft and craft.z,
            yaw = craft and craft.yaw,
            speed = craft and select(1, pose.speed(craft)) or 0,
            thrust = surge,
            duties = duties,
            sent = motors.getSentMap(),
            desired = motors.getDesiredMap(),
            actual = actual,
            held = heldLabels(held),
            errors = (function()
                local e = {}
                for _, t in ipairs(thrusters) do
                    local err2 = motors.getLastError(t.name)
                    if err2 then
                        e[t.name] = err2
                    end
                end
                return e
            end)(),
        })
    end

    local function doApply()
        local surge, strafe, yaw = teleop.commandFromHeld(held, yawSign)
        duties = teleop.apply(surge, strafe, yaw, thrusters)
        redraw()
    end

    local tick = os.startTimer(teleop.TICK)
    doApply()

    while true do
        local e, a, b = os.pullEvent()
        local t = util.now()
        if e == "key" then
            local key, isRepeat = a, b
            if key == keys.q and not isRepeat then
                motors.panicNow()
                motors.flush(64)
                return
            elseif key == keys.x and not isRepeat then
                held = {}
                seen = {}
                motors.panicNow()
                motors.flush(64)
                duties = {}
                doApply()
            elseif MOVE[key] then
                held[key] = true
                seen[key] = t
                doApply()
            end
        elseif e == "key_up" then
            local key = a
            if MOVE[key] then
                held[key] = nil
                seen[key] = nil
                doApply()
            end
        elseif e == "timer" and a == tick then
            local expired = expireHolds(held, seen, t)
            if expired then
                doApply()
            else
                motors.flush(16)
                redraw()
            end
            tick = os.startTimer(teleop.TICK)
        end
    end
end

return teleop
