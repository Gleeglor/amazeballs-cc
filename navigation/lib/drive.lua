-- Drive: Reassembly-style wrench allocation with analog (1-15) + live trim.
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

--- True if RS is inverted: logical thrust 15 (full) → physical 0, off → 15.
function drive.isInvert(control)
    control = control or drive.loadControl()
    return control and control.invert_analog == true
end

--- Map logical thrust level (0=off .. 15=full) to physical redstone on the wire.
function drive.logicalToPhysical(logicalLevel, invert)
    local level = math.floor(util.clamp(tonumber(logicalLevel) or 0, 0, 15) + 0.5)
    if invert then
        return 15 - level
    end
    return level
end

--- Write raw physical redstone 0-15 to a relay (no invert).
function drive.setRelayPhysical(name, level)
    if not name then
        return false
    end
    level = math.floor(util.clamp(tonumber(level) or 0, 0, 15) + 0.5)
    if string.sub(name, 1, 5) == "side:" then
        rs.setAnalogOutput(string.sub(name, 6), level)
        return true
    end
    if not peripheral.isPresent(name) then
        return false
    end
    local r = peripheral.wrap(name)
    if not r then
        return false
    end
    local sides = { "top", "bottom", "left", "right", "front", "back" }
    if r.setAnalogOutput then
        for _, side in ipairs(sides) do
            pcall(function()
                r.setAnalogOutput(side, level)
            end)
        end
        return true
    end
    if r.setOutput then
        -- Digital-only relay: treat any physical >0 as on (invert-aware callers pass physical)
        local on = level > 0
        for _, side in ipairs(sides) do
            pcall(function()
                r.setOutput(side, on)
            end)
        end
        return true
    end
    return false
end

--- Set thruster by logical strength 0=off .. 15=full (honors invert_analog).
-- For thruster tables prefer drive.setActuator.
local motorRpmCache = {}
local motorRpmLastSet = {}
local motorWrapCache = {}
local actuatorDutyCache = {}

local function getMotor(name)
    local m = motorWrapCache[name]
    if m then
        return m
    end
    if not peripheral.isPresent(name) then
        return nil
    end
    m = peripheral.wrap(name)
    if not m or (not m.setRPM and not m.setSpeed and not m.stop) then
        return nil
    end
    motorWrapCache[name] = m
    return m
end

function drive.setThrustLevel(control, name, logicalLevel)
    local invert = drive.isInvert(control)
    -- Prefer motor API when this peripheral is a motor (cached wrap)
    if getMotor(name) then
        local maxRpm = (control and control.default_motor_rpm) or 256
        local u = util.clamp((tonumber(logicalLevel) or 0) / 15, 0, 1)
        return drive.setMotorRpm(name, u * maxRpm)
    end
    return drive.setRelayPhysical(name, drive.logicalToPhysical(logicalLevel, invert))
end

function drive.setMotorRpm(name, rpm)
    if not name then
        return false
    end
    local m = getMotor(name)
    if not m then
        return false
    end
    rpm = math.floor((tonumber(rpm) or 0) + 0.5)
    local now = os.clock()
    local lastT = motorRpmLastSet[name] or 0
    local lastR = motorRpmCache[name]
    -- Skip identical command
    if lastR ~= nil and lastR == rpm then
        return true
    end
    -- CCA anti-spam: allow large changes ASAP, small tweaks need a short gap
    local dt = now - lastT
    local delta = lastR and math.abs(lastR - rpm) or 999
    if dt < 0.04 and delta < 8 then
        return true
    end
    local ok, err = pcall(function()
        if math.abs(rpm) < 1 and m.stop then
            m.stop()
        elseif m.setRPM then
            m.setRPM(rpm)
        elseif m.setSpeed then
            m.setSpeed(rpm)
        else
            error("no setRPM")
        end
    end)
    if ok then
        motorRpmCache[name] = rpm
        motorRpmLastSet[name] = now
    else
        motorRpmLastSet[name] = now
        -- Drop bad wrap so next call re-wraps (modem reconnect)
        if err and not string.find(tostring(err), "Anti Spam") then
            motorWrapCache[name] = nil
        end
    end
    return ok
end

function drive.stopAllMotors()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "electric_motor") then
            drive.setMotorRpm(name, 0)
            local m = getMotor(name)
            if m and m.stop then
                pcall(m.stop)
            end
            motorRpmCache[name] = 0
            actuatorDutyCache[name] = 0
        end
    end
end

