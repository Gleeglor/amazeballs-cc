-- Drive: Reassembly-style wrench allocation over calibrated thrusters.
local util = require("util")
local pose = require("pose")
local path = require("path")

local drive = {}
local CONTROL_PATH = "/boat_control.json"

local LEGACY_AXES = {
    "thrust_forward",
    "thrust_reverse",
    "strafe_left",
    "strafe_right",
    "steer_left",
    "steer_right",
}

function drive.loadControl()
    return util.readJSON(CONTROL_PATH)
end

function drive.saveControl(data)
    return util.writeJSON(CONTROL_PATH, data)
end

local function setRelay(name, on)
    if not name or not peripheral.isPresent(name) then
        return false
    end
    if string.sub(name, 1, 5) == "side:" then
        rs.setAnalogOutput(string.sub(name, 6), on and 15 or 0)
        return true
    end
    local r = peripheral.wrap(name)
    if not r then
        return false
    end
    local sides = { "top", "bottom", "left", "right", "front", "back" }
    local level = on and 15 or 0
    if r.setAnalogOutput then
        for _, side in ipairs(sides) do
            pcall(function()
                r.setAnalogOutput(side, level)
            end)
        end
        return true
    end
    if r.setOutput then
        for _, side in ipairs(sides) do
            pcall(function()
                r.setOutput(side, on)
            end)
        end
        return true
    end
    return false
end

function drive.isWrenchMode(control)
    control = control or drive.loadControl()
    return control
        and (control.mode == "wrench" or control.version == 2)
        and type(control.thrusters) == "table"
        and #control.thrusters > 0
end

function drive.allOff(control)
    control = control or drive.loadControl()
    if not control then
        return
    end
    if type(control.thrusters) == "table" then
        for _, t in ipairs(control.thrusters) do
            setRelay(t.name, false)
        end
    end
    if type(control.relays) == "table" then
        for _, axis in ipairs(LEGACY_AXES) do
            local list = control.relays[axis]
            if type(list) == "table" then
                for _, name in ipairs(list) do
                    setRelay(name, false)
                end
            end
        end
    end
end

function drive.setAxis(control, axis, on)
    if not control or type(control.relays) ~= "table" then
        return
    end
    local list = control.relays[axis]
    if type(list) ~= "table" then
        return
    end
    for _, name in ipairs(list) do
        setRelay(name, on and true or false)
    end
end

function drive.applySigned(control, posAxis, negAxis, cmd, deadband)
    deadband = deadband or 0.08
    if cmd > deadband then
        drive.setAxis(control, posAxis, true)
        drive.setAxis(control, negAxis, false)
    elseif cmd < -deadband then
        drive.setAxis(control, posAxis, false)
        drive.setAxis(control, negAxis, true)
    else
        drive.setAxis(control, posAxis, false)
        drive.setAxis(control, negAxis, false)
    end
end

local function dotW(weights, a, b)
    local wx = (weights and weights.fx) or 1
    local wy = (weights and weights.fy) or 1
    local wz = (weights and weights.tz) or 1
    return wx * a.fx * b.fx + wy * a.fy * b.fy + wz * a.tz * b.tz
end

local function wrenchLen2(weights, w)
    return dotW(weights, w, w)
end

