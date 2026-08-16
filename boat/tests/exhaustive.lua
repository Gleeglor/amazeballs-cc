-- Exhaustive in-game boat tests. Returns structured results; fails loud.
-- Run via agent RPC run_tests suite=exhaustive, or: tests/exhaustive
-- Avoid touching `package` at load time — agent exec may use a sandbox without it.

local function reload(name)
    if type(package) == "table" and type(package.loaded) == "table" then
        package.loaded[name] = nil
    end
end

if type(package) == "table" and type(package.path) == "string" then
    package.path = "/lib/?.lua;/lib/?/init.lua;/tests/?.lua;./lib/?.lua;" .. package.path
end

for _, name in ipairs({
    "motors",
    "pose",
    "teleop",
    "wrench",
    "boat_calibrate",
    "util",
    "dock",
}) do
    reload(name)
end

local motors = require("motors")
local pose = require("pose")
local teleop = require("teleop")
local wrench = require("wrench")
local calibrate = require("boat_calibrate")
local dock = require("dock")

local M = {}

local function now()
    if os.epoch then
        return os.epoch("utc") / 1000
    end
    return os.clock()
end

local function sign(x)
    x = tonumber(x) or 0
    if x > 0 then
        return 1
    end
    if x < 0 then
        return -1
    end
    return 0
end

local function maxAbs(map)
    local m = 0
    for _, v in pairs(map or {}) do
        local a = math.abs(tonumber(v) or 0)
        if a > m then
            m = a
        end
    end
    return m
end