--- duty in [-1,1] for motors (signed RPM), [0,1] for relays.
function drive.setActuator(control, thruster, duty)
    if type(thruster) == "string" then
        thruster = { name = thruster, kind = "relay" }
    end
    local name = thruster.name
    local kind = thruster.kind
    if not kind then
        if getMotor(name) then
            kind = "motor"
        else
            kind = "relay"
        end
    end

    if kind == "motor" then
        local maxRpm = thruster.max_rpm or (control and control.default_motor_rpm) or 256
        duty = util.clamp(tonumber(duty) or 0, -1, 1)
        if math.abs(duty) < 0.03 then
            duty = 0
        end
        local prev = actuatorDutyCache[name]
        if prev ~= nil and math.abs(prev - duty) < 0.02 then
            return true
        end
        local ok = drive.setMotorRpm(name, duty * maxRpm)
        if ok then
            actuatorDutyCache[name] = duty
        end
        return ok
    end

    duty = util.clamp(tonumber(duty) or 0, 0, 1)
    local level = 0
    if duty >= 0.04 then
        level = math.max(1, math.floor(duty * 15 + 0.5))
    end
    local prev = actuatorDutyCache[name]
    if prev ~= nil and math.abs(prev - duty) < 0.02 then
        return true
    end
    local ok = drive.setThrustLevel(control, name, level)
    if ok then
        actuatorDutyCache[name] = duty
    end
    return ok
end

--- Back-compat name: treats boolean/"level" as logical (full or off) unless number given.
function drive.setRelayLevel(name, levelOrOn, control)
    control = control or drive.loadControl()
    local logical
    if type(levelOrOn) == "boolean" then
        logical = levelOrOn and 15 or 0
    else
        logical = levelOrOn
    end
    return drive.setThrustLevel(control, name, logical)
end

function drive.isWrenchMode(control)
    control = control or drive.loadControl()
    return control
        and (control.mode == "wrench" or (control.version or 0) >= 2)
        and type(control.thrusters) == "table"
        and #control.thrusters > 0
end

function drive.allOff(control, opts)
    control = control or drive.loadControl()
    opts = opts or {}
    if type(control) == "table" and type(control.thrusters) == "table" then
        for _, t in ipairs(control.thrusters) do
            drive.setActuator(control, t, 0)
        end
    end
    if type(control) == "table" and type(control.relays) == "table" then
        for _, axis in ipairs(LEGACY_AXES) do
            local list = control.relays[axis]
            if type(list) == "table" then
                for _, name in ipairs(list) do
                    drive.setThrustLevel(control, name, 0)
                end
            end
        end
    end
    -- Full network scan only when explicitly requested (boot / stop / calibrate)
    if opts.scan_all then
        drive.stopAllMotors()
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
        drive.setThrustLevel(control, name, on and 15 or 0)
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

local function dutyToLevel(u)
    u = util.clamp(u or 0, 0, 1)
    if u < 0.04 then
        return 0
    end
    return math.max(1, math.floor(u * 15 + 0.5))
end