--- Greedy allocate thrusters for desired wrench (Reassembly-like).
-- Activates a combination: e.g. two side props for pure strafe (torques cancel).
function drive.applyWrench(control, fx, fy, tz)
    control = control or drive.loadControl()
    if not drive.isWrenchMode(control) then
        return false
    end

    local desired = { fx = fx or 0, fy = fy or 0, tz = tz or 0 }
    local desMag = math.sqrt(desired.fx ^ 2 + desired.fy ^ 2 + desired.tz ^ 2)
    if desMag < 1e-4 then
        drive.allOff(control)
        return true
    end

    local weights = control.weights or { fx = 1, fy = 1, tz = 1.4 }
    local threshold = control.alloc_threshold or 0.12
    local rounds = control.alloc_rounds or math.min(8, #control.thrusters)
    local remaining = { fx = desired.fx, fy = desired.fy, tz = desired.tz }
    local chosen = {}
    local used = {}

    for _ = 1, rounds do
        local bestI, bestScore = nil, threshold
        for i, t in ipairs(control.thrusters) do
            if not used[i] then
                local score = dotW(weights, remaining, t)
                -- Prefer thrusters aligned with what we still need
                local tMag = t.mag or math.sqrt(t.fx * t.fx + t.fy * t.fy + t.tz * t.tz)
                if tMag > 1e-6 then
                    score = score / (0.35 + tMag)
                end
                if score > bestScore then
                    bestScore = score
                    bestI = i
                end
            end
        end
        if not bestI then
            break
        end
        used[bestI] = true
        chosen[bestI] = true
        local t = control.thrusters[bestI]
        local denom = wrenchLen2(weights, t)
        if denom > 1e-8 then
            local alpha = util.clamp(dotW(weights, remaining, t) / denom, 0, 1.5)
            remaining.fx = remaining.fx - alpha * t.fx
            remaining.fy = remaining.fy - alpha * t.fy
            remaining.tz = remaining.tz - alpha * t.tz
        end
    end

    for i, t in ipairs(control.thrusters) do
        setRelay(t.name, chosen[i] == true)
    end
    return true
end

local function simplePid(state, err, kp, ki, kd, dt, outMin, outMax)
    state.integral = (state.integral or 0) + err * dt
    local deriv = (err - (state.prev or 0)) / math.max(dt, 1e-3)
    state.prev = err
    local out = kp * err + ki * (state.integral or 0) + kd * deriv
    return util.clamp(out, outMin, outMax)
end

function drive.newPidStates()
    return { forward = {}, yaw = {}, right = {} }
end

function drive.stepToward(control, target, mode, pidStates, dt)
    control = control or drive.loadControl()
    pidStates = pidStates or drive.newPidStates()
    dt = dt or 0.1
    mode = mode or "cruise"

    local craft = pose.get()
    local err = pose.errorToTarget(target, craft)

    local gains = (control and control.gains) or {}
    local dock = (control and control.dock_assist) or {}
    local kp_f = gains.forward or 1.0
    local kp_y = gains.yaw or 1.0
    local kp_s = gains.strafe or 1.0

    local fwdCmd, yawCmd, strafeCmd = 0, 0, 0

    if mode == "dock" then
        fwdCmd = simplePid(pidStates.forward, err.forward, kp_f * 0.5, 0.02, 0.1, dt, -1, 1)
        yawCmd = simplePid(pidStates.yaw, err.yaw, kp_y * 0.8, 0.01, 0.05, dt, -1, 1)
        strafeCmd = simplePid(pidStates.right, err.right, kp_s * 0.5, 0.02, 0.1, dt, -1, 1)
        local scale = math.min(1, (dock.max_speed or 0.35) / 0.35)
        fwdCmd = fwdCmd * scale
        strafeCmd = strafeCmd * scale
    else
        fwdCmd = simplePid(pidStates.forward, err.forward, kp_f * 0.35, 0.01, 0.08, dt, -1, 1)
        local bearing = math.atan2(err.right, math.max(0.01, err.forward))
        if target.yaw ~= nil and err.distance < 4 then
            yawCmd = simplePid(pidStates.yaw, err.yaw, kp_y * 0.6, 0.01, 0.05, dt, -1, 1)
        else
            yawCmd = simplePid(pidStates.yaw, bearing, kp_y * 0.7, 0.01, 0.05, dt, -1, 1)
        end
        strafeCmd = 0
    end

    if drive.isWrenchMode(control) then
        drive.applyWrench(control, fwdCmd, strafeCmd, yawCmd)
    else
        drive.applySigned(control, "thrust_forward", "thrust_reverse", fwdCmd)
        drive.applySigned(control, "steer_left", "steer_right", yawCmd)
        if mode == "dock" then
            drive.applySigned(control, "strafe_right", "strafe_left", strafeCmd)
        else
            drive.setAxis(control, "strafe_left", false)
            drive.setAxis(control, "strafe_right", false)
        end
    end

    local tolPos = dock.tol_pos or 0.35
    local tolYaw = math.rad(dock.tol_yaw_deg or 5)
    local arrived
    if mode == "dock" then
        arrived = math.abs(err.forward) <= tolPos
            and math.abs(err.right) <= tolPos
            and err.distance <= tolPos * 1.5
            and math.abs(err.yaw) <= tolYaw
    else
        arrived = err.distance <= math.max(tolPos, 1.5)
    end

    return err, arrived
end

function drive.followPath(control, waypoints, opts)
    opts = opts or {}
    control = control or drive.loadControl()
    if not control then
        return false, "no boat_control.json (run calibrate)"
    end
    if not waypoints or #waypoints == 0 then
        return false, "empty path"
    end

    local dock = control.dock_assist or {}
    local engage = opts.engage_distance or dock.engage_distance or 12
    local holdTicks = opts.hold_ticks or 8
    local dt = opts.dt or 0.1
    local pidStates = drive.newPidStates()
    local i = path.nearestIndex(waypoints)
    local hold = 0

    while true do
        local craft = pose.get()
        local last = waypoints[#waypoints]
        local distLast = math.sqrt((last.x - craft.position.x) ^ 2 + (last.z - craft.position.z) ^ 2)
        local mode = "cruise"
        local target = waypoints[math.min(i, #waypoints)]
        if distLast <= engage or i >= #waypoints then
            mode = "dock"
            target = last
        end

        local err, arrived = drive.stepToward(control, target, mode, pidStates, dt)
        if mode == "cruise" then
            if err.distance < 2.5 then
                i = math.min(i + 1, #waypoints)
            end
            hold = 0
        else
            if arrived then
                hold = hold + 1
                if hold >= holdTicks then
                    drive.allOff(control)
                    return true, "arrived"
                end
            else
                hold = 0
            end
        end
        sleep(dt)
    end
end

function drive.manualLoop(control, opts)
    opts = opts or {}
    control = control or drive.loadControl()
    if not control then
        return nil, "no boat_control.json (run calibrate first)"
    end
    if not drive.isWrenchMode(control) and type(control.relays) ~= "table" then
        return nil, "no boat_control.json (run calibrate first)"
    end

    local quitKey = opts.quit_key or keys.q
    local interval = opts.interval or 0.25
    local recordName = opts.recordName
    local held = {}
    local waypoints = {}
    local t0 = os.clock()
    local lastSample = 0
    local stop = false
    local wrenchMode = drive.isWrenchMode(control)

    print("Manual control (hold keys):")
    print("  W/S  forward / reverse")
    print("  A/D  yaw left / right")
    print("  Z/C  strafe left / right")
    print("  X    all stop")
    print("  Q    quit" .. (recordName and (" + save path '" .. recordName .. "'") or ""))
    if wrenchMode then
        print("  Mode: Reassembly wrench (" .. #control.thrusters .. " thrusters)")
        print("  Strafe/turn = combination of props, not single labels")
    end
    print()

    local function refresh()
        local fx = (held[keys.w] and 1 or 0) + (held[keys.s] and -1 or 0)
        local fy = (held[keys.c] and 1 or 0) + (held[keys.z] and -1 or 0)
        local tz = (held[keys.a] and 1 or 0) + (held[keys.d] and -1 or 0)
        if wrenchMode then
            drive.applyWrench(control, fx, fy, tz)
        else
            drive.setAxis(control, "thrust_forward", fx > 0)
            drive.setAxis(control, "thrust_reverse", fx < 0)
            drive.setAxis(control, "steer_left", tz > 0)
            drive.setAxis(control, "steer_right", tz < 0)
            drive.setAxis(control, "strafe_left", fy < 0)
            drive.setAxis(control, "strafe_right", fy > 0)
        end
    end

    local function onKey(key, isHeld)
        if key == quitKey then
            stop = true
            return
        end
        if key == keys.x then
            held = {}
            drive.allOff(control)
            return
        end
        if key == keys.w or key == keys.s or key == keys.a or key == keys.d
            or key == keys.z or key == keys.c then
            held[key] = isHeld or nil
            if key == keys.w and isHeld then
                held[keys.s] = nil
            elseif key == keys.s and isHeld then
                held[keys.w] = nil
            elseif key == keys.a and isHeld then
                held[keys.d] = nil
            elseif key == keys.d and isHeld then
                held[keys.a] = nil
            elseif key == keys.z and isHeld then
                held[keys.c] = nil
            elseif key == keys.c and isHeld then
                held[keys.z] = nil
            end
            refresh()
        end
    end

    while not stop do
        local timerId = os.startTimer(recordName and interval or 0.1)
        while true do
            local ev = { os.pullEvent() }
            if ev[1] == "key" then
                onKey(ev[2], true)
                if stop then
                    break
                end
            elseif ev[1] == "key_up" then
                onKey(ev[2], false)
            elseif ev[1] == "timer" and ev[2] == timerId then
                break
            end
        end
        if stop then
            break
        end
        if recordName then
            local now = os.clock()
            if now - lastSample >= interval * 0.9 then
                lastSample = now
                local ok, wp = pcall(path.sampleWaypoint, t0)
                if ok and wp then
                    waypoints[#waypoints + 1] = wp
                    if #waypoints % 20 == 0 then
                        print("  recorded #" .. #waypoints)
                    end
                end
            end
        end
    end

    drive.allOff(control)

    if recordName then
        if #waypoints < 2 then
            return waypoints, "too few waypoints"
        end
        local last = waypoints[#waypoints]
        local ok, err = path.save(recordName, waypoints, {
            samples = #waypoints,
            duration = os.clock() - t0,
            end_pose = { x = last.x, y = last.y, z = last.z, yaw = last.yaw },
            recorded_with = "manual",
        })
        if not ok then
            return waypoints, tostring(err)
        end
        return waypoints, "saved"
    end
    return nil, "ok"
end

return drive