local function allSpeedsNearZero(names, tol)
    tol = tol or 1
    local speeds = {}
    local bad = {}
    for _, n in ipairs(names) do
        local s = motors.readActualSpeed(n)
        speeds[n] = s
        if s ~= nil and math.abs(s) > tol then
            bad[#bad + 1] = n .. "=" .. tostring(s)
        end
    end
    return #bad == 0, speeds, bad
end

local function waitSettle(names, timeout)
    timeout = timeout or 2.5
    local t0 = now()
    while now() - t0 < timeout do
        motors.panicNow()
        motors.flush(64)
        local ok = allSpeedsNearZero(names, 1)
        if ok then
            return true
        end
        sleep(0.15)
    end
    return false
end

local function sampleYawRate(duration)
    duration = duration or 0.45
    local t0 = now()
    local sum, n = 0, 0
    while now() - t0 < duration do
        sum = sum + (pose.yawRate() or 0)
        n = n + 1
        sleep(0.05)
    end
    if n == 0 then
        return 0
    end
    return sum / n
end

local function sampleForward(duration)
    duration = duration or 0.45
    local t0 = now()
    local sum, n = 0, 0
    while now() - t0 < duration do
        local craft = pose.get()
        local fwd = select(1, pose.speed(craft))
        sum = sum + (fwd or 0)
        n = n + 1
        sleep(0.05)
    end
    if n == 0 then
        return 0
    end
    return sum / n
end

local function applyAxes(thrusters, surge, strafe, yaw, hold)
    hold = hold or 0.7
    local byName, mode = teleop.setCommand(surge, strafe, yaw, thrusters)
    motors.flush(32)
    sleep(0.15)
    motors.flush(32)
    local t0 = now()
    local rates, fwds = {}, {}
    while now() - t0 < hold do
        rates[#rates + 1] = pose.yawRate() or 0
        local craft = pose.get()
        fwds[#fwds + 1] = select(1, pose.speed(craft)) or 0
        motors.flush(8)
        sleep(0.05)
    end
    local actual = {}
    for _, t in ipairs(thrusters) do
        actual[t.name] = motors.readActualSpeed(t.name)
    end
    local meanRate, meanFwd = 0, 0
    for _, r in ipairs(rates) do
        meanRate = meanRate + r
    end
    for _, f in ipairs(fwds) do
        meanFwd = meanFwd + f
    end
    if #rates > 0 then
        meanRate = meanRate / #rates
    end
    if #fwds > 0 then
        meanFwd = meanFwd / #fwds
    end
    return {
        duties = byName,
        mode = mode,
        sent = motors.getSentMap(),
        desired = motors.getDesiredMap(),
        actual = actual,
        mean_yaw_rate = meanRate,
        mean_forward = meanFwd,
        max_actual = maxAbs(actual),
        max_duty = maxAbs(byName),
        max_sent = maxAbs(motors.getSentMap()),
    }
end

function M.run(opts)
    opts = opts or {}
    local results = {}
    local function check(name, ok, detail)
        results[#results + 1] = {
            name = name,
            ok = ok and true or false,
            detail = detail,
        }
        local tag = ok and "PASS" or "FAIL"
        print(string.format("[%s] %s %s", tag, name, detail and ("— " .. tostring(detail)) or ""))
        return ok
    end

    motors.resetState()
    motors.panicNow()
    motors.flush(64)

    -- --- static / unit ---
    check("motors.clamp_cap", motors.clampRpm(100) == 24 and motors.clampRpm(-100) == -24)
    check("motors.clamp_int", motors.clampRpm(12.6) == 13 and motors.clampRpm(12.4) == 12)
    check("motors.duty_full", motors.dutyToRpm(1) == 24 and motors.dutyToRpm(-1) == -24)
    check("dock.tolerance", dock.withinTolerance(0.4, 10) and not dock.withinTolerance(0.6, 10))

    local craft = pose.get()
    check("pose.available", craft ~= nil, craft and string.format("xyz=%.1f,%.1f,%.1f", craft.x, craft.y, craft.z) or "nil")
    if craft then
        check("pose.yaw_finite", type(craft.yaw) == "number" and craft.yaw == craft.yaw, tostring(craft.yaw))
        -- Facing anything but exact identity: |yaw| or non-identity forward
        local fx = craft.forward and craft.forward.x or 0
        local fz = craft.forward and craft.forward.z or 0
        local fwdMag = math.sqrt(fx * fx + fz * fz)
        check("pose.forward_unit_hz", fwdMag > 0.9 and fwdMag < 1.1, string.format("mag=%.3f", fwdMag))
        -- Broken quat parse used to force yaw=0 AND forward=(0,0,1) always; allow yaw=0 only if truly facing +Z
        local facingPlusZ = math.abs(fx) < 0.15 and fz > 0.85
        if not facingPlusZ then
            check("pose.yaw_not_stuck_zero", math.abs(craft.yaw) > 0.05, string.format("yaw=%.4f (would be 0 if quat bug)", craft.yaw))
        else
            check("pose.yaw_south_ok", true, "craft facing +Z; yaw≈0 expected")
        end
    end

    local control = calibrate.load()
    check("calib.present", control ~= nil and type(control.thrusters) == "table", control and ("n=" .. #control.thrusters) or "missing /boat_control.json")
    if not control or not control.thrusters or #control.thrusters == 0 then
        motors.panicNow()
        motors.flush(64)
        return { ok = false, results = results, error = "no thrusters — run calibrate" }
    end

    local thrusters = control.thrusters
    local names = {}
    for _, t in ipairs(thrusters) do
        names[#names + 1] = t.name
        motors.register(t.name)
    end
    local yawSign = tonumber(control.yaw_sign) or 1
    local surgeSign = tonumber(control.surge_sign) or -1
    check("calib.yaw_sign", yawSign == 1 or yawSign == -1, tostring(yawSign))
    check("calib.surge_sign", surgeSign == 1 or surgeSign == -1, tostring(surgeSign))

    -- peripherals present
    local missing = {}
    for _, n in ipairs(names) do
        if not peripheral.isPresent(n) then
            missing[#missing + 1] = n
        end
    end
    check("motors.peripherals", #missing == 0, #missing > 0 and table.concat(missing, ",") or "all present")

    waitSettle(names, 2.0)

    -- --- setSpeed write / readback ---
    local probeName = names[1]
    motors.setDesired(probeName, 12)
    motors.flush(16)
    sleep(0.35)
    local got = motors.readActualSpeed(probeName)
    local sent = motors.getSent(probeName)
    check(
        "motors.setSpeed_readback",
        sent == 12 and got ~= nil and math.abs(got) >= 8,
        string.format("sent=%s get=%s", tostring(sent), tostring(got))
    )
    motors.setDesired(probeName, 0)
    motors.flush(16)
    check("motors.stop_after_probe", waitSettle(names, 2.5), "speeds not zero")

    -- rate-limit: desired stays while sent may lag within FLUSH_GAP
    motors.resetState()
    for _, n in ipairs(names) do
        motors.register(n)
    end
    motors.setDesired(probeName, 8)
    motors.flush(8)
    local sent1 = motors.getSent(probeName)
    motors.setDesired(probeName, 16)
    motors.flush(8)
    local sent2 = motors.getSent(probeName)
    local desired2 = motors.getDesired(probeName)
    check(
        "motors.rate_limit_keeps_desired",
        desired2 == 16 and (sent2 == 8 or sent2 == 16),
        string.format("sent1=%s sent2=%s want=%s", tostring(sent1), tostring(sent2), tostring(desired2))
    )
    waitSettle(names, 2.0)

    -- --- teleop command mapping ---
    local heldA = { [keys.a] = true }
    local heldD = { [keys.d] = true }
    local heldW = { [keys.w] = true }
    local _, _, yawA = teleop.commandFromHeld(heldA, yawSign, surgeSign)
    local _, _, yawD = teleop.commandFromHeld(heldD, yawSign, surgeSign)
    local surgeW = teleop.commandFromHeld(heldW, yawSign, surgeSign)
    check("teleop.A_D_opposite", sign(yawA) ~= 0 and sign(yawA) == -sign(yawD), string.format("A=%s D=%s", yawA, yawD))
    check("teleop.W_surge", math.abs(surgeW) == 1, tostring(surgeW))

    -- hold timeout constants
    check("teleop.hold_timeout_ge_1", (teleop.HOLD_TIMEOUT or 0) >= 0.99, tostring(teleop.HOLD_TIMEOUT))

    -- session begin/sync/stop (no blocking run)
    local session, err = teleop.begin()
    check("teleop.begin", session ~= nil, err)
    if session then
        session.held[keys.w] = true
        session.seen[keys.w] = now()
        teleop.sync(session, true)
        check("teleop.sync_W_duties", maxAbs(session.duties) > 0.05 or session.mixMode == "fallback", session.mixMode)
        -- simulate OS delay without key_up
        sleep(0.4)
        local expired = false
        -- expire only via onEvent timer path — call expire by faking old seen beyond timeout
        local oldSeen = session.seen[keys.w]
        session.seen[keys.w] = now() - 0.4
        -- should NOT expire at 0.4s (timeout 1.0)
        local tfake = now()
        local still = true
        for k, on in pairs(session.held) do
            if on and (tfake - (session.seen[k] or 0)) > teleop.HOLD_TIMEOUT then
                still = false
            end
        end
        check("teleop.hold_survives_0.4s", still and session.held[keys.w], "would stutter if timeout<0.5")
        session.seen[keys.w] = now() - 1.1
        local t2 = now()
        local shouldExpire = (t2 - (session.seen[keys.w] or 0)) > teleop.HOLD_TIMEOUT
        check("teleop.hold_expires_1.1s", shouldExpire, "safety timeout")
        teleop.stop(session)
    end
    waitSettle(names, 2.0)

    -- --- live dynamics: A then D ---
    -- Physics convention: commanded yaw sign should match measured yaw_rate sign.
    -- If this fails, yaw_sign in /boat_control.json is wrong (flip 1 ↔ -1).
    local aCmd = yawA
    local dCmd = yawD
    local aRes = applyAxes(thrusters, 0, 0, aCmd, 0.85)
    check(
        "live.A_motors_spin",
        aRes.max_actual >= 4 or aRes.max_sent >= 4,
        string.format("max_actual=%.1f max_sent=%.1f mode=%s", aRes.max_actual, aRes.max_sent, tostring(aRes.mode))
    )
    check(
        "live.A_yaw_rate_sign",
        sign(aRes.mean_yaw_rate) ~= 0 and sign(aRes.mean_yaw_rate) == sign(aCmd),
        string.format("cmd=%s rate=%.4f (flip yaw_sign if wrong)", aCmd, aRes.mean_yaw_rate)
    )
    waitSettle(names, 2.5)

    local dRes = applyAxes(thrusters, 0, 0, dCmd, 0.85)
    check(
        "live.D_motors_spin",
        dRes.max_actual >= 4 or dRes.max_sent >= 4,
        string.format("max_actual=%.1f mode=%s", dRes.max_actual, tostring(dRes.mode))
    )
    check(
        "live.D_yaw_rate_sign",
        sign(dRes.mean_yaw_rate) ~= 0 and sign(dRes.mean_yaw_rate) == sign(dCmd),
        string.format("cmd=%s rate=%.4f", dCmd, dRes.mean_yaw_rate)
    )
    check(
        "live.A_D_rates_opposite",
        sign(aRes.mean_yaw_rate) == -sign(dRes.mean_yaw_rate),
        string.format("A_rate=%.4f D_rate=%.4f", aRes.mean_yaw_rate, dRes.mean_yaw_rate)
    )
    waitSettle(names, 2.5)

    -- --- W surge (use signed command from teleop mapping) ---
    local baseline = sampleForward(0.3)
    local wCmd = surgeW
    local wRes = applyAxes(thrusters, wCmd, 0, 0, 1.0)
    check(
        "live.W_motors_spin",
        wRes.max_actual >= 4 or wRes.max_sent >= 4,
        string.format("max_actual=%.1f mode=%s duties=%.2f", wRes.max_actual, tostring(wRes.mode), wRes.max_duty)
    )
    check(
        "live.W_forward_increases",
        sign(wRes.mean_forward - baseline) == sign(wCmd)
            or (sign(wCmd) ~= 0 and sign(wRes.mean_forward) == sign(wCmd) and math.abs(wRes.mean_forward) > 0.05),
        string.format(
            "baseline=%.3f during=%.3f cmd=%s (flip surge_sign if W goes backward)",
            baseline,
            wRes.mean_forward,
            tostring(wCmd)
        )
    )
    waitSettle(names, 3.0)
    local zeroOk, speeds, bad = allSpeedsNearZero(names, 1)
    check("live.release_all_zero", zeroOk, bad and table.concat(bad, ",") or "ok")

    -- wrench pure surge not all zero (or fallback kicks in)
    local duties = wrench.fromAxes(thrusters, 1, 0, 0)
    local byName = wrench.dutiesByName(thrusters, duties)
    local mixMag = maxAbs(byName)
    local fb = teleop.fallbackDuties(thrusters, 1, 0, 0)
    check(
        "wrench.or_fallback_surge",
        mixMag > 0.05 or maxAbs(fb) > 0.05,
        string.format("mix=%.3f fallback=%.3f", mixMag, maxAbs(fb))
    )

    motors.panicNow()
    motors.flush(64)

    local failed = 0
    for _, r in ipairs(results) do
        if not r.ok then
            failed = failed + 1
        end
    end
    local summary = {
        ok = failed == 0,
        passed = #results - failed,
        failed = failed,
        total = #results,
        yaw_sign = yawSign,
        surge_sign = surgeSign,
        results = results,
        samples = {
            A = { rate = aRes.mean_yaw_rate, cmd = aCmd },
            D = { rate = dRes.mean_yaw_rate, cmd = dCmd },
            W = { forward = wRes.mean_forward, baseline = baseline, cmd = wCmd },
        },
    }
    print(string.format("exhaustive: %d/%d passed", summary.passed, summary.total))
    return summary
end

-- CLI when run as a program (shell.run / updater dest)
local prog = shell and shell.getRunningProgram and shell.getRunningProgram()
if prog and tostring(prog):find("exhaustive") then
    local ok, summary = pcall(M.run, {})
    if not ok then
        print("exhaustive CRASH: " .. tostring(summary))
        error(tostring(summary), 0)
    end
    if textutils and textutils.serialiseJSON then
        print(textutils.serialiseJSON({
            ok = summary.ok,
            passed = summary.passed,
            failed = summary.failed,
            total = summary.total,
        }))
    end
    if not summary.ok then
        error("exhaustive FAILED", 0)
    end
end

return M