--- Continuous greedy allocation. Motors get signed RPM; relays get 0-15.
function drive.applyWrench(control, fx, fy, tz)
    control = control or drive.loadControl()
    if not drive.isWrenchMode(control) then
        return false
    end

    local desired = { fx = fx or 0, fy = fy or 0, tz = tz or 0 }
    local desMag = math.sqrt(desired.fx ^ 2 + desired.fy ^ 2 + desired.tz ^ 2)
    if desMag < 1e-4 then
        -- Zero known thrusters only — avoid peripheral.getNames scan every idle tick
        for _, t in ipairs(control.thrusters) do
            drive.setActuator(control, t, 0)
        end
        return true
    end

    local norm = (control.gains and control.gains.norm) or 1
    if norm < 1e-6 then
        norm = 1
    end
    local scale = desMag * norm
    desired.fx = (desired.fx / desMag) * scale
    desired.fy = (desired.fy / desMag) * scale
    desired.tz = (desired.tz / desMag) * scale

    local weights = control.weights or { fx = 1, fy = 1, tz = 1.6 }
    local threshold = control.alloc_threshold or 0.08
    local rounds = control.alloc_rounds or math.min(12, #control.thrusters * 2)
    local remaining = { fx = desired.fx, fy = desired.fy, tz = desired.tz }
    local u = {}
    for i = 1, #control.thrusters do
        u[i] = 0
    end

    for _ = 1, rounds do
        local bestI, bestScore = nil, threshold
        for i, t in ipairs(control.thrusters) do
            local reversible = (t.kind == "motor")
            local room = reversible and (1 - math.abs(u[i])) or (1 - u[i])
            if room > 0.02 then
                local score = dotW(weights, remaining, t)
                local tMag = t.mag or math.sqrt(t.fx * t.fx + t.fy * t.fy + t.tz * t.tz)
                if tMag > 1e-6 then
                    score = score / (0.25 + tMag)
                end
                -- Motors may run reverse (negative score); relays only forward duty
                if reversible then
                    if math.abs(score) > bestScore then
                        bestScore = math.abs(score)
                        bestI = i
                    end
                elseif score > bestScore then
                    bestScore = score
                    bestI = i
                end
            end
        end
        if not bestI then
            break
        end
        local t = control.thrusters[bestI]
        local denom = wrenchLen2(weights, t)
        if denom <= 1e-8 then
            break
        end
        local alpha = dotW(weights, remaining, t) / denom
        local reversible = (t.kind == "motor")
        if reversible then
            local maxStep = 1 - math.abs(u[bestI])
            alpha = util.clamp(alpha, -maxStep, maxStep)
        else
            alpha = util.clamp(alpha, 0, 1 - u[bestI])
        end
        if math.abs(alpha) < 0.02 then
            break
        end
        u[bestI] = u[bestI] + alpha
        remaining.fx = remaining.fx - alpha * t.fx
        remaining.fy = remaining.fy - alpha * t.fy
        remaining.tz = remaining.tz - alpha * t.tz
    end

    for i, t in ipairs(control.thrusters) do
        if t.kind == "motor" then
            drive.setActuator(control, t, u[i])
        else
            drive.setActuator(control, t, math.max(0, u[i]))
        end
    end
    return true
end

--- Live trim: cancel unwanted yaw/strafe rate when command doesn't ask for them.
-- command = {fx,fy,tz} in -1..1 from keys/PID; returns trimmed wrench command.
function drive.trimCommand(control, command, trimState, dt)
    command = command or { fx = 0, fy = 0, tz = 0 }
    trimState = trimState or {}
    dt = dt or 0.1
    control = control or drive.loadControl()

    local fb = (control and control.feedback) or {}
    local kpYaw = fb.kp_yaw or 1.2
    local kpLat = fb.kp_lat or 0.8
    local maxTrim = fb.max_trim or 1.0

    local ok, craft = pcall(pose.get)
    if not ok then
        return command, trimState
    end
    local vel = pose.getVelocity()
    local ang = pose.getAngularVelocity()
    local localV = pose.worldToLocal(vel, craft)
    local yawRate = ang.x * craft.up.x + ang.y * craft.up.y + ang.z * craft.up.z

    local fx = command.fx or 0
    local fy = command.fy or 0
    local tz = command.tz or 0

    -- If pilot/autopilot isn't commanding yaw, kill measured yaw rate
    if math.abs(tz) < 0.08 then
        local corr = -kpYaw * yawRate
        tz = util.clamp(corr, -maxTrim, maxTrim)
    end
    -- If not commanding strafe, kill sideways velocity
    if math.abs(fy) < 0.08 then
        local corr = -kpLat * localV.right
        fy = util.clamp(corr, -maxTrim, maxTrim)
    end

    trimState.yaw_rate = yawRate
    trimState.lat_vel = localV.right
    return { fx = fx, fy = fy, tz = tz }, trimState
end

local function simplePid(state, err, kp, ki, kd, dt, outMin, outMax)
    state.integral = (state.integral or 0) + err * dt
    local deriv = (err - (state.prev or 0)) / math.max(dt, 1e-3)
    state.prev = err
    local out = kp * err + ki * (state.integral or 0) + kd * deriv
    return util.clamp(out, outMin, outMax)
end

function drive.newPidStates()
    return { forward = {}, yaw = {}, right = {}, trim = {} }
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
        local cmd = { fx = fwdCmd, fy = strafeCmd, tz = yawCmd }
        -- Cruise: allow live cancel of unwanted yaw from off-center thrust
        if mode == "cruise" then
            cmd, pidStates.trim = drive.trimCommand(control, cmd, pidStates.trim, dt)
            -- Keep path yaw command if we were actively steering toward bearing
            if math.abs(yawCmd) >= 0.08 then
                cmd.tz = yawCmd
            end
        end
        drive.applyWrench(control, cmd.fx, cmd.fy, cmd.tz)
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

    -- Defaults for trim (persist into config memory only; optional write)
    if drive.isWrenchMode(control) and not control.feedback then
        control.feedback = { kp_yaw = 1.2, kp_lat = 0.8, max_trim = 1.0 }
    end

    local quitKey = opts.quit_key or keys.q
    local interval = opts.interval or 0.25
    -- Background trim / hold refresh; key changes apply immediately
    local tick = opts.tick or 0.05
    local trimEvery = opts.trim_every or 0.2
    local recordName = opts.recordName
    local held = {}
    local waypoints = {}
    local t0 = os.clock()
    local lastSample = 0
    local stop = false
    local trimState = {}
    local wrenchMode = drive.isWrenchMode(control)
    local idleApplied = false
    local lastTrimAt = 0
    local lastCmdKey = nil

    drive.allOff(control)
    idleApplied = true

    local nMotor = 0
    if wrenchMode then
        for _, t in ipairs(control.thrusters) do
            if t.kind == "motor" then
                nMotor = nMotor + 1
            end
        end
    end

    print("Manual control (hold keys):")
    print("  W/S  forward / reverse")
    print("  A/D  yaw left / right")
    print("  Z/C  strafe left / right")
    print("  X    all stop")
    print("  Q    quit" .. (recordName and (" + save path '" .. recordName .. "'") or ""))
    if wrenchMode then
        if nMotor > 0 then
            print("  Electric motors: signed RPM (idle = 0), max "
                .. tostring(control.default_motor_rpm or 256))
        else
            print("  Analog 1-15 + live yaw/strafe trim (off-center CoM cancel)")
            if drive.isInvert(control) then
                print("  invert_analog: ON  (logical full→RS 0, off→RS 15)")
            end
        end
        print("  Thrusters: " .. #control.thrusters .. (nMotor > 0 and (" (" .. nMotor .. " motors)") or ""))
    end
    print()

    local function commandFromKeys()
        local fx = (held[keys.w] and 1 or 0) + (held[keys.s] and -1 or 0)
        local fy = (held[keys.c] and 1 or 0) + (held[keys.z] and -1 or 0)
        local tz = (held[keys.a] and 1 or 0) + (held[keys.d] and -1 or 0)
        return { fx = fx, fy = fy, tz = tz }
    end

    local function refresh(dt, reason)
        local cmd = commandFromKeys()
        local idle = math.abs(cmd.fx) + math.abs(cmd.fy) + math.abs(cmd.tz) < 0.01
        local cmdKey = string.format("%d%d%d", cmd.fx, cmd.fy, cmd.tz)
        local now = os.clock()
        local keysChanged = cmdKey ~= lastCmdKey
        lastCmdKey = cmdKey

        if idle then
            if not idleApplied or reason == "stop" then
                drive.allOff(control)
                idleApplied = true
            end
            return
        end
        idleApplied = false

        if wrenchMode then
            local doTrim = (now - lastTrimAt) >= trimEvery
            local trimmed = cmd
            if doTrim then
                trimmed, trimState = drive.trimCommand(control, cmd, trimState, dt)
                lastTrimAt = now
                -- Keep manual yaw/strafe authority when keys held
                if math.abs(cmd.tz) >= 0.08 then
                    trimmed.tz = cmd.tz
                end
                if math.abs(cmd.fy) >= 0.08 then
                    trimmed.fy = cmd.fy
                end
            elseif not keysChanged and reason ~= "key" then
                return
            end
            drive.applyWrench(control, trimmed.fx, trimmed.fy, trimmed.tz)
        else
            if not keysChanged and reason ~= "key" and reason ~= "stop" then
                return
            end
            drive.setAxis(control, "thrust_forward", cmd.fx > 0)
            drive.setAxis(control, "thrust_reverse", cmd.fx < 0)
            drive.setAxis(control, "steer_left", cmd.tz > 0)
            drive.setAxis(control, "steer_right", cmd.tz < 0)
            drive.setAxis(control, "strafe_left", cmd.fy < 0)
            drive.setAxis(control, "strafe_right", cmd.fy > 0)
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
            idleApplied = true
            lastCmdKey = "000"
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
            -- Apply thrust immediately on key change (main lag fix)
            refresh(tick, "key")
        end
    end

    while not stop do
        local timerId = os.startTimer(tick)
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

        -- Periodic yaw/strafe trim while thrusting (keys already applied immediately)
        refresh(tick, "tick")

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
