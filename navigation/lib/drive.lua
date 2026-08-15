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
    -- Never leave 1–2 RPM creep (looks "stuck on" in CCA UI)
    if math.abs(rpm) < 2 then
        rpm = 0
    end
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

--- Fast stop: only calibrated thrusters / queued motors (no network scan).
-- Full getNames()+getRPM scan was freezing input for 1–2s on every key release.
function drive.hardStopThrusters(control)
    control = control or drive.loadControl()
    local names = {}
    local seen = {}
    local function add(name)
        if name and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    if type(control) == "table" then
        if type(control.thrusters) == "table" then
            for _, t in ipairs(control.thrusters) do
                add(t.name)
                if t.kind ~= "motor" then
                    drive.setActuator(control, t, 0)
                end
            end
        end
        if type(control.unused) == "table" then
            for _, name in ipairs(control.unused) do
                add(name)
            end
        end
    end
    for name, _ in pairs(motorDesired) do
        add(name)
    end
    for _, name in ipairs(names) do
        motorDesired[name] = 0
        motorSent[name] = nil -- force setRPM(0) even if we thought it was already 0
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
end

--- Panic stop for X / idle: slower but hits every motor past CCA anti-spam.
function drive.panicStop(control)
    drive.hardStopThrusters(control)
    local names = {}
    local seen = {}
    local function add(name)
        if name and not seen[name] and peripheral.isPresent(name) then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "electric_motor") then
            add(name)
        end
    end
    if type(control) == "table" then
        if type(control.thrusters) == "table" then
            for _, t in ipairs(control.thrusters) do
                add(t.name)
            end
        end
        if type(control.unused) == "table" then
            for _, name in ipairs(control.unused) do
                add(name)
            end
        end
    end
    for _, name in ipairs(names) do
        motorDesired[name] = 0
        motorWrapCache[name] = nil
        local m = peripheral.wrap(name)
        if m then
            pcall(function()
                if m.setRPM then
                    m.setRPM(0)
                end
                if m.setSpeed then
                    m.setSpeed(0)
                end
                if m.stop then
                    m.stop()
                end
            end)
        end
        motorSent[name] = 0
        sleep(0.05)
    end
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
        if math.abs(nextRpm) < 2 then
            nextRpm = 0
        end
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
        if math.abs(duty) < 0.08 then
            duty = 0
        end
        local rpm = duty * maxRpm * rpmSign
        if math.abs(rpm) < 2 then
            rpm = 0
        end
        -- Always re-issue stop when target is 0 (CCA sometimes ignores a prior 0)
        if rpm == 0 then
            motorDesired[name] = 0
            motorSent[name] = nil
        end
        drive.setMotorRpm(name, rpm)
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

--- Invert 3x3 matrix * vector (Gaussian elimination). Returns nil if singular.
local function solve3x3(A, b)
    local m = {
        { A[1][1], A[1][2], A[1][3], b[1] },
        { A[2][1], A[2][2], A[2][3], b[2] },
        { A[3][1], A[3][2], A[3][3], b[3] },
    }
    for col = 1, 3 do
        local pivot = col
        for r = col + 1, 3 do
            if math.abs(m[r][col]) > math.abs(m[pivot][col]) then
                pivot = r
            end
        end
        if math.abs(m[pivot][col]) < 1e-12 then
            return nil
        end
        m[col], m[pivot] = m[pivot], m[col]
        local div = m[col][col]
        for c = col, 4 do
            m[col][c] = m[col][c] / div
        end
        for r = 1, 3 do
            if r ~= col then
                local f = m[r][col]
                for c = col, 4 do
                    m[r][c] = m[r][c] - f * m[col][c]
                end
            end
        end
    end
    return { m[1][4], m[2][4], m[3][4] }
end

