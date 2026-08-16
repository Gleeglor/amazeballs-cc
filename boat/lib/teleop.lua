-- Held-key teleop as a session (non-blocking). Agent owns the event loop.
-- Sticky holds until key_up (or 1.0s safety timeout). Flush on axis change + tick.
local util = require("util")
local motors = require("motors")
local wrench = require("wrench")
local calibrate = require("boat_calibrate")
local pose = require("pose")
local ui = require("ui")

local teleop = {}

teleop.HOLD_TIMEOUT = 1.0
teleop.TICK = 0.05

local MOVE = {
    [keys.w] = true,
    [keys.s] = true,
    [keys.a] = true,
    [keys.d] = true,
    [keys.left] = true,
    [keys.right] = true,
    [keys.j] = true,
    [keys.l] = true,
    [keys.z] = true,
    [keys.c] = true,
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
    if not control or not control.thrusters or #control.thrusters == 0 then
        return nil, nil, "run calibrate first"
    end
    return control.thrusters, control, nil
end

function teleop.commandFromHeld(held, yawSign, surgeSign)
    yawSign = tonumber(yawSign) or 1
    surgeSign = tonumber(surgeSign) or -1 -- live: +duty was reverse of pose.forward
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
    surge = surge * surgeSign
    return util.clamp(surge, -1, 1), util.clamp(strafe, -1, 1), util.clamp(yaw, -1, 1)
end

local function maxAbsDuty(byName)
    local m = 0
    for _, d in pairs(byName) do
        local a = math.abs(tonumber(d) or 0)
        if a > m then
            m = a
        end
    end
    return m
end

--- If wrench deadbands everything to 0 while commanding motion, drive simply.
function teleop.fallbackDuties(thrusters, surge, strafe, yaw)
    local byName = {}
    local n = #thrusters
    if n == 0 then
        return byName
    end
    if math.abs(surge) > 0.1 then
        for _, t in ipairs(thrusters) do
            byName[t.name] = surge
        end
    elseif math.abs(yaw) > 0.1 then
        -- Split: first half of sorted names one way, rest the other (rough yaw)
        local names = {}
        for _, t in ipairs(thrusters) do
            names[#names + 1] = t.name
        end
        table.sort(names)
        local mid = math.ceil(#names / 2)
        for i, name in ipairs(names) do
            if i <= mid then
                byName[name] = yaw
            else
                byName[name] = -yaw
            end
        end
    elseif math.abs(strafe) > 0.1 then
        for _, t in ipairs(thrusters) do
            byName[t.name] = strafe * 0.5
        end
    end
    return byName
end

--- Set desired RPM from axes (no flush).
function teleop.setCommand(surge, strafe, yaw, thrusters)
    local thrByName = {}
    for _, t in ipairs(thrusters) do
        thrByName[t.name] = t
        motors.register(t.name)
    end
    if math.abs(surge) + math.abs(strafe) + math.abs(yaw) < 1e-6 then
        for name in pairs(thrByName) do
            motors.setDesired(name, 0)
        end
        return {}, "idle"
    end
    local duties = wrench.fromAxes(thrusters, surge, strafe, yaw)
    local byName = wrench.dutiesByName(thrusters, duties)
    local mode = "mix"
    if maxAbsDuty(byName) < 0.05 then
        byName = teleop.fallbackDuties(thrusters, surge, strafe, yaw)
        mode = "fallback"
    end
    motors.applyDuties(byName, thrByName)
    return byName, mode
end

function teleop.apply(surge, strafe, yaw, thrusters)
    local byName = teleop.setCommand(surge, strafe, yaw, thrusters)
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

local function sameAxes(a, b)
    return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

--- Start a teleop session. Returns session or nil, err.
function teleop.begin()
    local thrusters, control, err = loadThrusters()
    if not thrusters then
        return nil, err
    end
    local session = {
        thrusters = thrusters,
        yawSign = (control and control.yaw_sign) or 1,
        surgeSign = (control and control.surge_sign) or -1,
        held = {},
        seen = {},
        duties = {},
        lastAxes = { 0, 0, 0 },
        mixMode = "idle",
        tickId = nil,
        active = true,
    }
    motors.panicNow()
    motors.flush(64)
    ui.setMode("teleop")
    ui.setStatus("Teleop W/S A/D Z/C  X stop  Q quit")
    session.tickId = os.startTimer(teleop.TICK)
    teleop.sync(session, true)
    teleop.redraw(session)
    return session
end

function teleop.sync(session, forceFlush)
    if not session then
        return false
    end
    local surge, strafe, yaw = teleop.commandFromHeld(session.held, session.yawSign, session.surgeSign)
    local axes = { surge, strafe, yaw }
    if sameAxes(axes, session.lastAxes) then
        return false
    end
    session.lastAxes = axes
    local byName, mode = teleop.setCommand(surge, strafe, yaw, session.thrusters)
    session.duties = byName
    session.mixMode = mode or "mix"
    if forceFlush ~= false then
        motors.flush(24)
    end
    return true
end

function teleop.redraw(session)
    if not session then
        return
    end
    local craft = pose.get()
    local surge = select(1, teleop.commandFromHeld(session.held, session.yawSign, session.surgeSign))
    local actual = {}
    for _, t in ipairs(session.thrusters) do
        actual[t.name] = motors.readActualSpeed(t.name)
    end
    local errors = {}
    for _, t in ipairs(session.thrusters) do
        local err2 = motors.getLastError(t.name)
        if err2 then
            errors[t.name] = err2
        end
    end
    ui.setStatus(
        string.format(
            "teleop mix=%s held=%s",
            tostring(session.mixMode),
            heldLabels(session.held)
        )
    )
    ui.draw({
        x = craft and craft.x,
        y = craft and craft.y,
        z = craft and craft.z,
        yaw = craft and craft.yaw,
        speed = craft and select(1, pose.speed(craft)) or 0,
        thrust = surge,
        duties = session.duties,
        sent = motors.getSentMap(),
        desired = motors.getDesiredMap(),
        actual = actual,
        held = heldLabels(session.held),
        errors = errors,
    })
end

--- Handle one event. Returns "quit" to leave teleop, nil to continue.
function teleop.onEvent(session, e, a, b)
    if not session or not session.active then
        return "quit"
    end
    local t = util.now()
    if e == "key" then
        local key, isRepeat = a, b
        if key == keys.q and not isRepeat then
            return "quit"
        elseif key == keys.x and not isRepeat then
            session.held = {}
            session.seen = {}
            session.lastAxes = { 999, 999, 999 }
            motors.panicNow()
            motors.flush(64)
            session.duties = {}
            teleop.sync(session, true)
            teleop.redraw(session)
        elseif MOVE[key] then
            session.held[key] = true
            session.seen[key] = t
            if isRepeat then
                local surge, strafe, yaw = teleop.commandFromHeld(session.held, session.yawSign, session.surgeSign)
                if not sameAxes({ surge, strafe, yaw }, session.lastAxes) then
                    teleop.sync(session, true)
                end
            else
                teleop.sync(session, true)
            end
        end
    elseif e == "key_up" then
        if MOVE[a] then
            session.held[a] = nil
            session.seen[a] = nil
            teleop.sync(session, true)
        end
    elseif e == "timer" and a == session.tickId then
        if expireHolds(session.held, session.seen, t) then
            teleop.sync(session, true)
        end
        motors.flush(16)
        teleop.redraw(session)
        session.tickId = os.startTimer(teleop.TICK)
    end
    return nil
end

function teleop.stop(session)
    if session then
        session.active = false
    end
    motors.panicNow()
    motors.flush(64)
    ui.setMode("agent")
    ui.setStatus("")
end

--- Blocking wrapper (offline menu / no agent). Still processes key/timer only.
function teleop.run()
    local session, err = teleop.begin()
    if not session then
        print(err)
        return
    end
    print("Teleop: W/S A/D Z/C  X stop  Q quit")
    while true do
        local e, a, b = os.pullEvent()
        if teleop.onEvent(session, e, a, b) == "quit" then
            teleop.stop(session)
            return
        end
    end
end

return teleop
