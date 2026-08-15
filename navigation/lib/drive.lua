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
    return drive.clampControlRpm(util.readJSON(CONTROL_PATH))
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
--
-- Motors use a desired/sent queue: key handlers only set targets (cheap);
-- flushMotors() pushes at most a few setRPM calls so CCA anti-spam + modem
-- lag don't block the event loop (which felt like 0.5–1s input delay).
--
-- IMPORTANT: Create Addition motors KEEP their last RPM if the computer
-- reboots/shuts off mid-command. Always stop() before exit; boot must zero them.
local DEFAULT_MAX_RPM = 24 -- hard cap per motor for this boat
local DEFAULT_POWER_BUDGET_RF = 45
local DEFAULT_FE_PER_RPM = 1 -- CCA-ish: ~1 FE/t per RPM (pack-dependent)
local motorDesired = {}
local motorSent = {}
local motorWrapCache = {}
local lastMotorFlushAt = 0
local MOTOR_FLUSH_GAP = 0.06 -- Create Addition global anti-spam is picky

local function clampMotorRpm(rpm, maxRpm)
    maxRpm = math.min(math.abs(tonumber(maxRpm) or DEFAULT_MAX_RPM), DEFAULT_MAX_RPM)
    if maxRpm < 1 then
        maxRpm = DEFAULT_MAX_RPM
    end
    rpm = math.floor((tonumber(rpm) or 0) + 0.5)
    if rpm > maxRpm then
        rpm = maxRpm
    elseif rpm < -maxRpm then
        rpm = -maxRpm
    end
    return rpm
end

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

local function writeMotorRpm(name, rpm)
    local m = getMotor(name)
    if not m then
        return false
    end
    rpm = clampMotorRpm(rpm, DEFAULT_MAX_RPM)
    local ok, err = pcall(function()
        if math.abs(rpm) < 1 then
            -- Both: some CCA builds ignore stop() or ignore setRPM(0) alone
            if m.setRPM then
                m.setRPM(0)
            end
            if m.stop then
                m.stop()
            end
        elseif m.setRPM then
            m.setRPM(rpm)
        elseif m.setSpeed then
            m.setSpeed(rpm)
        else
            error("no setRPM")
        end
    end)
    if ok then
        motorSent[name] = rpm
        lastMotorFlushAt = os.clock()
        return true
    end
    if err and not string.find(tostring(err), "Anti Spam") then
        motorWrapCache[name] = nil
    end
    lastMotorFlushAt = os.clock()
    return false
end

--- Queue a motor RPM target (does not call the peripheral yet).
function drive.setMotorRpm(name, rpm)
    if not name then
        return false
    end
    motorDesired[name] = clampMotorRpm(rpm, DEFAULT_MAX_RPM)
    return true
end

function drive.defaultMaxRpm()
    return DEFAULT_MAX_RPM
end

--- Cap control file RPM fields to the hard max (mutates in-memory config).
function drive.clampControlRpm(control)
    if type(control) ~= "table" then
        return control
    end
    control.default_motor_rpm = math.min(tonumber(control.default_motor_rpm) or DEFAULT_MAX_RPM, DEFAULT_MAX_RPM)
    if control.power_budget_rf == nil then
        control.power_budget_rf = DEFAULT_POWER_BUDGET_RF
    end
    if control.fe_per_rpm == nil then
        control.fe_per_rpm = DEFAULT_FE_PER_RPM
    end
    if type(control.thrusters) == "table" then
        for _, t in ipairs(control.thrusters) do
            t.max_rpm = math.min(tonumber(t.max_rpm) or control.default_motor_rpm, DEFAULT_MAX_RPM)
        end
    end
    return control
end

