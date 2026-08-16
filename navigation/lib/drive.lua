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
    local control = drive.clampControlRpm(util.readJSON(CONTROL_PATH))
    return drive.enrichControl(control)
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
-- 24 was too weak for measurable live Δyaw/Δfwd on Aero props; 96 still CCA-safe.
local DEFAULT_MAX_RPM = 96 -- per motor (NOT a shared total across thrusters)
local DEFAULT_POWER_BUDGET_RF = 0 -- 0 = off; shared RF cap is opt-in only
local DEFAULT_FE_PER_RPM = 1 -- CCA-ish: ~1 FE/t per RPM (pack-dependent)
local motorDesired = {}
local motorSent = {}
--- Last duty vector written by apply* / hard-stop (dense 1..n; empty until first apply).
local lastDuties = {}
local motorWrapCache = {}
local lastMotorFlushAt = 0
local MOTOR_FLUSH_GAP = 0.028 -- CCA anti-spam; keep short so first setRPM feels snappy

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
        local zeros = {}
        for i, t in ipairs(control.thrusters) do
            zeros[i] = 0
            if t.kind ~= "motor" then
                drive.setActuator(control, t, 0)
            end
        end
        lastDuties = zeros
    else
        lastDuties = {}
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
-- Normal limit is DEFAULT_MAX_RPM (96) on each motor individually.
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
-- Stops first (bypass anti-spam gap), then largest |RPM| so main surge/yaw leaders fire ASAP.
-- opts.yield_gap: if true, sleep MOTOR_FLUSH_GAP between thrust writes (hold/calibrate drains).
function drive.flushMotors(budget, opts)
    budget = budget or 2
    opts = opts or {}
    local yieldGap = opts.yield_gap and true or false
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
        -- Stops bypass anti-spam gap so release/X feel immediate
        if not isStop then
            if (now - lastMotorFlushAt) < MOTOR_FLUSH_GAP and sent == 0 then
                if yieldGap then
                    sleep(MOTOR_FLUSH_GAP)
                    now = os.clock()
                else
                    return false
                end
            end
            if sent > 0 and (os.clock() - lastMotorFlushAt) < MOTOR_FLUSH_GAP then
                if yieldGap then
                    sleep(MOTOR_FLUSH_GAP)
                    now = os.clock()
                else
                    return false
                end
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
    -- Then largest |RPM| pending (primary surge / yaw leaders before tiny cancel nudges)
    local ranked = {}
    for name, want in pairs(motorDesired) do
        if pending(name) and (want or 0) ~= 0 then
            ranked[#ranked + 1] = { name = name, abs = math.abs(want or 0) }
        end
    end
    table.sort(ranked, function(a, b)
        return a.abs > b.abs
    end)
    for _, row in ipairs(ranked) do
        tryFlush(row.name)
        if sent >= budget then
            return sent
        end
    end
    return sent
end

--- Blocking drain until queue empty or timeout (for hold_apply / calibrate).
function drive.drainMotorsBlocking(timeoutSec)
    timeoutSec = tonumber(timeoutSec) or 1.0
    local t0 = os.clock()
    local writes = 0
    while os.clock() - t0 < timeoutSec do
        if not drive.motorsPending() then
            break
        end
        local n = drive.flushMotors(8, { yield_gap = true })
        writes = writes + (n or 0)
        if (n or 0) < 1 then
            sleep(MOTOR_FLUSH_GAP)
        end
    end
    return writes
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

local function facingToUnit(facing)
    if facing == "forward" or facing == "surge" or facing == "main" then
        return 1, 0
    elseif facing == "back" or facing == "aft" or facing == "reverse" then
        return -1, 0
    elseif facing == "left" or facing == "port" then
        return 0, -1
    elseif facing == "right" or facing == "starboard" or facing == "stbd" then
        return 0, 1
    end
    return nil, nil
end

--- Sign convention: pilot +tz = A / craft-left. boat_control.yaw_sign flips once
-- so measured (raw ω·up) wrenches match that pilot axis.
function drive.getYawSign(control)
    local s = tonumber(control and control.yaw_sign)
    if s and s ~= 0 then
        return (s > 0) and 1 or -1
    end
    return -1
end

function drive.getCom(control)
    control = control or {}
    return {
        x = tonumber(control.com_x or control.comX) or 0,
        y = tonumber(control.com_y or control.comY) or 0,
        z = tonumber(control.com_z or control.comZ) or 0,
    }
end

function drive.netWrench(thrusters, duties)
    local Fx, Fy, Tz = 0, 0, 0
    for i, t in ipairs(thrusters) do
        local d = duties[i] or 0
        if math.abs(d) >= 1e-12 then
            Fx = Fx + d * (t.fx or 0)
            Fy = Fy + d * (t.fy or 0)
            Tz = Tz + d * (t.tz or 0)
        end
    end
    return { fx = Fx, fy = Fy, tz = Tz }
end

--- Yaw mixer authority: prefer calib/geometry tz sign (fixes A-invert on forward thrusters).
function drive.yawAuthority(t, sideFallback)
    local tz = tonumber(t and t.tz) or 0
    if math.abs(tz) >= 0.015 then
        return (tz >= 0) and 1 or -1
    end
    local side = sideFallback or drive.thrusterSide(t)
    if math.abs(side) < 1e-6 then
        return 0
    end
    local facing = t and (t.facing or t.role) or ""
    if facing == "forward" or facing == "surge" or facing == "main" then
        return (side >= 0) and -1 or 1
    elseif facing == "back" or facing == "aft" or facing == "reverse" then
        return (side >= 0) and 1 or -1
    end
    return (side >= 0) and 1 or -1
end

--- Duty-space yaw null for pure surge/strafe (CoM couple cancel).
-- Never drives commanded primary (Fx surge / Fy strafe) below minPrimaryFraction
-- of the pre-null baseline — yaw cancel must not kill forward surge.
-- Tight targets (0.035 / 0.012): older 0.12 / 0.06 left ~10–15° planar yaw on W.
-- opts: cmdFx, cmdFy, minPrimaryFraction, targetRatio, targetAbs, steps
function drive.nullResidualYaw(thrusters, duties, opts)
    opts = opts or {}
    local out = {}
    for i, d in ipairs(duties) do
        out[i] = d or 0
    end
    local maxSteps = math.max(1, tonumber(opts.steps) or 20)
    local targetRatio = tonumber(opts.targetRatio) or 0.035
    local targetAbs = tonumber(opts.targetAbs) or 0.012
    local minFrac = tonumber(opts.minPrimaryFraction) or 0.55
    local cmdFx = tonumber(opts.cmdFx)
    local cmdFy = tonumber(opts.cmdFy)
    local baseline = drive.netWrench(thrusters, out)
    local surgeIntent = false
    if cmdFx and math.abs(cmdFx) >= 0.5 and math.abs(cmdFy or 0) < 0.25 then
        surgeIntent = true
    elseif math.abs(baseline.fx) >= math.abs(baseline.fy) and math.abs(baseline.fx) >= 0.05 then
        surgeIntent = true
    end
    local function primaryOf(w)
        if surgeIntent then
            return w.fx
        end
        return w.fy
    end
    local basePrimary = primaryOf(baseline)
    local minPrimary = 0
    if math.abs(basePrimary) >= 1e-6 then
        minPrimary = (basePrimary >= 0 and 1 or -1) * math.abs(basePrimary) * minFrac
    end
    local lateralCap = math.max(math.abs(basePrimary) * 0.2, 0.1)
    if surgeIntent then
        lateralCap = lateralCap + math.abs(baseline.fy) * 0.5
    else
        lateralCap = lateralCap + math.abs(baseline.fx) * 0.5
    end

    local function isYawHelper(t)
        local f = t.facing or t.role or ""
        return f == "left" or f == "right" or f == "port" or f == "starboard" or f == "stbd"
    end

    for _ = 1, maxSteps do
        local w = drive.netWrench(thrusters, out)
        local primary = math.max(math.abs(primaryOf(w)), 1e-3)
        if math.abs(w.tz) < targetAbs and math.abs(w.tz) / primary < targetRatio then
            break
        end
        local bestI, bestScore, bestDelta = nil, -1e9, 0
        for i, t in ipairs(thrusters) do
            local tz = tonumber(t.tz) or 0
            if math.abs(tz) >= 0.008 then
                local reversible = t.kind == "motor"
                local delta = (-w.tz / tz) * 0.85
                local lo, hi = reversible and -1 or 0, 1
                local nextDuty = util.clamp((out[i] or 0) + delta, lo, hi)
                delta = nextDuty - (out[i] or 0)
                if math.abs(delta) >= 1e-4 then
                    local trial = {}
                    for j = 1, #out do
                        trial[j] = out[j]
                    end
                    trial[i] = nextDuty
                    local tw = drive.netWrench(thrusters, trial)
                    local trialPrimary = primaryOf(tw)
                    local accept = true
                    if math.abs(basePrimary) >= 1e-4 then
                        if (trialPrimary >= 0) ~= (basePrimary >= 0) and math.abs(trialPrimary) > 1e-4 then
                            accept = false
                        elseif math.abs(trialPrimary) + 1e-9 < math.abs(minPrimary) then
                            local p0 = primaryOf(w)
                            local dP = trialPrimary - p0
                            if math.abs(dP) < 1e-9 then
                                accept = false
                            else
                                local need = minPrimary - p0
                                local scale = util.clamp(need / dP, 0, 1)
                                if scale < 0.05 then
                                    accept = false
                                else
                                    delta = delta * scale
                                    trial[i] = util.clamp((out[i] or 0) + delta, lo, hi)
                                    tw = drive.netWrench(thrusters, trial)
                                    if math.abs(primaryOf(tw)) + 1e-9 < math.abs(minPrimary) then
                                        accept = false
                                    end
                                end
                            end
                        end
                    end
                    local lat = surgeIntent and math.abs(tw.fy) or math.abs(tw.fx)
                    if accept and lat > lateralCap + 0.04 then
                        accept = false
                    end
                    if accept then
                        local latPerTz = math.abs(surgeIntent and (t.fy or 0) or (t.fx or 0))
                            / math.max(math.abs(tz), 1e-3)
                        local couple = math.abs(tz)
                            / (0.08 + math.abs(t.fx or 0) * 0.25 + math.abs(t.fy or 0) * 0.5)
                        local tzDrop = math.abs(w.tz) - math.abs(tw.tz)
                        if tzDrop > 1e-6 then
                            local latBleed = surgeIntent and math.abs(tw.fy) or math.abs(tw.fx)
                            local lat0 = surgeIntent and math.abs(w.fy) or math.abs(w.fx)
                            local latIncrease = math.max(0, latBleed - lat0)
                            local primaryKeep = math.abs(primaryOf(tw)) / math.max(math.abs(basePrimary), 1e-3)
                            local helperBias = isYawHelper(t) and 0.35 or 0
                            local score = couple * 0.45
                                + math.max(0, tzDrop) * 6
                                + helperBias
                                - latBleed * 3.2
                                - latIncrease * 4
                                - latPerTz * 0.8
                                + primaryKeep * 0.4
                            if score > bestScore then
                                bestScore = score
                                bestI = i
                                bestDelta = trial[i] - (out[i] or 0)
                            end
                        end
                    end
                end
            end
        end
        if not bestI then
            break
        end
        local prev = out[bestI]
        local t = thrusters[bestI]
        local lo, hi = (t.kind == "motor") and -1 or 0, 1
        out[bestI] = util.clamp((out[bestI] or 0) + bestDelta, lo, hi)
        if math.abs(out[bestI] - prev) < 1e-4 then
            break
        end
    end

    local beforeScrub = drive.netWrench(thrusters, out)
    local scrubbed = {}
    for i = 1, #out do
        scrubbed[i] = (math.abs(out[i] or 0) < 0.08) and 0 or out[i]
    end
    local afterScrub = drive.netWrench(thrusters, scrubbed)
    local primaryOk = math.abs(basePrimary) < 0.1
        or math.abs(primaryOf(afterScrub)) + 1e-9 >= math.abs(minPrimary)
        or math.abs(primaryOf(beforeScrub)) < math.abs(minPrimary) * 0.9
    local tzOk = math.abs(afterScrub.tz) <= math.abs(beforeScrub.tz) + 0.003
    if primaryOk and tzOk then
        for i = 1, #out do
            out[i] = scrubbed[i]
        end
    end
    return out
end

--- Boost surge-facing thrusters when pure-W left almost no Fx (weighted by max_force).
local function ensureSurgeDuties(thrusters, duties, fxCmd, opts)
    opts = opts or {}
    local deadband = opts.deadband or 0.08
    local minFx = opts.minFx or 0.35
    local out = {}
    for i, d in ipairs(duties) do
        out[i] = d or 0
    end
    local w = drive.netWrench(thrusters, out)
    local sign = (fxCmd >= 0) and 1 or -1
    if (w.fx >= 0) == (fxCmd >= 0) and math.abs(w.fx) >= minFx then
        return out
    end
    local scores = {}
    local maxScore = 0
    for i, t in ipairs(thrusters) do
        local facing = t.facing or t.role or ""
        local strength = tonumber(t.max_force) or tonumber(t.strength)
            or math.max(math.abs(t.fx or 0), 0.25)
        local s = 0
        if facing == "forward" or facing == "surge" or facing == "main" then
            s = sign * strength
        elseif facing == "back" or facing == "aft" or facing == "reverse" then
            s = -sign * strength
        elseif math.abs(t.fx or 0) >= 0.05 and math.abs(t.fx or 0) >= math.abs(t.fy or 0) * 0.75 then
            s = sign * (t.fx or 0)
        end
        scores[i] = s
        maxScore = math.max(maxScore, math.abs(s))
    end
    if maxScore < 1e-8 then
        return out
    end
    for i, t in ipairs(thrusters) do
        if math.abs(scores[i] or 0) >= 1e-8 then
            local duty = (scores[i] / maxScore) * math.min(1, math.abs(fxCmd))
            if math.abs(duty) < deadband then
                duty = 0
            end
            local lo = (t.kind == "motor") and -1 or 0
            duty = util.clamp(duty, lo, 1)
            local cur = out[i] or 0
            if not ((duty >= 0) == (cur >= 0) and math.abs(cur) >= math.abs(duty)) then
                out[i] = duty
            end
        end
    end
    w = drive.netWrench(thrusters, out)
    if (w.fx >= 0) ~= (fxCmd >= 0) or math.abs(w.fx) < minFx * 0.5 then
        for i, t in ipairs(thrusters) do
            local facing = t.facing or t.role or ""
            if facing == "forward" or facing == "surge" or facing == "main" then
                out[i] = (t.kind == "motor") and sign or math.max(0, sign)
            elseif facing == "back" or facing == "aft" or facing == "reverse" then
                out[i] = (t.kind == "motor") and -sign or 0
            end
        end
    end
    return out
end

local function ensureStrafeDuties(thrusters, duties, fyCmd, opts)
    opts = opts or {}
    local deadband = opts.deadband or 0.08
    local minFy = opts.minFy or 0.2
    local out = {}
    for i, d in ipairs(duties) do
        out[i] = d or 0
    end
    local w = drive.netWrench(thrusters, out)
    local sign = (fyCmd >= 0) and 1 or -1
    if (w.fy >= 0) == (fyCmd >= 0) and math.abs(w.fy) >= minFy then
        return out
    end
    local scores = {}
    local maxScore = 0
    for i, t in ipairs(thrusters) do
        local facing = t.facing or t.role or ""
        local strength = tonumber(t.max_force) or tonumber(t.strength)
            or math.max(math.abs(t.fy or 0), 0.25)
        local s = 0
        if facing == "right" or facing == "starboard" or facing == "stbd" then
            s = sign * strength
        elseif facing == "left" or facing == "port" then
            s = -sign * strength
        elseif math.abs(t.fy or 0) >= 0.02 then
            s = sign * (t.fy or 0)
        end
        scores[i] = s
        maxScore = math.max(maxScore, math.abs(s))
    end
    if maxScore < 1e-8 then
        return out
    end
    for i, t in ipairs(thrusters) do
        local duty = (scores[i] / maxScore) * math.min(1, math.abs(fyCmd))
        if math.abs(duty) < deadband then
            duty = 0
        end
        local lo = (t.kind == "motor") and -1 or 0
        out[i] = util.clamp(duty, lo, 1)
    end
    return out
end

local function isPureSurge(fx, fy, tz)
    return math.abs(fx) >= 0.5 and math.abs(fy) + math.abs(tz) < 0.25
end
local function isPureStrafe(fx, fy, tz)
    return math.abs(fy) >= 0.5 and math.abs(fx) + math.abs(tz) < 0.25
end
local function isPureYaw(fx, fy, tz)
    return math.abs(tz) >= 0.5 and math.abs(fx) + math.abs(fy) < 0.25
end

--- Pure A/D: ensure both port and starboard contribute (differential), not one side only.
function drive.ensureYawDifferential(thrusters, duties, tzCmd, opts)
    opts = opts or {}
    local deadband = opts.deadband or 0.08
    local sideOpts = { yaw_sign = opts.yaw_sign or -1 }
    if not thrusters or not duties or math.abs(tzCmd or 0) < 0.5 then
        return duties
    end
    local out = {}
    for i, d in ipairs(duties) do
        out[i] = d or 0
    end
    local portIdx, stbdIdx = {}, {}
    local portMax, stbdMax = 0, 0
    for i, t in ipairs(thrusters) do
        local s = drive.thrusterSide(t, sideOpts)
        if s < -0.05 then
            portIdx[#portIdx + 1] = i
            portMax = math.max(portMax, math.abs(out[i]))
        elseif s > 0.05 then
            stbdIdx[#stbdIdx + 1] = i
            stbdMax = math.max(stbdMax, math.abs(out[i]))
        end
    end
    if #portIdx == 0 or #stbdIdx == 0 then
        return out
    end
    if portMax >= deadband and stbdMax >= deadband then
        return out
    end
    local hotMax = math.max(portMax, stbdMax)
    if hotMax < deadband then
        return out
    end
    local cold = (portMax < deadband) and portIdx or stbdIdx
    local bestI, bestContrib = nil, 0
    for _, i in ipairs(cold) do
        local t = thrusters[i]
        local tz = tonumber(t.tz) or 0
        local auth = drive.yawAuthority(t, drive.thrusterSide(t, sideOpts))
        local contrib = math.max(math.abs(tz), math.abs(auth) * 0.35)
        if contrib > bestContrib then
            bestContrib = contrib
            bestI = i
        end
    end
    if not bestI or bestContrib < 1e-6 then
        return out
    end
    local t = thrusters[bestI]
    local tz = tonumber(t.tz) or 0
    local dutySign
    if math.abs(tz) >= 0.015 then
        dutySign = ((tzCmd * tz) >= 0) and 1 or -1
    else
        local auth = drive.yawAuthority(t, drive.thrusterSide(t, sideOpts))
        if auth == 0 then
            return out
        end
        dutySign = ((tzCmd * auth) >= 0) and 1 or -1
    end
    local mag = math.max(deadband, math.min(1, hotMax * 0.9))
    local lo = (t.kind == "motor") and -1 or 0
    out[bestI] = util.clamp(dutySign * mag, lo, 1)
    return out
end

--- Classify cardinal facing from wrench when facing/role missing.
function drive.classifyFacing(t)
    local fx = tonumber(t.fx) or 0
    local fy = tonumber(t.fy) or 0
    local af, ar = math.abs(fx), math.abs(fy)
    local m = math.max(af, ar)
    if m < 1e-6 then
        return "mixed"
    end
    if af >= ar and af >= m * 0.55 then
        return (fx >= 0) and "forward" or "back"
    end
    if ar >= af and ar >= m * 0.55 then
        return (fy >= 0) and "right" or "left"
    end
    return "mixed"
end

--- Rebuild fx/fy/(tz about CoM) from facing × max_force when geometry labels exist.
function drive.syncThrusterFacing(t, control)
    if type(t) ~= "table" then
        return t
    end
    local facing = t.facing or t.role
    if not facing or facing == "mixed" then
        facing = drive.classifyFacing(t)
        if facing ~= "mixed" then
            t.facing = facing
            t.role = facing
        end
    end
    local ux, uy = facingToUnit(facing)
    if not ux then
        return t
    end
    local strength = tonumber(t.max_force) or tonumber(t.strength)
    if not strength or strength < 1e-6 then
        strength = math.sqrt((tonumber(t.fx) or 0) ^ 2 + (tonumber(t.fy) or 0) ^ 2)
        if strength < 1e-6 then
            strength = 0.5
        end
        t.max_force = strength
    end
    t.facing = facing
    t.role = facing
    local prevTz = tonumber(t.tz) or 0
    t.fx = strength * ux
    t.fy = strength * uy
    local lx = tonumber(t.lx) or 0
    local ly = tonumber(t.ly) or 0
    local lz = tonumber(t.lz) or 0
    local hasLever = math.sqrt(lx * lx + ly * ly + lz * lz) >= 1e-4
    if hasLever then
        local com = drive.getCom(control)
        local rx, ry = lx - com.x, ly - com.y
        t.tz = rx * t.fy - ry * t.fx
    else
        t.tz = prevTz
    end
    if facing == "left" then
        t.side_score = -1
    elseif facing == "right" then
        t.side_score = 1
    elseif t.side_score == nil then
        t.side_score = 0
    end
    t.mag = math.sqrt((t.fx or 0) ^ 2 + (t.fy or 0) ^ 2 + (t.tz or 0) ^ 2)
    return t
end

function drive.enrichControl(control)
    if not control or type(control.thrusters) ~= "table" then
        return control
    end
    -- Yaw polarity (single flip — never also negate pose.yawRate):
    --   v8+ fresh calib: raw ω·up tz + yaw_sign=-1 → A=left
    --   v7: pose.yawRate was negated + yaw_sign=+1 (double-flip after recalibrate).
    --       Convert: undo stored negate (tz = -tz) and set yaw_sign=-1.
    --   pre-v7 raw CW+ tables: yaw_sign=-1 until recalibrate
    local ver = tonumber(control.version) or 0
    if control._yaw_migrated ~= true then
        if ver == 7 then
            for _, t in ipairs(control.thrusters) do
                t.tz = -(tonumber(t.tz) or 0)
                if t.mag then
                    t.mag = math.sqrt((t.fx or 0) ^ 2 + (t.fy or 0) ^ 2 + (t.tz or 0) ^ 2)
                end
            end
            control.yaw_sign = -1
            control.version = 8
        elseif ver > 0 and ver < 7 then
            local anyLever = false
            for _, t in ipairs(control.thrusters) do
                local lx = tonumber(t.lx) or 0
                local ly = tonumber(t.ly) or 0
                local lz = tonumber(t.lz) or 0
                if math.sqrt(lx * lx + ly * ly + lz * lz) >= 1e-4 then
                    anyLever = true
                    break
                end
            end
            if not anyLever then
                local ys = tonumber(control.yaw_sign)
                if ys == nil or ys == 0 or ys == 1 then
                    control.yaw_sign = -1
                end
            end
        end
        control._yaw_migrated = true
    end
    if control.yaw_sign == nil then
        -- Default matches v8 Minecraft raw-ω calib (A=left). Sim fixtures that use
        -- pilot-convention / geometric left+ tz should set yaw_sign=1 explicitly.
        control.yaw_sign = -1
    end
    if control.com_compensate == nil then
        control.com_compensate = true
    end
    for _, t in ipairs(control.thrusters) do
        local facing = t.facing or t.role
        if facing and facing ~= "mixed" then
            drive.syncThrusterFacing(t, control)
        elseif not facing then
            facing = drive.classifyFacing(t)
            t.facing = facing
            t.role = facing
            if facing ~= "mixed" and (t.max_force or t.strength) then
                drive.syncThrusterFacing(t, control)
            end
        end
        -- Migrate calib side_score=0 on surge thrusters → infer from tz + yaw_sign
        local ss = tonumber(t.side_score)
        if (ss == nil or math.abs(ss) < 0.05)
            and (t.facing == "forward" or t.facing == "back" or t.role == "forward" or t.role == "back")
            and math.abs(tonumber(t.tz) or 0) >= 0.004
        then
            local tz = tonumber(t.tz) or 0
            local ys = drive.getYawSign(control)
            t.side_score = -((tz >= 0) and 1 or -1) * ys
        end
        -- Weak calib tz (common when pulse is short): synthesize geometric yaw from
        -- side × lateral force so Reassembly/LS can actually allocate A/D.
        local tzAbs = math.abs(tonumber(t.tz) or 0)
        if tzAbs < 0.02 then
            local side = drive.thrusterSide(t, { yaw_sign = drive.getYawSign(control) })
            local fy = tonumber(t.fy) or 0
            local fx = tonumber(t.fx) or 0
            local f = t.facing or t.role or ""
            local synth = 0
            if math.abs(side) >= 0.05 and (f == "left" or f == "right" or f == "port"
                or f == "starboard" or f == "stbd" or math.abs(fy) >= 0.02)
            then
                -- Port (side<0) thrusting +fy (craft-right) → negative pilot tz before yaw_sign
                synth = -side * math.max(math.abs(fy), 0.08)
            elseif math.abs(side) >= 0.05 and math.abs(fx) >= 0.05 then
                synth = -side * math.max(math.abs(fx) * 0.35, 0.05)
            end
            if math.abs(synth) > tzAbs then
                t.tz = synth
                t._tz_synthesized = true
            end
        end
    end
    return control
end

--- Last duty vector written by applyReassembly / teleop / cardinal / hard-stop (or {}).
function drive.getLastDuties()
    local out = {}
    for i, d in ipairs(lastDuties) do
        out[i] = d or 0
    end
    return out
end

--- Snapshot of queued / last-sent motor RPMs (for realtime host tests).
function drive.getMotorSnapshot()
    local desired, sent = {}, {}
    for name, rpm in pairs(motorDesired) do
        desired[name] = rpm
    end
    for name, rpm in pairs(motorSent) do
        sent[name] = rpm
    end
    return { desired = desired, sent = sent }
end

local function readBackDuties(control, scores, maxAbs, scale)
    local duties = {}
    for i, t in ipairs(control.thrusters) do
        local duty = ((scores[i] or 0) / maxAbs) * scale
        if math.abs(duty) < 0.08 then
            duty = 0
        end
        if t.kind ~= "motor" then
            duty = util.clamp(duty, 0, 1)
        else
            duty = util.clamp(duty, -1, 1)
        end
        duties[i] = duty
    end
    return duties
end

local function applyDutiesToActuators(control, duties)
    local anyDuty = false
    for i, t in ipairs(control.thrusters) do
        local duty = duties[i] or 0
        if math.abs(duty) >= 0.08 then
            anyDuty = true
        end
        drive.setActuator(control, t, duty)
    end
    lastDuties = duties
    return anyDuty
end

--- Prefer Reassembly when alloc_mode says so or when facings are present.
function drive.preferReassembly(control)
    if not control then
        return true
    end
    local mode = control.alloc_mode or control.teleop_mode
    if mode == "teleop" or mode == "direct" or mode == "cardinal" or mode == "roles" then
        return false
    end
    if mode == "reassembly" or mode == "wrench_ls" then
        return true
    end
    -- Default: Reassembly when any thruster has a cardinal facing label
    if type(control.thrusters) == "table" then
        for _, t in ipairs(control.thrusters) do
            local f = t.facing or t.role
            if f == "forward" or f == "back" or f == "left" or f == "right" then
                return true
            end
        end
    end
    return true -- Reassembly-like default (sim + tests)
end

function drive.preferCardinal(control)
    if not control then
        return false
    end
    local mode = control.alloc_mode or control.teleop_mode
    return mode == "cardinal" or mode == "roles"
end

--- Facing/role mixer: W uses forward (+), back (−); A/D uses yaw authority; Z/C uses L/R facing.
-- Does not need calibrated tz — fixes A/D dead when Reassembly LS deadbands to 0.
-- Applies CoM duty-space yaw null on pure surge/strafe.
function drive.applyCardinalRoles(control, fx, fy, tz)
    control = control or drive.loadControl()
    if not drive.isWrenchMode(control) then
        return false
    end
    drive.enrichControl(control)

    fx, fy, tz = fx or 0, fy or 0, tz or 0
    tz = tz * drive.getYawSign(control)
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

    local scores = {}
    local anyFacing = false
    for i, t in ipairs(thrusters) do
        local facing = t.facing or t.role or drive.classifyFacing(t)
        if facing and facing ~= "mixed" then
            anyFacing = true
        end
        local strength = tonumber(t.max_force) or tonumber(t.strength)
            or math.max(math.abs(t.fx or 0), math.abs(t.fy or 0), 0.5)
        local surge, strafe = 0, 0
        if facing == "forward" or facing == "surge" or facing == "main" then
            surge = strength
        elseif facing == "back" or facing == "aft" or facing == "reverse" then
            surge = -strength
        end
        if facing == "right" or facing == "starboard" or facing == "stbd" then
            strafe = strength
        elseif facing == "left" or facing == "port" then
            strafe = -strength
        end
        local yawAuth = drive.yawAuthority(t, drive.thrusterSide(t))
        scores[i] = fx * surge + fy * strafe + tz * yawAuth * strength
    end
    if not anyFacing then
        return false
    end

    local maxAbs = 0
    for i = 1, n do
        maxAbs = math.max(maxAbs, math.abs(scores[i] or 0))
    end
    if maxAbs < 1e-8 then
        drive.hardStopThrusters(control)
        return false
    end

    local scale = math.min(1, cmdMag)
    local duties = readBackDuties(control, scores, maxAbs, scale)
    if math.abs(tz) >= 0.5 and math.abs(fx) + math.abs(fy) < 0.25 then
        duties = drive.ensureYawDifferential(thrusters, duties, tz, {
            yaw_sign = drive.getYawSign(control),
        })
    end
    if isPureSurge(fx, fy, 0) or isPureStrafe(fx, fy, 0) then
        if control.com_compensate ~= false then
            duties = drive.nullResidualYaw(thrusters, duties, {
                cmdFx = fx,
                cmdFy = fy,
                minPrimaryFraction = 0.55,
            })
        end
        if isPureSurge(fx, fy, 0) then
            duties = ensureSurgeDuties(thrusters, duties, fx, {})
        end
    end

    local anyDuty = applyDutiesToActuators(control, duties)
    if not anyDuty then
        drive.hardStopThrusters(control)
        return false
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

local function maxThrusterTzAbs(control)
    local m = 0
    if not control or type(control.thrusters) ~= "table" then
        return 0
    end
    for _, t in ipairs(control.thrusters) do
        m = math.max(m, math.abs(tonumber(t.tz) or 0))
    end
    return m
end

--- Allocate command; yaw_sign + CoM cancel; Reassembly → teleop → cardinal roles.
function drive.applyCommand(control, fx, fy, tz)
    control = control or drive.loadControl()
    drive.enrichControl(control)
    fx, fy, tz = fx or 0, fy or 0, tz or 0

    -- Pure A/D with weak calib tz → cardinal differential (Reassembly LS under-yaws).
    local pureYaw = isPureYaw(fx, fy, tz)
    if pureYaw and maxThrusterTzAbs(control) < 0.08 then
        if drive.applyCardinalRoles(control, fx, fy, tz) then
            return true, "cardinal_yaw"
        end
    end

    if drive.preferCardinal(control) then
        if drive.applyCardinalRoles(control, fx, fy, tz) then
            return true, "cardinal"
        end
        return false, "failed"
    end
    if drive.preferReassembly(control) then
        local ok = drive.applyReassembly(control, fx, fy, tz)
        if ok then
            -- If pure yaw but net tz still tiny, override with cardinal differential.
            if pureYaw then
                local duties = drive.getLastDuties()
                local net = drive.netWrench(control.thrusters, duties)
                if math.abs(net.tz or 0) < 0.08 then
                    if drive.applyCardinalRoles(control, fx, fy, tz) then
                        return true, "cardinal_yaw_override"
                    end
                end
            end
            return true, "reassembly"
        end
        if drive.applyTeleop(control, fx, fy, tz) then
            return true, "teleop_fallback"
        end
        if drive.applyCardinalRoles(control, fx, fy, tz) then
            return true, "cardinal_fallback"
        end
        return false, "failed"
    end
    if drive.applyTeleop(control, fx, fy, tz) then
        return true, "teleop"
    end
    if drive.applyCardinalRoles(control, fx, fy, tz) then
        return true, "cardinal_fallback"
    end
    return false, "failed"
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
    drive.enrichControl(control)

    fx, fy, tz = fx or 0, fy or 0, tz or 0
    tz = tz * drive.getYawSign(control)
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
    -- Cost weights (sqrt applied below). Surge-first so yaw-null does not kill Fx.
    local axW = { 1.0, 1.0, 1.0 }
    local dutyDeadband = 0.08
    local absFx, absFy, absTz = math.abs(fx), math.abs(fy), math.abs(tz)
    local pureSurge = absFx >= 0.5 and absFy + absTz < 0.25
    local pureStrafe = absFy >= 0.5 and absFx + absTz < 0.25
    local surgePriority = absFx >= 0.5 and absFx >= absFy and absTz < 0.85
    local strafePriority = absFy >= 0.5 and absFy >= absFx and absTz < 0.85
    if pureStrafe or (strafePriority and not surgePriority) then
        axW = { 2.2, 3.0, 2.5 }
        dutyDeadband = 0.10
    elseif pureSurge or surgePriority then
        -- Fx dominant but enough Tz weight so LS leaves less residual yaw.
        axW = { 3.8, 1.6, 1.6 }
        dutyDeadband = 0.10
    elseif absTz >= 0.5 and absFx + absFy < 0.25 then
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
        if surgePriority or strafePriority then
            -- Clamp instead of rescaling target — keep surge/strafe when saturated.
            for i, t in ipairs(thrusters) do
                local lo = (t.kind == "motor") and -1 or 0
                u[i] = util.clamp(u[i] or 0, lo, 1)
            end
        else
            local u2, m2 = dutiesFor(1.0 / maxAbs)
            if u2 then
                u, maxAbs = u2, m2
            end
        end
    end

    local duties = {}
    local anyDuty = false
    for i, t in ipairs(thrusters) do
        local duty = util.clamp(u[i] or 0, (t.kind == "motor") and -1 or 0, 1)
        if math.abs(duty) < dutyDeadband then
            duty = 0
        end
        duties[i] = duty
        if math.abs(duty) >= dutyDeadband then
            anyDuty = true
        end
    end

    -- LS "succeeded" but every duty deadbanded → fail so applyCommand can fall back
    if not anyDuty then
        return false
    end

    if pureSurge or (surgePriority and absTz < 0.35) then
        duties = ensureSurgeDuties(thrusters, duties, fx, { deadband = dutyDeadband })
    elseif pureStrafe or (strafePriority and absTz < 0.35) then
        duties = ensureStrafeDuties(thrusters, duties, fy, { deadband = dutyDeadband })
    elseif absTz >= 0.5 and absFx + absFy < 0.25 then
        duties = drive.ensureYawDifferential(thrusters, duties, tz, {
            deadband = dutyDeadband,
            yaw_sign = drive.getYawSign(control),
        })
    end

    -- CoM couple polish on pure surge/strafe (protect primary force)
    if control.com_compensate ~= false and (isPureSurge(fx, fy, 0) or isPureStrafe(fx, fy, 0)) then
        duties = drive.nullResidualYaw(thrusters, duties, {
            cmdFx = fx,
            cmdFy = fy,
            minPrimaryFraction = 0.55,
        })
        if isPureSurge(fx, fy, 0) then
            duties = ensureSurgeDuties(thrusters, duties, fx, { deadband = dutyDeadband })
        end
    end

    applyDutiesToActuators(control, duties)

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

--- Write every pending motor RPM now (retries; time-gap only, never sleep).
-- First keypress path: push stops + largest RPM targets before returning to the event loop.
function drive.commitMotorsNow()
    for _ = 1, 16 do
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

--- Physical side score: +starboard / -port (from facing, calib, not name order).
-- opts.yaw_sign: when inferring from measured tz, account for raw ω·up (v8 yaw_sign=-1).
function drive.thrusterSide(t, opts)
    if type(t) ~= "table" then
        return 0
    end
    opts = opts or {}
    local facing = t.facing or t.role
    if facing == "left" or facing == "port" then
        return -1
    elseif facing == "right" or facing == "starboard" or facing == "stbd" then
        return 1
    end
    -- side_score=0 means "unknown" (calib used to write 0 on forward) — keep looking.
    if t.side_score ~= nil then
        local ss = tonumber(t.side_score) or 0
        if math.abs(ss) >= 0.05 then
            return ss
        end
    end
    local ly = tonumber(t.ly) or 0
    if math.abs(ly) >= 0.05 then
        return (ly >= 0) and 1 or -1
    end
    local fy = tonumber(t.fy) or 0
    if math.abs(fy) >= 0.02 then
        return fy
    end
    local lever = tonumber(t.lever_est)
    local ys = tonumber(opts.yaw_sign)
    if not ys or ys == 0 then
        ys = -1 -- v8 raw ω·up default (callers with geometric tables must pass +1)
    end
    if lever and math.abs(lever) >= 0.05 then
        -- lever_est = tz/|F|; convert to port(−)/stbd(+) with yaw_sign
        return lever * ys * -1
    end
    -- Geometric left+ : port fwd → +tz → side = −tz/fx.
    -- Raw ω·up (yaw_sign=-1): measured tz flipped → multiply by yaw_sign.
    local fx = tonumber(t.fx) or 0
    local tz = tonumber(t.tz) or 0
    if math.abs(fx) >= 0.02 and math.abs(tz) >= 0.004 then
        return (-tz / fx) * ys
    end
    if math.abs(tz) >= 0.008 then
        return tz * ys * -1
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
    local sideOpts = { yaw_sign = drive.getYawSign(control) }
    for i, t in ipairs(control.thrusters) do
        ranked[#ranked + 1] = { i = i, s = drive.thrusterSide(t, sideOpts), t = t }
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
    local hasStrafeFacing = false
    for _, t in ipairs(control.thrusters) do
        local f = t.facing or t.role
        if f == "left" or f == "right" or f == "port" or f == "starboard" then
            hasStrafeFacing = true
            break
        end
    end
    for idx, row in ipairs(ranked) do
        local t = row.t
        local facing = t.facing or t.role
        -- Don't invent yaw levers on centerline forward when L/R exist (that made W spin).
        if hasStrafeFacing and (facing == "forward" or facing == "surge" or facing == "main")
            and math.abs(row.s) < 1e-6 then
            -- leave tz as-is
        elseif t.kind == "motor" or math.abs(t.fx or 0) > 0.01 or math.abs(t.fy or 0) > 0.01 then
            local sideSign = (idx <= (n / 2)) and -1 or 1
            if row.s ~= 0 then
                sideSign = (row.s < 0) and -1 or 1
            end
            -- Match τ = −ly·fx so A (+tz) → +Tz (left). Forward: opposite of side.
            local sign = sideSign
            if facing == "forward" or facing == "surge" or facing == "main" then
                sign = -sideSign
            elseif facing == "back" or facing == "aft" or facing == "reverse" then
                sign = sideSign
            end
            t.tz = sign * base * 0.5
            t.side_score = sideSign
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
    tz = tz * drive.getYawSign(control)
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
    local sideOpts = { yaw_sign = drive.getYawSign(control) }
    local maxFx, maxFy, maxTz = 0, 0, 0
    for i, t in ipairs(thrusters) do
        sides[i] = drive.thrusterSide(t, sideOpts)
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
    local pureSurge = isPureSurge(fx, fy, tz)
    local pureYaw = math.abs(tz) >= 0.5 and math.abs(fx) + math.abs(fy) < 0.25
    local pureStrafe = isPureStrafe(fx, fy, tz)

    if pureSurge then
        -- Forward/back only: use calibrated fx. If calib is all-strafe, push weighted by max_force.
        local useEqual = maxFx < math.max(0.04, maxFy * 0.35, maxTz * 0.35)
        for i, t in ipairs(thrusters) do
            if useEqual then
                local strength = tonumber(t.max_force) or tonumber(t.strength) or 1
                scores[i] = fx * strength
            else
                scores[i] = fx * (t.fx or 0)
            end
        end
    elseif pureYaw then
        -- Turn: differential by physical yaw authority. Prefer calib tz when it has real authority.
        local useCalibTz = maxTz >= 0.02 and maxTz >= math.max(maxFx, maxFy) * 0.1
        for i, t in ipairs(thrusters) do
            if useCalibTz then
                scores[i] = tz * (t.tz or 0)
            else
                scores[i] = tz * drive.yawAuthority(t, sides[i])
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
                local auth = drive.yawAuthority(t, sides[i])
                yawLever = auth * math.max(0.25, math.abs(t.fx or 0), math.abs(t.fy or 0))
            end
            scores[i] = fx * (t.fx or 0) + fy * (t.fy or 0) + tz * yawLever
        end
    end

    local maxAbs = 0
    for i = 1, n do
        maxAbs = math.max(maxAbs, math.abs(scores[i] or 0))
    end
    if maxAbs < 1e-8 then
        -- Last resort: surge → all equal; yaw → authority differential
        if math.abs(fx) >= math.abs(fy) and math.abs(fx) >= math.abs(tz) then
            for i = 1, n do
                scores[i] = fx
            end
        else
            for i = 1, n do
                scores[i] = (tz ~= 0 and tz or fy) * drive.yawAuthority(thrusters[i], sides[i])
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
    local duties = readBackDuties(control, scores, maxAbs, scale)
    if pureYaw then
        duties = drive.ensureYawDifferential(thrusters, duties, tz, {
            yaw_sign = drive.getYawSign(control),
        })
    end
    if control.com_compensate ~= false and (pureSurge or pureStrafe) then
        duties = drive.nullResidualYaw(thrusters, duties, {
            cmdFx = fx,
            cmdFy = fy,
            minPrimaryFraction = 0.55,
        })
        if pureSurge then
            duties = ensureSurgeDuties(thrusters, duties, fx, {})
        end
    end
    applyDutiesToActuators(control, duties)

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
    -- pose.yawRate is raw ω·up (MC ≈ right+). Pilot command space is left+ = −raw.
    local rawYaw = pose.yawRate(craft, ang)
    local yawRate = -rawYaw

    local fx = command.fx or 0
    local fy = command.fy or 0
    local tz = command.tz or 0

    -- If pilot/autopilot isn't commanding yaw, kill measured yaw rate (pilot axis)
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
        drive.applyCommand(control, cmd.fx, cmd.fy, cmd.tz)
        drive.flushMotors(4)
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
    local timeout = tonumber(opts.timeout) or 300
    if timeout < 10 then
        timeout = 10
    end
    if timeout > 600 then
        timeout = 600
    end
    local pidStates = drive.newPidStates()
    local i = path.nearestIndex(waypoints)
    local hold = 0
    local t0 = os.clock()

    while true do
        if os.clock() - t0 >= timeout then
            drive.allOff(control)
            return false, "timeout"
        end
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
    drive.enrichControl(control)
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

    local allocLabel = "teleop mixer"
    if wrenchMode and drive.preferCardinal(control) then
        allocLabel = "cardinal roles"
    elseif wrenchMode and drive.preferReassembly(control) then
        allocLabel = "Reassembly LS (+ fallback)"
    end
    print("Manual control (" .. allocLabel .. "):")
    print("  W/S surge | A/D or arrows or J/L yaw | Z/C strafe")
    print("  X panic-stop | Q quit")
    if wrenchMode then
        print("  Thrusters: " .. #control.thrusters .. " (" .. nMotor .. " motors)")
        local facings = {}
        for _, t in ipairs(control.thrusters) do
            facings[#facings + 1] = tostring(t.facing or t.role or "?")
        end
        print("  Facing: " .. table.concat(facings, ", "))
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
            -- Reassembly LS over facing/wrench thrusters; teleop if alloc_mode=teleop
            drive.applyCommand(control, cmd.fx, cmd.fy, cmd.tz)
            -- Extra flush burst on edge (press/release already forced realloc)
            drive.flushMotors(6)
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
