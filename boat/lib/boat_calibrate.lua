-- Auto-calibrate Create Addition motors: +/- RPM gains and max-safe ≤ 24.
local util = require("util")
local pose = require("pose")
local motors = require("motors")

local calibrate = {}

calibrate.CONTROL_PATH = "/boat_control.json"
calibrate.PROBE_RPM = 12
calibrate.PROBE_TIME = 0.55
calibrate.SETTLE = 0.45
calibrate.UNUSED_THRESH = 0.012

local function sampleMotion()
    local craft = pose.get()
    if not craft then
        return nil, "no pose"
    end
    local vel = pose.getVelocity()
    local localV = pose.worldToLocal(vel, craft)
    local yaw = pose.yawRate(craft)
    return {
        forward = localV.forward,
        right = localV.right,
        up = localV.up,
        yaw = yaw,
        craft = craft,
    }
end

local function deltaMotion(a, b)
    return {
        fx = (b.forward or 0) - (a.forward or 0),
        fy = (b.right or 0) - (a.right or 0),
        tz = (b.yaw or 0) - (a.yaw or 0),
    }
end

local function mag3(w)
    return math.sqrt(w.fx * w.fx + w.fy * w.fy + w.tz * w.tz)
end

function calibrate.listMotors()
    return motors.discover()
end

function calibrate.probeMotor(name, rpm, duration)
    rpm = motors.clampRpm(rpm)
    duration = duration or calibrate.PROBE_TIME
    motors.panic(2)
    sleep(calibrate.SETTLE)
    local before = sampleMotion()
    if not before then
        return nil, "no pose"
    end
    motors.setDesired(name, rpm)
    motors.drain(2)
    sleep(duration)
    local after = sampleMotion()
    motors.setDesired(name, 0)
    motors.drain(2)
    sleep(calibrate.SETTLE * 0.5)
    if not after then
        return nil, "no pose after"
    end
    return deltaMotion(before, after)
end

function calibrate.maxSafeRpm(name, sign)
    sign = sign >= 0 and 1 or -1
    local best = calibrate.PROBE_RPM
    local prevAccel = nil
    for rpm = 6, motors.MAX_RPM, 6 do
        local signed = sign * rpm
        motors.panic(1)
        sleep(0.25)
        local before = sampleMotion()
        if not before then
            break
        end
        motors.setDesired(name, signed)
        motors.drain(2)
        sleep(0.4)
        local m = peripheral.wrap(name)
        local actual = signed
        if m and m.getSpeed then
            local ok, s = pcall(m.getSpeed)
            if ok and type(s) == "number" then
                actual = s
            end
        end
        local after = sampleMotion()
        motors.setDesired(name, 0)
        motors.drain(2)
        if not after then
            break
        end
        local slip = math.abs(math.abs(actual) - rpm)
        if slip > 4 then
            break
        end
        if m and m.getEnergyConsumption and m.getMaxInsert then
            local ok1, use = pcall(m.getEnergyConsumption)
            local ok2, cap = pcall(m.getMaxInsert)
            if ok1 and ok2 and type(use) == "number" and type(cap) == "number" and cap > 0 and use > cap * 0.95 then
                break
            end
        end
        local d = deltaMotion(before, after)
        local accel = mag3(d)
        if prevAccel and accel < prevAccel * 0.55 and rpm > 12 then
            break
        end
        prevAccel = accel
        best = rpm
    end
    return math.min(best, motors.MAX_RPM)
end

function calibrate.run(opts)
    opts = opts or {}
    local names = calibrate.listMotors()
    if #names == 0 then
        return nil, "no electric_motor peripherals"
    end
    local thrusters = {}
    local unused = {}
    print("Calibrating " .. #names .. " motors (cap ±" .. motors.MAX_RPM .. " RPM)...")
    for _, name in ipairs(names) do
        write("  " .. name .. " + ... ")
        local pos, err = calibrate.probeMotor(name, calibrate.PROBE_RPM)
        if not pos then
            print("FAIL " .. tostring(err))
            unused[#unused + 1] = name
        else
            print(string.format("fx=%.3f fy=%.3f tz=%.3f", pos.fx, pos.fy, pos.tz))
            write("  " .. name .. " - ... ")
            local neg, err2 = calibrate.probeMotor(name, -calibrate.PROBE_RPM)
            if not neg then
                print("FAIL " .. tostring(err2))
                unused[#unused + 1] = name
            else
                print(string.format("fx=%.3f fy=%.3f tz=%.3f", neg.fx, neg.fy, neg.tz))
                local mpos = mag3(pos)
                local mneg = mag3(neg)
                if mpos < calibrate.UNUSED_THRESH and mneg < calibrate.UNUSED_THRESH then
                    unused[#unused + 1] = name
                    print("  unused (no motion)")
                else
                    local maxPos = motors.MAX_RPM
                    local maxNeg = motors.MAX_RPM
                    if opts.ramp ~= false then
                        write("  max+ ... ")
                        maxPos = calibrate.maxSafeRpm(name, 1)
                        print(maxPos)
                        write("  max- ... ")
                        maxNeg = calibrate.maxSafeRpm(name, -1)
                        print(maxNeg)
                    end
                    -- Normalize gains to unit duty at probe RPM so wrench sees comparable columns
                    local scale = motors.MAX_RPM / calibrate.PROBE_RPM
                    thrusters[#thrusters + 1] = {
                        name = name,
                        kind = "motor",
                        fx_pos = pos.fx * scale,
                        fy_pos = pos.fy * scale,
                        tz_pos = pos.tz * scale,
                        fx_neg = neg.fx * scale,
                        fy_neg = neg.fy * scale,
                        tz_neg = neg.tz * scale,
                        max_rpm_pos = maxPos,
                        max_rpm_neg = maxNeg,
                    }
                end
            end
        end
    end

    local control = {
        version = 2,
        max_rpm = motors.MAX_RPM,
        yaw_sign = -1, -- A = turn port; flip to 1 in /boat_control.json if still inverted after recalib
        thrusters = thrusters,
        unused = unused,
        calibrated_at = tostring(os.epoch and os.epoch("utc") or os.clock()),
    }
    util.writeJSON(calibrate.CONTROL_PATH, control)
    print("Wrote " .. calibrate.CONTROL_PATH .. " (" .. #thrusters .. " thrusters)")
    return control
end

function calibrate.load()
    return util.readJSON(calibrate.CONTROL_PATH)
end

return calibrate
