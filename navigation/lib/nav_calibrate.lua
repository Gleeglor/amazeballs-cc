-- Reassembly-style thruster ID: pulse relays + Create Addition electric motors.
local util = require("util")
local pose = require("pose")
local drive = require("drive")

local calibrate = {}

--- Discover actuators: electric_motor first, then redstone_relay.
-- @return list of { name, kind, max_rpm? }
function calibrate.listActuators(useSides)
    local list = {}
    local names = peripheral.getNames()
    table.sort(names)
    for _, name in ipairs(names) do
        if peripheral.hasType(name, "electric_motor") then
            list[#list + 1] = { name = name, kind = "motor", max_rpm = 24 }
        end
    end
    for _, name in ipairs(names) do
        if peripheral.hasType(name, "redstone_relay") then
            list[#list + 1] = { name = name, kind = "relay" }
        end
    end
    if useSides then
        for _, side in ipairs({ "top", "bottom", "left", "right", "front", "back" }) do
            list[#list + 1] = { name = "side:" .. side, kind = "relay" }
        end
    end
    return list
end

-- back-compat
function calibrate.listRelays(useSides)
    local names = {}
    for _, a in ipairs(calibrate.listActuators(useSides)) do
        if a.kind == "relay" then
            names[#names + 1] = a.name
        end
    end
    return names
end

local function allOff(actuators, control)
    for _, a in ipairs(actuators) do
        drive.setActuator(control, a, 0)
    end
    -- Drain briefly so the next probe starts from a true stop
    drive.stopAllMotors({ drain = true, drain_timeout = 0.4 })
end

local function sampleMotion()
    local craft = pose.get()
    local vel = pose.getVelocity()
    local ang = pose.getAngularVelocity()
    local localV = pose.worldToLocal(vel, craft)
    -- Raw ω·up (see pose.yawRate). Pilot A=left is applied once via yaw_sign.
    local yawRate = pose.yawRate(craft, ang)
    return {
        forward = localV.forward,
        right = localV.right,
        up = localV.up,
        yaw = yawRate,
        craft = craft,
    }
end

local function wrenchMag(w)
    return math.sqrt(w.fx * w.fx + w.fy * w.fy + w.tz * w.tz)
end

--- Steady mid-window wrench while thrusting (default 2.0s pulse, sample 0.5→1.5s).
-- Avoids startup transient and post-pulse spin-down that flipped tz signs.
local function measureActuator(actuator, opts, control, probeRpm)
    opts = opts or {}
    local pulse = opts.pulse or 2.0
    local win0 = opts.window_start or 0.5
    local win1 = opts.window_end or 1.5
    if win1 > pulse then
        win1 = pulse
    end
    if win0 < 0 then
        win0 = 0
    end
    if win0 >= win1 then
        win0, win1 = 0.5, math.min(1.5, pulse)
    end

    allOff({ actuator }, control)
    sleep(0.25)

    if actuator.kind == "motor" then
        drive.setMotorRpmNow(actuator.name, probeRpm or actuator.max_rpm or 24)
    else
        drive.setActuator(control, actuator, 1)
    end

    sleep(win0)
    local before = sampleMotion()
    sleep(math.max(0, win1 - win0))
    local after = sampleMotion()
    sleep(math.max(0, pulse - win1))

    allOff({ actuator }, control)
    local w = {
        fx = after.forward - before.forward,
        fy = after.right - before.right,
        tz = after.yaw - before.yaw,
    }
    w.mag = wrenchMag(w)
    return w
end
function calibrate.describe(w)
    local af, ar, ay = math.abs(w.fx), math.abs(w.fy), math.abs(w.tz)
    local m = math.max(af, ar, ay)
    if m < 1e-6 then
        return "dead"
    end
    if ay >= m * 0.55 and ay >= af * 0.8 and ay >= ar * 0.8 then
        return w.tz > 0 and "mostly yaw+" or "mostly yaw-"
    end
    if ar >= m * 0.55 and ar >= af then
        return w.fy > 0 and "mostly +strafe" or "mostly -strafe"
    end
    if af >= m * 0.55 then
        return w.fx > 0 and "mostly +thrust" or "mostly -thrust"
    end
    return "mixed"
end

--- Cardinal facing from dominant force axis (axis-aligned thrusters).
-- Returns "forward"|"back"|"left"|"right"|"mixed".
function calibrate.classifyFacing(w)
    local fx = tonumber(w.fx) or 0
    local fy = tonumber(w.fy) or 0
    local af, ar = math.abs(fx), math.abs(fy)
    local m = math.max(af, ar)
    if m < 1e-6 then
        return "mixed"
    end
    if af >= ar and af >= m * 0.55 then
        if fx >= 0 then
            return "forward"
        end
        return "back"
    end
    if ar >= af and ar >= m * 0.55 then
        if fy >= 0 then
            return "right"
        end
        return "left"
    end
    return "mixed"
end

--- Relative thrust magnitude for allocation / size (uses horiz force).
function calibrate.facingMagnitude(w)
    local fx = tonumber(w.fx) or 0
    local fy = tonumber(w.fy) or 0
    return math.sqrt(fx * fx + fy * fy)
end

--- Optional: snap force to cardinal unit × magnitude; keep measured tz lever.
-- Do NOT write side_score=0 on forward/back — that blocked thrusterSide tz fallback
-- and made pure-yaw one-sided. Set side from measured tz when known (v8 yaw_sign=-1).
function calibrate.applyFacingLabels(t, yawSign)
    local facing = calibrate.classifyFacing(t)
    t.facing = facing
    t.role = facing
    local mag = calibrate.facingMagnitude(t)
    local ys = tonumber(yawSign) or -1
    if ys == 0 then
        ys = -1
    end
    if facing ~= "mixed" and mag >= 0.02 then
        t.max_force = mag
        if facing == "forward" then
            t.fx, t.fy = mag, 0
        elseif facing == "back" then
            t.fx, t.fy = -mag, 0
        elseif facing == "left" then
            t.fx, t.fy = 0, -mag
            t.side_score = -1
        elseif facing == "right" then
            t.fx, t.fy = 0, mag
            t.side_score = 1
        end
        -- Surge thrusters: side from measured tz in pilot frame.
        -- geometric left+: port → +tz → side=-sign(tz); raw (ys=-1): port → −tz → side=-sign(tz)*ys
        if (facing == "forward" or facing == "back") and math.abs(tonumber(t.tz) or 0) >= 0.004 then
            local tz = tonumber(t.tz) or 0
            t.side_score = -((tz >= 0) and 1 or -1) * ys
        end
        t.mag = math.sqrt((t.fx or 0) ^ 2 + (t.fy or 0) ^ 2 + (t.tz or 0) ^ 2)
    elseif mag >= 0.02 then
        t.max_force = mag
    end
    return t
end

--- Parse CLI / boat-menu args: invert, rpm N, power N, fe N
function calibrate.parseArgs(args)
    args = args or {}
    local opts = {
        invert_analog = false,
        probe_rpm = 24,
        power_budget_rf = 0,
        fe_per_rpm = 1,
    }
    local i = 1
    while i <= #args do
        local a = string.lower(tostring(args[i]))
        if a == "invert" or a == "--invert" or a == "inverted" then
            opts.invert_analog = true
        elseif a == "rpm" or a == "--rpm" then
            i = i + 1
            opts.probe_rpm = tonumber(args[i]) or opts.probe_rpm
        elseif a == "power" or a == "--power" or a == "rf" or a == "fe" then
            i = i + 1
            opts.power_budget_rf = tonumber(args[i]) or opts.power_budget_rf
        elseif a == "fe_per_rpm" or a == "--fe_per_rpm" then
            i = i + 1
            opts.fe_per_rpm = tonumber(args[i]) or opts.fe_per_rpm
        elseif tonumber(a) then
            opts.probe_rpm = tonumber(a)
        end
        i = i + 1
    end
    -- Never probe harder than the boat hard-cap
    if opts.probe_rpm > 24 then
        opts.probe_rpm = 24
    end
    if opts.probe_rpm < 1 then
        opts.probe_rpm = 24
    end
    return opts
end

function calibrate.printReport(control)
    if not control then
        return
    end
    print()
    print("Saved /boat_control.json  (version " .. tostring(control.version)
        .. ", mode=" .. tostring(control.mode)
        .. ", max_rpm/motor=" .. tostring(control.default_motor_rpm)
        .. ", shared_power=" .. tostring(control.power_budget_rf) .. " RF/t)")
    print("Thrusters (" .. #control.thrusters .. "):")
    for _, t in ipairs(control.thrusters) do
        local kind = t.kind or "?"
        print(string.format(
            "  [%s] %s  facing=%s  fx=%.3f fy=%.3f tz=%.3f  [%s]",
            kind,
            t.name,
            tostring(t.facing or t.role or "?"),
            t.fx,
            t.fy,
            t.tz,
            calibrate.describe(t)
        ))
    end
    if control.unused and #control.unused > 0 then
        print("Unused: " .. table.concat(control.unused, ", "))
    end
    print("Motors reverse for strafe/turn when needed; idle = 0 RPM.")
    print("Max " .. tostring(control.default_motor_rpm) .. " RPM per motor (not a shared total).")
end

function calibrate.run(opts)
    opts = opts or {}
    -- 2s thrust; wrench from steady mid-window 0.5→1.5s (not pre/post pulse).
    local pulse = opts.pulse or 2.0
    local settle = opts.settle or 0.8
    local win0 = opts.window_start or 0.5
    local win1 = opts.window_end or 1.5
    local useSides = opts.use_sides == true
    local probeRpm = opts.probe_rpm or 24
    if probeRpm > 24 then
        probeRpm = 24
    end
    local powerBudget = opts.power_budget_rf or 0
    local fePerRpm = opts.fe_per_rpm or 1
    local linFloor = (opts.thresholds and opts.thresholds.linear) or 0.03
    local yawFloor = (opts.thresholds and opts.thresholds.yaw) or 0.008
    local measureOpts = {
        pulse = pulse,
        window_start = win0,
        window_end = win1,
    }
    local prev = drive.loadControl() or {}
    local invert = opts.invert_analog
    if invert == nil then
        invert = prev.invert_analog == true
    end

    local probeControl = { invert_analog = invert }

    print("Calibrate (Reassembly / wrench mode)")
    print("Actuators: Create Addition electric_motor + redstone_relay")
    print("Motors: probes +RPM and -RPM (reverse thrust)")
    print(string.format(
        "Pulse %.2fs; wrench window %.2f→%.2fs while thrusting (steady mid-window).",
        pulse,
        win0,
        win1
    ))
    print("Motion vs CoM → force + torque (no modem GPS needed).")
    print(string.format("Motor probe/max RPM: %s  |  power budget: %s RF/t (≈%s FE per RPM)",
        tostring(probeRpm), tostring(powerBudget), tostring(fePerRpm)))    if invert then
        print("Relay invert ON (motors ignore this — 0 RPM is always off)")
    end
    print("Motor probe RPM: " .. tostring(probeRpm))
    print()

    -- Stop everything first so props aren't stuck "all on"
    print("Stopping all electric motors...")
    drive.stopAllMotors()
    sleep(0.3)

    local actuators = calibrate.listActuators(useSides)
    if #actuators == 0 then
        return nil, "no electric_motor or redstone_relay peripherals found"
    end

    local nMotor, nRelay = 0, 0
    for _, a in ipairs(actuators) do
        if a.kind == "motor" then
            nMotor = nMotor + 1
            a.max_rpm = probeRpm
        else
            nRelay = nRelay + 1
        end
    end
    print(string.format("Found %d motor(s), %d relay(s)", nMotor, nRelay))
    if nMotor > 0 then
        local fair = math.floor(powerBudget / math.max(1, nMotor * fePerRpm))
        print(string.format(
            "Power: %s RF/t shared → ~%s RPM each if all spin together (cap %s)",
            tostring(powerBudget),
            tostring(math.min(probeRpm, math.max(1, fair))),
            tostring(probeRpm)
        ))
    end

    local ok, err = pcall(pose.get)
    if not ok then
        return nil, tostring(err)
    end

    local comOk, com = pcall(sublevel.getCenterOfMass)
    if comOk and com then
        print(string.format("CoM (world): %.2f, %.2f, %.2f", com.x, com.y, com.z))
    end

    allOff(actuators, probeControl)
    sleep(0.2)

    local thrusters = {}
    local unused = {}

    for _, a in ipairs(actuators) do
        print("Probing " .. a.name .. " (" .. a.kind .. ") ...")
        local w

        if a.kind == "motor" then
            print("  +RPM ...")
            local wPlus = measureActuator(a, measureOpts, probeControl, probeRpm)
            print(string.format("    +  fx=%.3f fy=%.3f tz=%.3f", wPlus.fx, wPlus.fy, wPlus.tz))
            sleep(math.max(0.8, settle)) -- let yaw rate die before reverse probe
            print("  -RPM ...")
            local wMinus = measureActuator(a, measureOpts, probeControl, -probeRpm)
            print(string.format("    -  fx=%.3f fy=%.3f tz=%.3f", wMinus.fx, wMinus.fy, wMinus.tz))
            local plusOk = wPlus.mag >= linFloor or math.abs(wPlus.tz) >= yawFloor
            local minusOk = wMinus.mag >= linFloor or math.abs(wMinus.tz) >= yawFloor

            if plusOk and minusOk then
                -- Use +RPM wrench as the +duty map. Averaging with -RPM was
                -- cancelling yaw (tz) when the hull was still spinning from the
                -- forward pulse — that made A/D "do nothing".
                w = {
                    name = a.name,
                    kind = "motor",
                    max_rpm = a.max_rpm or probeRpm,
                    rpm_sign = 1,
                    reversible = true,
                    fx = wPlus.fx,
                    fy = wPlus.fy,
                    tz = wPlus.tz,
                }
                local dot = wPlus.fx * wMinus.fx + wPlus.fy * wMinus.fy + wPlus.tz * wMinus.tz
                local revOk = dot < -0.2 * (wPlus.mag * wMinus.mag + 1e-6)
                print(revOk and "  reverse: OK (opposes forward)" or "  reverse: weak/asymmetric (signed duty still allowed)")
            elseif plusOk then
                w = {
                    name = a.name,
                    kind = "motor",
                    max_rpm = a.max_rpm or probeRpm,
                    rpm_sign = 1,
                    reversible = minusOk,
                    fx = wPlus.fx,
                    fy = wPlus.fy,
                    tz = wPlus.tz,
                }
                print("  reverse: little/no response (check prop/FE)")
            elseif minusOk then
                -- Only reverse RPM pushes — map +duty to -RPM
                w = {
                    name = a.name,
                    kind = "motor",
                    max_rpm = a.max_rpm or probeRpm,
                    rpm_sign = -1,
                    reversible = true,
                    fx = wMinus.fx,
                    fy = wMinus.fy,
                    tz = wMinus.tz,
                }
                print("  only -RPM thrusted; rpm_sign=-1 so +duty uses reverse")
            else
                w = {
                    name = a.name,
                    kind = "motor",
                    max_rpm = a.max_rpm or probeRpm,
                    fx = 0,
                    fy = 0,
                    tz = 0,
                }
            end
            w.mag = wrenchMag(w)
        else
            print("  relay pulse ...")
            w = measureActuator(a, measureOpts, probeControl, probeRpm)
            w.name = a.name
            w.kind = a.kind
        end

        local fHoriz = math.sqrt(w.fx * w.fx + w.fy * w.fy)
        if fHoriz > linFloor then
            w.lever_est = w.tz / fHoriz
        end

        if w.mag < linFloor and math.abs(w.tz) < yawFloor then
            unused[#unused + 1] = a.name
            print(string.format("  -> unused  fx=%.3f fy=%.3f tz=%.3f", w.fx, w.fy, w.tz))
        else
            thrusters[#thrusters + 1] = w
            calibrate.applyFacingLabels(w, -1)
            local lever = w.lever_est and string.format(" lever~%.2f", w.lever_est) or ""
            local rev = w.reversible and " reversible" or ""
            local face = w.facing and (" facing=" .. w.facing) or ""
            print(string.format(
                "  -> thruster [%s]%s fx=%.3f fy=%.3f tz=%.3f%s%s",
                calibrate.describe(w),
                face,
                w.fx,
                w.fy,
                w.tz,
                lever,
                rev
            ))
        end
        sleep(0.15)
    end

    allOff(actuators, probeControl)
    drive.stopAllMotors({ drain = true, drain_timeout = 0.4 })

    if #thrusters == 0 then
        return nil, "no thrusters responded (no FE? props not connected? not on sublevel?)"
    end

    local maxMag = 0
    for _, t in ipairs(thrusters) do
        if t.mag > maxMag then
            maxMag = t.mag
        end
    end
    if maxMag < 1e-6 then
        maxMag = 1
    end

    local control = {
        version = 8,
        mode = "wrench",
        alloc_mode = "reassembly",
        -- Measured tz uses raw ω·up (Minecraft Y-up ≈ CW+/right+). Pilot +tz = A/left
        -- is applied once here — do NOT also negate pose.yawRate (that double-flipped v7).
        -- Set to +1 only if A still turns right after a fresh v8 recalibrate.
        yaw_sign = -1,
        com_compensate = true,
        invert_analog = invert,
        default_motor_rpm = probeRpm,
        power_budget_rf = powerBudget,
        fe_per_rpm = fePerRpm,
        thrusters = thrusters,
        unused = unused,
        weights = { fx = 1.0, fy = 1.0, tz = 1.5 },
        alloc_threshold = 0.08,
        alloc_rounds = 12,
        gains = {
            forward = 1.0,
            strafe = 1.0,
            yaw = 1.0,
            norm = maxMag,
        },
        dock_assist = {
            engage_distance = 20,
            max_speed = 0.2,
            tol_pos = 20,
            tol_yaw_deg = 45,
        },
        feedback = {
            kp_yaw = 1.2,
            kp_lat = 0.8,
            max_trim = 1.0,
        },
        calibrated_at = tostring(util.now()),
        relays = {
            thrust_forward = {},
            thrust_reverse = {},
            strafe_left = {},
            strafe_right = {},
            steer_left = {},
            steer_right = {},
        },
    }

    local wrote, werr = drive.saveControl(control)
    if not wrote then
        return nil, werr
    end
    return control
end

return calibrate
