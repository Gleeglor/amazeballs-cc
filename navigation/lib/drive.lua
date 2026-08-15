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
local DEFAULT_MAX_RPM = 24 -- per motor (NOT a shared total across thrusters)
local DEFAULT_POWER_BUDGET_RF = 0 -- 0 = off; shared RF cap is opt-in only
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

    -- Zero path: setRPM(0) and stop() independently. If one hits CCA anti-spam,
    -- the other may still land — never skip stop() because setRPM failed.
    if math.abs(rpm) < 1 then
        local okRpm, errRpm = false, nil
        local okStop, errStop = false, nil
        if m.setRPM then
            okRpm, errRpm = pcall(function()
                m.setRPM(0)
            end)
        end
        if m.stop then
            okStop, errStop = pcall(function()
                m.stop()
            end)
        end
        if okRpm or okStop then
            motorSent[name] = 0
            return true
        end
        local err = errRpm or errStop
        if err and not string.find(tostring(err), "Anti Spam") then
            motorWrapCache[name] = nil
        end
        return false
    end

    local ok, err = pcall(function()
        if m.setRPM then
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

local function collectThrusterMotorNames(control)
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
    return names
end

--- Zero every known thruster motor immediately (bypass flush gap for stops).
-- Fixes W-release leaving yaw-cancel “stabilizer” motors spinning.
function drive.forceStopAllThrusters(control)
    control = control or drive.loadControl()
    if type(control) == "table" and type(control.thrusters) == "table" then
        for _, t in ipairs(control.thrusters) do
            if t.kind ~= "motor" then
                drive.setActuator(control, t, 0)
            end
        end
    end
    local names = collectThrusterMotorNames(control)
    table.sort(names)
    for _, name in ipairs(names) do
        motorDesired[name] = 0
        motorSent[name] = nil
        writeMotorRpm(name, 0)
    end
end

--- Fast stop: calibrated thrusters / queued motors (no network scan).
function drive.hardStopThrusters(control)
    drive.forceStopAllThrusters(control)
end

--- Panic stop for X: same force-stop + clear wrap cache for retries.
function drive.panicStop(control)
    control = control or drive.loadControl()
    if type(control) == "table" and type(control.thrusters) == "table" then
        for _, t in ipairs(control.thrusters) do
            if t.name then
                motorWrapCache[t.name] = nil
            end
        end
    end
    if type(control) == "table" and type(control.unused) == "table" then
        for _, name in ipairs(control.unused) do
            motorWrapCache[name] = nil
        end
    end
    drive.forceStopAllThrusters(control)
end

--- Cap control file RPM fields to the hard max (mutates in-memory config).
-- 24 RPM is per motor. Shared power_budget_rf is off unless enforce_power_budget.
function drive.clampControlRpm(control)
    if type(control) ~= "table" then
        return control
    end
    control.default_motor_rpm = math.min(tonumber(control.default_motor_rpm) or DEFAULT_MAX_RPM, DEFAULT_MAX_RPM)
    if control.fe_per_rpm == nil then
        control.fe_per_rpm = DEFAULT_FE_PER_RPM
    end
    -- Old calibrations wrote power_budget_rf=45 and scaled all motors as one pool —
    -- that was wrong for this boat. Opt in with enforce_power_budget=true.
    if control.enforce_power_budget == true then
        if control.power_budget_rf == nil then
            control.power_budget_rf = DEFAULT_POWER_BUDGET_RF
        end
    else
        control.power_budget_rf = 0
    end
    if type(control.thrusters) == "table" then
        for _, t in ipairs(control.thrusters) do
            t.max_rpm = math.min(tonumber(t.max_rpm) or control.default_motor_rpm, DEFAULT_MAX_RPM)
        end
    end
    return control
end

--- Optional: scale queued motor RPMs so sum(|rpm|)*fe_per_rpm <= power_budget_rf.
-- Disabled unless control.enforce_power_budget and power_budget_rf > 0.
-- Normal limit is DEFAULT_MAX_RPM (24) on each motor individually.
function drive.applyPowerBudget(control)
    control = control or drive.loadControl()
    if not control or control.enforce_power_budget ~= true then
        return false
    end
    local budget = tonumber(control.power_budget_rf)
    if not budget or budget <= 0 then
        return false
    end
    local fePer = tonumber(control.fe_per_rpm) or DEFAULT_FE_PER_RPM
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
        local want = motorDesired[name]
        local isStop = (want or 0) == 0
        -- Stops bypass anti-spam gap so all stabilizer motors zero on release
        if not isStop then
            if (now - lastMotorFlushAt) < MOTOR_FLUSH_GAP and sent == 0 then
                return false
            end
            if sent > 0 and (os.clock() - lastMotorFlushAt) < MOTOR_FLUSH_GAP then
                return false
            end
        end
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
    -- Cost weights (sqrt applied below). Autopilot path — teleop uses applyTeleop.
    local axW = { 1.0, 1.0, 1.0 }
    local dutyDeadband = 0.08
    if math.abs(fy) >= 0.5 and math.abs(fx) + math.abs(tz) < 0.25 then
        -- Strafe: kill CoM yaw couple
        axW = { 2.8, 1.0, 6.0 }
        dutyDeadband = 0.10
    elseif math.abs(fx) >= 0.5 and math.abs(fy) + math.abs(tz) < 0.25 then
        -- Surge: null yaw hard so path-follow doesn't spin
        axW = { 1.0, 2.2, 5.0 }
        dutyDeadband = 0.10
    elseif math.abs(tz) >= 0.5 and math.abs(fx) + math.abs(fy) < 0.25 then
        -- Yaw: allow translation residual (near-CoM thrusters always couple)
        axW = { 0.8, 0.8, 1.0 }
        dutyDeadband = 0.06
    end
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
        if math.abs(duty) < dutyDeadband then
            duty = 0
        end
        drive.setActuator(control, t, duty)
    end

    -- Per-motor RPM only (no shared RF pool scaling)
    if not (math.abs(tz) >= 0.5 and math.abs(fx) + math.abs(fy) < 0.25) then
        drive.applyPowerBudget(control)
    end
    -- After budget, scrub creep RPMs and immediately write every stop
    for name, rpm in pairs(motorDesired) do
        if math.abs(rpm or 0) < 2 then
            motorDesired[name] = 0
            motorSent[name] = nil
        end
    end
    -- Stops first (no anti-spam), then a few thrust writes
    for name, want in pairs(motorDesired) do
        if (want or 0) == 0 then
            writeMotorRpm(name, 0)
        end
    end
    drive.commitMotorsNow()
    return true
end

--- Write every pending motor RPM now (retries once on anti-spam).
-- Never sleeps: filtered sleep drops key/key_up and leaves thrusters stuck after quick taps.
function drive.commitMotorsNow()
    -- Several single flushes; gap is time-based without yielding the event loop away.
    for _ = 1, 12 do
        if drive.flushMotors(1) < 1 then
            break
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

--- Physical side score: +starboard / -port (from calib, not peripheral list order).
function drive.thrusterSide(t)
    if type(t) ~= "table" then
        return 0
    end
    if t.side_score ~= nil then
        return tonumber(t.side_score) or 0
    end
    local fy = tonumber(t.fy) or 0
    if math.abs(fy) >= 0.02 then
        return fy
    end
    local lever = tonumber(t.lever_est)
    if lever and math.abs(lever) >= 0.05 then
        return lever
    end
    -- Forward force on the port side (negative right) yields +tz ≈ -ry*fx
    local fx = tonumber(t.fx) or 0
    local tz = tonumber(t.tz) or 0
    if math.abs(fx) >= 0.02 and math.abs(tz) >= 0.004 then
        return -tz / fx
    end
    if math.abs(tz) >= 0.008 then
        return tz
    end
    return 0
end

--- Side-aware yaw levers when calib tz is too weak (never alternate by name order).
function drive.healYawThrusters(control)
    if not control or type(control.thrusters) ~= "table" then
        return false
    end
    local maxTz, maxFx, maxFy = 0, 0, 0
    for _, t in ipairs(control.thrusters) do
        maxTz = math.max(maxTz, math.abs(t.tz or 0))
        maxFx = math.max(maxFx, math.abs(t.fx or 0))
        maxFy = math.max(maxFy, math.abs(t.fy or 0))
    end
    if maxTz >= 0.02 and maxTz >= math.max(maxFx, maxFy) * 0.12 then
        return false
    end

    local ranked = {}
    for i, t in ipairs(control.thrusters) do
        ranked[#ranked + 1] = { i = i, s = drive.thrusterSide(t), t = t }
    end
    table.sort(ranked, function(a, b)
        if a.s == b.s then
            return a.i < b.i
        end
        return a.s < b.s
    end)

    local n = #ranked
    if n < 2 then
        return false
    end
    local base = math.max(0.25, maxFx, maxFy * 0.5, maxTz)
    local healed = 0
    for idx, row in ipairs(ranked) do
        local t = row.t
        if t.kind == "motor" or math.abs(t.fx or 0) > 0.01 or math.abs(t.fy or 0) > 0.01 then
            -- Left half of sorted sides → negative tz lever, right half → positive
            local sign = (idx <= (n / 2)) and -1 or 1
            if row.s ~= 0 then
                sign = (row.s < 0) and -1 or 1
            end
            t.tz = sign * base * 0.5
            t.side_score = sign
            t.mag = math.sqrt((t.fx or 0) ^ 2 + (t.fy or 0) ^ 2 + (t.tz or 0) ^ 2)
            healed = healed + 1
        end
    end
    return healed > 0
end

--- Teleop mixer: predictable W/S surge, A/D yaw via physical sides (not LS nulling).
-- Pure surge uses fx only (equal push if fx is weak) so W does not invent a turn.
-- Pure yaw uses side levers so A/D always differential-spin even when calib tz is tiny.
function drive.applyTeleop(control, fx, fy, tz)
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

    local sides = {}
    local maxFx, maxFy, maxTz = 0, 0, 0
    for i, t in ipairs(thrusters) do
        sides[i] = drive.thrusterSide(t)
        maxFx = math.max(maxFx, math.abs(t.fx or 0))
        maxFy = math.max(maxFy, math.abs(t.fy or 0))
        maxTz = math.max(maxTz, math.abs(t.tz or 0))
    end
    -- If every side_score is ~0, invent from sorted index so yaw still works
    local anySide = false
    for i = 1, n do
        if math.abs(sides[i]) > 1e-6 then
            anySide = true
            break
        end
    end
    if not anySide then
        local ranked = {}
        for i = 1, n do
            ranked[i] = i
        end
        table.sort(ranked, function(a, b)
            return tostring(thrusters[a].name) < tostring(thrusters[b].name)
        end)
        for idx, i in ipairs(ranked) do
            sides[i] = (idx <= (n / 2)) and -1 or 1
        end
    end

    local scores = {}
    local pureSurge = math.abs(fx) >= 0.5 and math.abs(fy) + math.abs(tz) < 0.25
    local pureYaw = math.abs(tz) >= 0.5 and math.abs(fx) + math.abs(fy) < 0.25
    local pureStrafe = math.abs(fy) >= 0.5 and math.abs(fx) + math.abs(tz) < 0.25

    if pureSurge then
        -- Forward/back only: use calibrated fx. If calib is all-strafe, push every motor equally
        -- (symmetric boat → net surge, not a forced differential turn).
        local useEqual = maxFx < math.max(0.04, maxFy * 0.35, maxTz * 0.35)
        for i, t in ipairs(thrusters) do
            if useEqual then
                scores[i] = fx
            else
                scores[i] = fx * (t.fx or 0)
            end
        end
    elseif pureYaw then
        -- Turn: differential by physical side. Prefer calib tz when it has real authority.
        local useCalibTz = maxTz >= 0.02 and maxTz >= math.max(maxFx, maxFy) * 0.1
        for i, t in ipairs(thrusters) do
            if useCalibTz then
                scores[i] = tz * (t.tz or 0)
            else
                local s = sides[i]
                if math.abs(s) < 1e-6 then
                    s = 1
                end
                scores[i] = tz * ((s >= 0) and 1 or -1)
            end
        end
    elseif pureStrafe then
        local useEqual = maxFy < 0.04
        for i, t in ipairs(thrusters) do
            if useEqual then
                local s = sides[i]
                scores[i] = fy * ((s >= 0) and 1 or -1)
            else
                scores[i] = fy * (t.fy or 0)
            end
        end
    else
        -- Chords: blend surge/strafe/yaw with side-aware yaw lever
        for i, t in ipairs(thrusters) do
            local yawLever = t.tz or 0
            if math.abs(yawLever) < 0.02 then
                local s = sides[i]
                yawLever = ((s >= 0) and 1 or -1) * math.max(0.25, math.abs(t.fx or 0), math.abs(t.fy or 0))
            end
            scores[i] = fx * (t.fx or 0) + fy * (t.fy or 0) + tz * yawLever
        end
    end

    local maxAbs = 0
    for i = 1, n do
        maxAbs = math.max(maxAbs, math.abs(scores[i] or 0))
    end
    if maxAbs < 1e-8 then
        -- Last resort: surge → all equal; yaw → name-split differential
        if math.abs(fx) >= math.abs(fy) and math.abs(fx) >= math.abs(tz) then
            for i = 1, n do
                scores[i] = fx
            end
        else
            for i = 1, n do
                local s = sides[i]
                scores[i] = (tz ~= 0 and tz or fy) * ((s >= 0) and 1 or -1)
            end
        end
        maxAbs = 0
        for i = 1, n do
            maxAbs = math.max(maxAbs, math.abs(scores[i] or 0))
        end
    end
    if maxAbs < 1e-8 then
        drive.hardStopThrusters(control)
        return false
    end

    local scale = math.min(1, cmdMag)
    for i, t in ipairs(thrusters) do
        local duty = ((scores[i] or 0) / maxAbs) * scale
        if math.abs(duty) < 0.08 then
            duty = 0
        end
        drive.setActuator(control, t, duty)
    end

    for name, rpm in pairs(motorDesired) do
        if math.abs(rpm or 0) < 2 then
            motorDesired[name] = 0
            motorSent[name] = nil
        end
    end
    for name, want in pairs(motorDesired) do
        if (want or 0) == 0 then
            writeMotorRpm(name, 0)
        end
    end
    drive.commitMotorsNow()
    return true
end

--- Direct (non-greedy) allocation for teleop — more predictable yaw/strafe.
-- Maps command (-1..1) onto thrusters by wrench projection, then normalizes.
function drive.applyDirect(control, fx, fy, tz)
    return drive.applyTeleop(control, fx, fy, tz)
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
    local held = {}
    local waypoints = {}
    local t0 = os.clock()
    local lastSample = 0
    local stop = false
    local wrenchMode = drive.isWrenchMode(control)
    local lastCmdSig = ""
    local lastIdleBurst = 0

    local YAW_L = { [keys.a] = true, [keys.left] = true, [keys.j] = true }
    local YAW_R = { [keys.d] = true, [keys.right] = true, [keys.l] = true }
    local MOVE = {
        [keys.w] = true, [keys.s] = true,
        [keys.a] = true, [keys.d] = true,
        [keys.z] = true, [keys.c] = true,
        [keys.left] = true, [keys.right] = true,
        [keys.j] = true, [keys.l] = true,
    }

    drive.clampControlRpm(control)
    local healedYaw = wrenchMode and drive.healYawThrusters(control)
    drive.hardStopThrusters(control)

    local nMotor = 0
    if wrenchMode then
        for _, t in ipairs(control.thrusters) do
            if t.kind == "motor" then
                nMotor = nMotor + 1
            end
        end
    end

    print("Manual control (teleop mixer):")
    print("  W/S surge | A/D or arrows or J/L yaw | Z/C strafe")
    print("  X panic-stop | Q quit")
    if wrenchMode then
        print("  Thrusters: " .. #control.thrusters .. " (" .. nMotor .. " motors)")
    end
    if healedYaw then
        print("  (side-aware yaw levers assigned)")
    end
    print()

    local function commandFromKeys()
        local fx = (held[keys.w] and 1 or 0) + (held[keys.s] and -1 or 0)
        local fy = (held[keys.c] and 1 or 0) + (held[keys.z] and -1 or 0)
        local yawL, yawR = false, false
        for k, _ in pairs(YAW_L) do
            if held[k] then
                yawL = true
                break
            end
        end
        for k, _ in pairs(YAW_R) do
            if held[k] then
                yawR = true
                break
            end
        end
        local tz = (yawL and 1 or 0) - (yawR and 1 or 0)
        return { fx = fx, fy = fy, tz = tz }
    end

    local function clearOpposites(key)
        if key == keys.w then
            held[keys.s] = nil
        elseif key == keys.s then
            held[keys.w] = nil
        elseif YAW_L[key] then
            for k, _ in pairs(YAW_R) do
                held[k] = nil
            end
        elseif YAW_R[key] then
            for k, _ in pairs(YAW_L) do
                held[k] = nil
            end
        elseif key == keys.z then
            held[keys.c] = nil
        elseif key == keys.c then
            held[keys.z] = nil
        end
    end

    local function cmdSig(cmd)
        return tostring(cmd.fx) .. "," .. tostring(cmd.fy) .. "," .. tostring(cmd.tz)
    end

    local function applyThrust(force)
        local cmd = commandFromKeys()
        local sig = cmdSig(cmd)
        local idle = cmd.fx == 0 and cmd.fy == 0 and cmd.tz == 0
        if idle then
            drive.forceStopAllThrusters(control)
            lastCmdSig = sig
            lastIdleBurst = os.clock()
            return
        end
        -- Skip identical realloc unless forced (hold reassert / pending flush)
        if not force and sig == lastCmdSig then
            drive.flushMotors(4)
            return
        end
        lastCmdSig = sig
        if wrenchMode then
            -- Teleop mixer: equal/fx surge (no invented turn), side-aware A/D yaw
            drive.applyTeleop(control, cmd.fx, cmd.fy, cmd.tz)
        else
            drive.setAxis(control, "thrust_forward", cmd.fx > 0)
            drive.setAxis(control, "thrust_reverse", cmd.fx < 0)
            drive.setAxis(control, "steer_left", cmd.tz > 0)
            drive.setAxis(control, "steer_right", cmd.tz < 0)
            drive.setAxis(control, "strafe_left", cmd.fy < 0)
            drive.setAxis(control, "strafe_right", cmd.fy > 0)
        end
    end

    while not stop do
        local timerId = os.startTimer(tick)
        while true do
            local ev = { os.pullEventRaw() }
            if ev[1] == "terminate" then
                drive.forceStopAllThrusters(control)
                error("Terminated", 0)
            elseif ev[1] == "key" then
                local key, isRepeat = ev[2], ev[3] and true or false
                if MOVE[key] then
                    if not held[key] then
                        held[key] = true
                        clearOpposites(key)
                        applyThrust(true)
                    elseif isRepeat then
                        -- Same command: only drain pending motor writes (no realloc spam)
                        applyThrust(false)
                    end
                elseif (not isRepeat) and key == quitKey then
                    stop = true
                    break
                elseif (not isRepeat) and key == keys.x then
                    print("Panic stop")
                    held = {}
                    lastCmdSig = ""
                    drive.panicStop(control)
                    lastIdleBurst = os.clock()
                end
            elseif ev[1] == "key_up" then
                local key = ev[2]
                if MOVE[key] and held[key] then
                    held[key] = nil
                    applyThrust(true) -- release → realloc or hard stop
                end
            elseif ev[1] == "timer" and ev[2] == timerId then
                break
            end
        end
        if stop then
            break
        end

        local cmd = commandFromKeys()
        local idle = cmd.fx == 0 and cmd.fy == 0 and cmd.tz == 0
        if idle then
            -- Keep hammering stops while idle (CCA anti-spam / sticky RPM)
            if drive.motorsPending() or (os.clock() - lastIdleBurst) >= 0.2 then
                drive.forceStopAllThrusters(control)
                lastIdleBurst = os.clock()
                lastCmdSig = "0,0,0"
            end
        else
            applyThrust(false)
            drive.flushMotors(4)
        end

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

    held = {}
    drive.forceStopAllThrusters(control)

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