--- Scale queued motor RPMs so sum(|rpm|)*fe_per_rpm <= power_budget_rf.
function drive.applyPowerBudget(control)
    control = control or drive.loadControl()
    local budget = tonumber(control and control.power_budget_rf)
    if not budget or budget <= 0 then
        return false
    end
    local fePer = tonumber(control and control.fe_per_rpm) or DEFAULT_FE_PER_RPM
    if fePer < 1e-6 then
        fePer = DEFAULT_FE_PER_RPM
    end
    local maxUnits = budget / fePer
    local total = 0
    for _, rpm in pairs(motorDesired) do
        total = total + math.abs(rpm or 0)
    end
    if total <= maxUnits + 1e-6 then
        return false
    end
    local scale = maxUnits / total
    for name, rpm in pairs(motorDesired) do
        local nextRpm = math.floor((rpm or 0) * scale + (rpm >= 0 and 0.5 or -0.5))
        if nextRpm ~= motorDesired[name] then
            motorDesired[name] = nextRpm
            motorSent[name] = nil
        end
    end
    return true
end

--- Block until this motor's desired RPM is sent (for calibrate pulses).
-- Yields via sleep so Ctrl+T can interrupt; keeps timeout short.
function drive.setMotorRpmNow(name, rpm, timeout)
    drive.setMotorRpm(name, rpm)
    motorSent[name] = nil
    local deadline = os.clock() + (timeout or 0.8)
    while os.clock() < deadline do
        if motorSent[name] == motorDesired[name] then
            return true
        end
        drive.flushMotors(1)
        -- Short yield; pullEventRaw would also work but sleep is fine for calibrate
        sleep(MOTOR_FLUSH_GAP)
    end
    return motorSent[name] == motorDesired[name]
end

--- Push pending motor targets. budget = max peripheral calls this invoke.
function drive.flushMotors(budget)
    budget = budget or 2
    local now = os.clock()
    local sent = 0

    local function pending(name)
        local want = motorDesired[name]
        if want == nil then
            return false
        end
        return motorSent[name] ~= want
    end

    local function tryFlush(name)
        if not pending(name) then
            return false
        end
        if sent >= budget then
            return false
        end
        if (now - lastMotorFlushAt) < MOTOR_FLUSH_GAP and sent == 0 then
            -- need to wait globally; caller should retry next tick
            return false
        end
        -- After first success in this flush, still respect gap via lastMotorFlushAt
        if sent > 0 and (os.clock() - lastMotorFlushAt) < MOTOR_FLUSH_GAP then
            return false
        end
        local want = motorDesired[name]
        if writeMotorRpm(name, want) then
            sent = sent + 1
            now = os.clock()
            return true
        end
        sent = sent + 1 -- count failed anti-spam attempts so we don't hammer
        now = os.clock()
        return false
    end

    -- Prefer stops first so release/X feel responsive
    for name, want in pairs(motorDesired) do
        if want == 0 and pending(name) then
            tryFlush(name)
            if sent >= budget then
                return sent
            end
        end
    end
    for name, _ in pairs(motorDesired) do
        if pending(name) then
            tryFlush(name)
            if sent >= budget then
                return sent
            end
        end
    end
    return sent
end

function drive.motorsPending()
    for name, want in pairs(motorDesired) do
        if motorSent[name] ~= want then
            return true
        end
    end
    return false
end