--- Reassembly-style: solve thruster duties from calibrated force+torque wrenches.
-- Near-CoM strafe thrusters get small tz; combinations (diagonals) produce turn.
function drive.applyReassembly(control, fx, fy, tz)
    control = control or drive.loadControl()
    if not drive.isWrenchMode(control) then
        return false
    end

    fx, fy, tz = fx or 0, fy or 0, tz or 0
    local cmdMag = math.sqrt(fx * fx + fy * fy + tz * tz)
    if cmdMag < 1e-4 then
        drive.hardStopThrusters(control)
        return true
    end

    local thrusters = control.thrusters
    local n = #thrusters
    if n == 0 then
        return false
    end

    -- Desired wrench in calibration units (norm ≈ response at probe RPM)
    local gain = (control.gains and control.gains.norm) or 1
    if gain < 1e-6 then
        gain = 1
    end
    -- Cost weights: uncommanded axes are expensive so strafe nulls yaw (CoM couple)
    -- and yaw nulls leftover strafe — Reassembly-style decoupling.
    local function axisW(cmd, onW, offW)
        return math.abs(cmd) > 0.15 and onW or offW
    end
    local axW = {
        axisW(fx, 1.0, 3.2),
        axisW(fy, 1.0, 3.2),
        axisW(tz, 1.0, 5.0), -- strongest: kill yaw when only strafing/surging
    }
    local sw = {
        math.sqrt(axW[1]),
        math.sqrt(axW[2]),
        math.sqrt(axW[3]),
    }

    local function dutiesFor(scale)
        local Fd = {
            (fx / cmdMag) * gain * scale * sw[1],
            (fy / cmdMag) * gain * scale * sw[2],
            (tz / cmdMag) * gain * scale * sw[3],
        }
        local G = {
            { 1e-8, 0, 0 },
            { 0, 1e-8, 0 },
            { 0, 0, 1e-8 },
        }
        for _, t in ipairs(thrusters) do
            local w1 = (t.fx or 0) * sw[1]
            local w2 = (t.fy or 0) * sw[2]
            local w3 = (t.tz or 0) * sw[3]
            G[1][1] = G[1][1] + w1 * w1
            G[1][2] = G[1][2] + w1 * w2
            G[1][3] = G[1][3] + w1 * w3
            G[2][1] = G[2][1] + w2 * w1
            G[2][2] = G[2][2] + w2 * w2
            G[2][3] = G[2][3] + w2 * w3
            G[3][1] = G[3][1] + w3 * w1
            G[3][2] = G[3][2] + w3 * w2
            G[3][3] = G[3][3] + w3 * w3
        end
        local lambda = solve3x3(G, Fd)
        if not lambda then
            return nil
        end
        local u = {}
        local maxAbs = 0
        for i, t in ipairs(thrusters) do
            local wi1 = (t.fx or 0) * sw[1]
            local wi2 = (t.fy or 0) * sw[2]
            local wi3 = (t.tz or 0) * sw[3]
            local ui = wi1 * lambda[1] + wi2 * lambda[2] + wi3 * lambda[3]
            if t.kind ~= "motor" then
                ui = math.max(0, ui)
            end
            u[i] = ui
            maxAbs = math.max(maxAbs, math.abs(ui))
        end
        return u, maxAbs
    end

    local u, maxAbs = dutiesFor(1.0)
    if not u then
        -- Fallback: greedy wrench alloc
        return drive.applyWrench(control, fx, fy, tz)
    end
    if maxAbs > 1 then
        local u2, m2 = dutiesFor(1.0 / maxAbs)
        if u2 then
            u, maxAbs = u2, m2
        end
    end

    for i, t in ipairs(thrusters) do
        local duty = util.clamp(u[i] or 0, (t.kind == "motor") and -1 or 0, 1)
        if math.abs(duty) < 0.06 then
            duty = 0
        end
        drive.setActuator(control, t, duty)
        -- Ensure idle thrusters actually get a stop command this frame
        if duty == 0 and t.kind == "motor" and t.name then
            motorDesired[t.name] = 0
            if motorSent[t.name] ~= 0 then
                motorSent[t.name] = nil
            end
        end
    end

    -- Keep yaw couples intact (don't unevenly shrink one diagonal)
    if not (math.abs(tz) >= 0.5 and math.abs(fx) + math.abs(fy) < 0.25) then
        drive.applyPowerBudget(control)
    end
    -- After budget, re-zero tiny RPMs and force-stop anything that should be off
    for name, rpm in pairs(motorDesired) do
        if math.abs(rpm or 0) < 2 then
            motorDesired[name] = 0
            if motorSent[name] ~= 0 then
                motorSent[name] = nil
            end
        end
    end
    drive.commitMotorsNow()
    return true
end

--- Write every pending motor RPM now (retries once on anti-spam).
function drive.commitMotorsNow()
    local pending = {}
    for name, want in pairs(motorDesired) do
        if motorSent[name] ~= want then
            pending[#pending + 1] = name
        end
    end
    -- Stops first
    table.sort(pending, function(a, b)
        local da, db = motorDesired[a] or 0, motorDesired[b] or 0
        if (da == 0) ~= (db == 0) then
            return da == 0
        end
        return tostring(a) < tostring(b)
    end)
    for _, name in ipairs(pending) do
        if not writeMotorRpm(name, motorDesired[name] or 0) then
            sleep(0.05)
            writeMotorRpm(name, motorDesired[name] or 0)
        end
    end
end

function drive.flushMotorsAll(maxCalls)
    maxCalls = maxCalls or 12
    local n = 0
    while n < maxCalls and drive.motorsPending() do
        if drive.flushMotors(1) < 1 then
            break
        end
        n = n + 1
    end
    return n
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
        drive.hardStopThrusters(control)
        return true
    end

    local wx = (control.weights and control.weights.fx) or 1
    local wy = (control.weights and control.weights.fy) or 1
    local wz = (control.weights and control.weights.tz) or 3.0

    local scores = {}
    local maxAbs = 0
    for i, t in ipairs(control.thrusters) do
        local s = wx * fx * (t.fx or 0) + wy * fy * (t.fy or 0) + wz * tz * (t.tz or 0)
        scores[i] = s
        if math.abs(s) > maxAbs then
            maxAbs = math.abs(s)
        end
    end

    -- Always mix differential yaw on forward motors (calib tz is often weak/wrong)
    if math.abs(tz) > 0.08 then
        local side = 1
        for i, t in ipairs(control.thrusters) do
            if t.kind == "motor" then
                local forwardish = math.abs(t.fx or 0)
                if forwardish < 1e-4 then
                    forwardish = 0.2 -- still participate in turn if unlabeled
                end
                scores[i] = (scores[i] or 0) + tz * side * forwardish * 2.0
                side = -side
            end
        end
        maxAbs = 0
        for i = 1, #scores do
            if math.abs(scores[i] or 0) > maxAbs then
                maxAbs = math.abs(scores[i])
            end
        end
    end

    if maxAbs < 1e-6 then
        drive.hardStopThrusters(control)
        return false
    end

    local scale = math.min(1, cmdMag)
    for i, t in ipairs(control.thrusters) do
        local duty = ((scores[i] or 0) / maxAbs) * scale
        if t.kind == "motor" then
            drive.setActuator(control, t, duty)
        else
            drive.setActuator(control, t, math.max(0, duty))
        end
    end
    drive.applyPowerBudget(control)
    drive.flushMotors(2)
    return true
end

--- If calibration wiped yaw, invent differential levers so A/D can still turn.
function drive.healYawThrusters(control)
    if not control or type(control.thrusters) ~= "table" then
        return false
    end
    local maxTz, maxFx = 0, 0
    for _, t in ipairs(control.thrusters) do
        maxTz = math.max(maxTz, math.abs(t.tz or 0))
        maxFx = math.max(maxFx, math.abs(t.fx or 0))
    end
    -- Heal when yaw is missing OR much weaker than surge (bad reverse-avg calib)
    if maxTz >= 0.02 and maxTz >= maxFx * 0.15 then
        return false
    end
    local side = 1
    local healed = 0
    for _, t in ipairs(control.thrusters) do
        if math.abs(t.fx or 0) > 0.01 or t.kind == "motor" then
            local base = math.abs(t.fx or 0)
            if base < 0.01 then
                base = 0.25
            end
            t.tz = side * base * 0.5
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
    drive.commitMotorsNow()
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
    local down = {}
    local pendingUp = {}
    local waypoints = {}
    local t0 = os.clock()
    local lastSample = 0
    local stop = false
    local wrenchMode = drive.isWrenchMode(control)
    local lastIdleStopAt = 0
    local KEY_UP_GRACE = 0.06
    local STALE_KEY_SEC = 0.35
    local lastSeen = {}

    local YAW_L = { [keys.a] = true, [keys.left] = true, [keys.j] = true }
    local YAW_R = { [keys.d] = true, [keys.right] = true, [keys.l] = true }
    local MOVE = {
        [keys.w] = true, [keys.s] = true,
        [keys.a] = true, [keys.d] = true,
        [keys.z] = true, [keys.c] = true,
        [keys.left] = true, [keys.right] = true,
        [keys.j] = true, [keys.l] = true,
    }

    if wrenchMode then
        -- Keep real calib wrenches (do NOT invent left/right groups)
        drive.clampControlRpm(control)
    else
        drive.clampControlRpm(control)
    end
    drive.hardStopThrusters(control)

    local nMotor = 0
    if wrenchMode then
        for _, t in ipairs(control.thrusters) do
            if t.kind == "motor" then
                nMotor = nMotor + 1
            end
        end
    end

    print("Manual control (Reassembly wrench alloc):")
    print("  W/S surge | A/D or arrows or J/L yaw | Z/C strafe")
    print("  X panic-stop | Q quit")
    if wrenchMode then
        print("  Thrusters: " .. #control.thrusters .. " (" .. nMotor .. " motors)")
        print("  Uses calib fx/fy/tz — diagonals turn even if each thruster looks like strafe")
    end
    print()

    local function yawLeft()
        for k, _ in pairs(YAW_L) do
            if down[k] then return true end
        end
        return false
    end
    local function yawRight()
        for k, _ in pairs(YAW_R) do
            if down[k] then return true end
        end
        return false
    end

    local function commandFromKeys()
        local fx = (down[keys.w] and 1 or 0) + (down[keys.s] and -1 or 0)
        local fy = (down[keys.c] and 1 or 0) + (down[keys.z] and -1 or 0)
        local tz = (yawLeft() and 1 or 0) - (yawRight() and 1 or 0)
        return { fx = fx, fy = fy, tz = tz }
    end

    local function anyDown()
        for _, v in pairs(down) do
            if v then return true end
        end
        return false
    end

    local function clearOpposites(key)
        if key == keys.w then down[keys.s] = nil
        elseif key == keys.s then down[keys.w] = nil
        elseif YAW_L[key] then
            for k, _ in pairs(YAW_R) do down[k] = nil; pendingUp[k] = nil end
        elseif YAW_R[key] then
            for k, _ in pairs(YAW_L) do down[k] = nil; pendingUp[k] = nil end
        elseif key == keys.z then down[keys.c] = nil
        elseif key == keys.c then down[keys.z] = nil
        end
    end

    local function applyThrust()
        local cmd = commandFromKeys()
        if cmd.fx == 0 and cmd.fy == 0 and cmd.tz == 0 then
            drive.hardStopThrusters(control)
            drive.commitMotorsNow()
            lastIdleStopAt = os.clock()
            return
        end
        if wrenchMode then
            drive.applyReassembly(control, cmd.fx, cmd.fy, cmd.tz)
        else
            drive.setAxis(control, "thrust_forward", cmd.fx > 0)
            drive.setAxis(control, "thrust_reverse", cmd.fx < 0)
            drive.setAxis(control, "steer_left", cmd.tz > 0)
            drive.setAxis(control, "steer_right", cmd.tz < 0)
            drive.setAxis(control, "strafe_left", cmd.fy < 0)
            drive.setAxis(control, "strafe_right", cmd.fy > 0)
        end
    end

    local function flushPendingUps()
        local now = os.clock()
        local changed = false
        for key, at in pairs(pendingUp) do
            if now >= at then
                down[key] = nil
                pendingUp[key] = nil
                changed = true
            end
        end
        -- Lost key_up (CC sticky): drop MOVE keys with no recent key/repeat
        for key, _ in pairs(down) do
            if MOVE[key] and (now - (lastSeen[key] or 0)) > STALE_KEY_SEC then
                down[key] = nil
                pendingUp[key] = nil
                changed = true
            end
        end
        if changed then
            applyThrust()
        end
    end

    while not stop do
        local timerId = os.startTimer(tick)
        while true do
            local ev = { os.pullEventRaw() }
            if ev[1] == "terminate" then
                drive.hardStopThrusters(control)
                error("Terminated", 0)
            elseif ev[1] == "key" then
                local key, isRepeat = ev[2], ev[3] and true or false
                if MOVE[key] then
                    pendingUp[key] = nil
                    down[key] = true
                    lastSeen[key] = os.clock()
                    if not isRepeat then
                        clearOpposites(key)
                        applyThrust()
                    end
                    -- repeats keep chord alive (cancel pending key_up from other key)
                elseif (not isRepeat) and key == quitKey then
                    stop = true
                    break
                elseif (not isRepeat) and key == keys.x then
                    print("Panic stop")
                    down = {}
                    pendingUp = {}
                    drive.panicStop(control)
                    lastIdleStopAt = os.clock()
                end
            elseif ev[1] == "key_up" then
                if MOVE[ev[2]] then
                    -- Grace so pressing a second key doesn't drop the first
                    pendingUp[ev[2]] = os.clock() + KEY_UP_GRACE
                end
            elseif ev[1] == "timer" and ev[2] == timerId then
                break
            end
        end
        if stop then break end

        flushPendingUps()

        if not anyDown() then
            if (os.clock() - lastIdleStopAt) >= 0.15 then
                drive.hardStopThrusters(control)
                drive.commitMotorsNow()
                lastIdleStopAt = os.clock()
            end
        end
        -- Finish any remaining motor RPM pushes without blocking the next keys long
        drive.flushMotors(3)

        if recordName then
            local now = os.clock()
            if now - lastSample >= interval * 0.9 then
                lastSample = now
                local ok, wp = pcall(path.sampleWaypoint, t0)
                if ok and wp then
                    waypoints[#waypoints + 1] = wp
                end
            end
        end
    end

    down = {}
    drive.hardStopThrusters(control)

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