--- Invalidate caches and queue stop for known motors (and optional full scan).
-- Non-blocking by default — does not sleep (Ctrl+T must stay snappy).
function drive.stopAllMotors(opts)
    opts = opts or {}
    local names = {}
    if opts.names then
        names = opts.names
    else
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.hasType(name, "electric_motor") then
                names[#names + 1] = name
            end
        end
    end
    for _, name in ipairs(names) do
        motorDesired[name] = 0
        motorSent[name] = nil -- force re-send
        -- Immediate hard stop attempt (don't wait for flush queue)
        local m = getMotor(name)
        if m then
            pcall(function()
                if m.setRPM then
                    m.setRPM(0)
                end
                if m.stop then
                    m.stop()
                end
            end)
            motorSent[name] = 0
        end
    end
    drive.flushMotors(1)
    local doDrain = opts.drain ~= false -- default drain on stop-all
    if opts.drain == false then
        doDrain = false
    end
    if opts.quick then
        doDrain = false
    end
    if doDrain then
        local deadline = os.clock() + (opts.drain_timeout or 0.5)
        while drive.motorsPending() and os.clock() < deadline do
            drive.flushMotors(1)
            sleep(MOTOR_FLUSH_GAP)
        end
    end
end

function drive.setThrustLevel(control, name, logicalLevel)
    local invert = drive.isInvert(control)
    if getMotor(name) then
        local maxRpm = math.min(
            (control and control.default_motor_rpm) or DEFAULT_MAX_RPM,
            DEFAULT_MAX_RPM
        )
        local u = util.clamp((tonumber(logicalLevel) or 0) / 15, 0, 1)
        drive.setMotorRpm(name, u * maxRpm)
        drive.flushMotors(1)
        return true
    end
    return drive.setRelayPhysical(name, drive.logicalToPhysical(logicalLevel, invert))
end

--- duty in [-1,1] for motors (signed RPM), [0,1] for relays.
-- Motors only queue desired RPM — call drive.flushMotors() to push.
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
        local maxRpm = math.min(
            thruster.max_rpm or (control and control.default_motor_rpm) or DEFAULT_MAX_RPM,
            DEFAULT_MAX_RPM
        )
        local rpmSign = thruster.rpm_sign or 1
        duty = util.clamp(tonumber(duty) or 0, -1, 1)
        if math.abs(duty) < 0.03 then
            duty = 0
        end
        drive.setMotorRpm(name, duty * maxRpm * rpmSign)
        return true
    end

    duty = util.clamp(tonumber(duty) or 0, 0, 1)
    local level = 0
    if duty >= 0.04 then
        level = math.max(1, math.floor(duty * 15 + 0.5))
    end
    return drive.setThrustLevel(control, name, level)
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
    local motorNames = {}
    if type(control) == "table" and type(control.thrusters) == "table" then
        for _, t in ipairs(control.thrusters) do
            if t.kind == "motor" or getMotor(t.name) then
                motorNames[#motorNames + 1] = t.name
                motorDesired[t.name] = 0
                motorSent[t.name] = nil
            else
                drive.setActuator(control, t, 0)
            end
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
    if opts.scan_all then
        drive.stopAllMotors()
    elseif #motorNames > 0 then
        -- Push stops without a full network scan; don't sleep long (keeps keys responsive)
        drive.flushMotors(1)
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

--- Direct (non-greedy) allocation for teleop — more predictable yaw/strafe.
-- Maps command (-1..1) onto thrusters by wrench projection, then normalizes.
function drive.applyDirect(control, fx, fy, tz)
    control = control or drive.loadControl()
    if not drive.isWrenchMode(control) then
        return drive.applyWrench(control, fx, fy, tz)
    end

    fx, fy, tz = fx or 0, fy or 0, tz or 0
    local cmdMag = math.sqrt(fx * fx + fy * fy + tz * tz)
    if cmdMag < 1e-4 then
        for _, t in ipairs(control.thrusters) do
            if t.kind == "motor" then
                motorDesired[t.name] = 0
                motorSent[t.name] = nil
            else
                drive.setActuator(control, t, 0)
            end
        end
        drive.flushMotors(1)
        return true
    end

    local wx = (control.weights and control.weights.fx) or 1
    local wy = (control.weights and control.weights.fy) or 1
    local wz = (control.weights and control.weights.tz) or 2.2

    local scores = {}
    local maxAbs = 0
    for i, t in ipairs(control.thrusters) do
        local s = wx * fx * (t.fx or 0) + wy * fy * (t.fy or 0) + wz * tz * (t.tz or 0)
        scores[i] = s
        if math.abs(s) > maxAbs then
            maxAbs = math.abs(s)
        end
    end

    -- If yaw was commanded but nothing scored (tz≈0 in calib), synthesize differential
    if maxAbs < 1e-6 and math.abs(tz) > 0.08 then
        local side = 1
        for i, t in ipairs(control.thrusters) do
            local forwardish = math.abs(t.fx or 0)
            if forwardish > 1e-4 then
                scores[i] = tz * side * forwardish
                side = -side
                if math.abs(scores[i]) > maxAbs then
                    maxAbs = math.abs(scores[i])
                end
            end
        end
    end

    if maxAbs < 1e-6 then
        for _, t in ipairs(control.thrusters) do
            if t.kind == "motor" then
                motorDesired[t.name] = 0
            end
        end
        drive.flushMotors(1)
        return false
    end

    local scale = math.min(1, cmdMag)
    for i, t in ipairs(control.thrusters) do
        local duty = (scores[i] / maxAbs) * scale
        if t.kind == "motor" then
            drive.setActuator(control, t, duty)
        else
            drive.setActuator(control, t, math.max(0, duty))
        end
    end
    drive.applyPowerBudget(control)
    drive.flushMotors(1)
    return true
end

--- If calibration wiped yaw, invent differential levers so A/D can still turn.
function drive.healYawThrusters(control)
    if not control or type(control.thrusters) ~= "table" then
        return false
    end
    local maxTz = 0
    for _, t in ipairs(control.thrusters) do
        maxTz = math.max(maxTz, math.abs(t.tz or 0))
    end
    if maxTz >= 0.02 then
        return false
    end
    local side = 1
    local healed = 0
    for _, t in ipairs(control.thrusters) do
        if math.abs(t.fx or 0) > 0.01 then
            t.tz = (t.fx or 0) * side * 0.4
            t.mag = math.sqrt((t.fx or 0) ^ 2 + (t.fy or 0) ^ 2 + (t.tz or 0) ^ 2)
            side = -side
            healed = healed + 1
        end
    end
    return healed > 0
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
        for _, t in ipairs(control.thrusters) do
            if t.kind == "motor" or (t.name and getMotor(t.name)) then
                motorDesired[t.name] = 0
            else
                drive.setActuator(control, t, 0)
            end
        end
        drive.flushMotors(1)
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
    drive.applyPowerBudget(control)
    drive.flushMotors(1)
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
        drive.flushMotors(2)
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
    local tick = opts.tick or 0.05
    local recordName = opts.recordName
    local held = {}
    local pendingUp = {}
    local waypoints = {}
    local t0 = os.clock()
    local lastSample = 0
    local stop = false
    local wrenchMode = drive.isWrenchMode(control)
    local lastCmdKey = nil
    local KEY_UP_DEBOUNCE = 0.2

    local MOVE = {
        [keys.w] = true,
        [keys.s] = true,
        [keys.a] = true,
        [keys.d] = true,
        [keys.z] = true,
        [keys.c] = true,
        [keys.left] = true,
        [keys.right] = true,
    }

    local function clearOpposite(key)
        local pairs_ = {
            [keys.w] = keys.s,
            [keys.s] = keys.w,
            [keys.a] = keys.d,
            [keys.d] = keys.a,
            [keys.left] = keys.right,
            [keys.right] = keys.left,
            [keys.z] = keys.c,
            [keys.c] = keys.z,
        }
        local other = pairs_[key]
        if other then
            held[other] = nil
            pendingUp[other] = nil
        end
        -- A mirrors left, D mirrors right
        if key == keys.a or key == keys.left then
            held[keys.d] = nil
            held[keys.right] = nil
            pendingUp[keys.d] = nil
            pendingUp[keys.right] = nil
        elseif key == keys.d or key == keys.right then
            held[keys.a] = nil
            held[keys.left] = nil
            pendingUp[keys.a] = nil
            pendingUp[keys.left] = nil
        end
    end

    if wrenchMode and drive.healYawThrusters(control) then
        print("Note: calib had weak yaw — using differential forward thrusters for turn")
    end
    drive.clampControlRpm(control)

    drive.allOff(control)

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
    print("  A/D or arrows  yaw left / right")
    print("  Z/C  strafe left / right")
    print("  X    all stop")
    print("  Q    quit" .. (recordName and (" + save path '" .. recordName .. "'") or ""))
    if wrenchMode then
        print("  Thrusters: " .. #control.thrusters .. (nMotor > 0 and (" (" .. nMotor .. " motors)") or ""))
        if nMotor > 0 then
            print(string.format(
                "  Motors: max %s RPM, power budget %s RF/t",
                tostring(control.default_motor_rpm or 24),
                tostring(control.power_budget_rf or 45)
            ))
        end
    end
    print()

    local function commandFromKeys()
        local fx = (held[keys.w] and 1 or 0) + (held[keys.s] and -1 or 0)
        local fy = (held[keys.c] and 1 or 0) + (held[keys.z] and -1 or 0)
        local yawL = (held[keys.a] or held[keys.left]) and 1 or 0
        local yawR = (held[keys.d] or held[keys.right]) and 1 or 0
        return { fx = fx, fy = fy, tz = yawL - yawR }
    end

    local function forceIdle()
        lastCmdKey = "0,0,0"
        if wrenchMode then
            for _, t in ipairs(control.thrusters) do
                if t.kind == "motor" then
                    motorDesired[t.name] = 0
                    motorSent[t.name] = nil
                else
                    drive.setActuator(control, t, 0)
                end
            end
            drive.flushMotors(1)
        else
            drive.allOff(control)
        end
    end

    local function applyCommand()
        local cmd = commandFromKeys()
        local cmdKey = string.format("%d,%d,%d", cmd.fx, cmd.fy, cmd.tz)
        if cmdKey == lastCmdKey then
            return
        end
        lastCmdKey = cmdKey

        if cmd.fx == 0 and cmd.fy == 0 and cmd.tz == 0 then
            forceIdle()
            return
        end

        if wrenchMode then
            drive.applyDirect(control, cmd.fx, cmd.fy, cmd.tz)
        else
            drive.setAxis(control, "thrust_forward", cmd.fx > 0)
            drive.setAxis(control, "thrust_reverse", cmd.fx < 0)
            drive.setAxis(control, "steer_left", cmd.tz > 0)
            drive.setAxis(control, "steer_right", cmd.tz < 0)
            drive.setAxis(control, "strafe_left", cmd.fy < 0)
            drive.setAxis(control, "strafe_right", cmd.fy > 0)
        end
    end

    --- Fresh press only. Repeats never set held=true by themselves (that caused
    --- ghost pulses from queued repeats after you let go).
    local function onMoveDown(key)
        pendingUp[key] = nil
        held[key] = true
        clearOpposite(key)
        applyCommand()
    end

    --- Repeats only cancel a pending release while the key is still considered down.
    local function onMoveRepeat(key)
        if held[key] or pendingUp[key] then
            pendingUp[key] = nil
            held[key] = true
        end
        -- do not applyCommand — already thrusting
    end

    local function onMoveUp(key)
        -- Defer: spurious key_ups while held are cancelled by a following repeat
        pendingUp[key] = os.clock() + KEY_UP_DEBOUNCE
    end

    local function flushPendingKeyUps()
        local now = os.clock()
        local changed = false
        for key, at in pairs(pendingUp) do
            if now >= at then
                held[key] = nil
                pendingUp[key] = nil
                changed = true
            end
        end
        if changed then
            applyCommand()
        end
    end

    while not stop do
        local timerId = os.startTimer(tick)
        while true do
            local ev = { os.pullEventRaw() }
            if ev[1] == "terminate" then
                forceIdle()
                error("Terminated", 0)
            elseif ev[1] == "key" then
                local key, isRepeat = ev[2], ev[3] and true or false
                if MOVE[key] then
                    if isRepeat then
                        onMoveRepeat(key)
                    else
                        onMoveDown(key)
                    end
                elseif not isRepeat then
                    if key == quitKey then
                        stop = true
                        break
                    elseif key == keys.x then
                        held = {}
                        pendingUp = {}
                        forceIdle()
                    end
                end
            elseif ev[1] == "key_up" then
                if MOVE[ev[2]] then
                    onMoveUp(ev[2])
                end
            elseif ev[1] == "timer" and ev[2] == timerId then
                break
            end
        end
        if stop then
            break
        end

        flushPendingKeyUps()

        -- Hard idle watchdog: no keys → motors must be zero (kills ghost thrust)
        local cmd = commandFromKeys()
        if cmd.fx == 0 and cmd.fy == 0 and cmd.tz == 0 then
            if lastCmdKey ~= "0,0,0" then
                forceIdle()
            elseif drive.motorsPending() then
                drive.flushMotors(2)
            end
        else
            drive.flushMotors(2)
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

    forceIdle()
    local deadline = os.clock() + 0.25
    while drive.motorsPending() and os.clock() < deadline do
        drive.flushMotors(1)
        sleep(MOTOR_FLUSH_GAP)
    end

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
