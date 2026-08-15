-- Reassembly-style thruster ID: pulse each relay, store force/torque wrench.
-- Modems do NOT expose block position in CC — we infer effect from motion vs CoM.
local util = require("util")
local pose = require("pose")
local drive = require("drive")

local calibrate = {}

local function setRelay(name, on)
    if not peripheral.isPresent(name) then
        return false
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

function calibrate.listRelays(useSides)
    local names = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "redstone_relay") then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    if useSides then
        for _, side in ipairs({ "top", "bottom", "left", "right", "front", "back" }) do
            names[#names + 1] = "side:" .. side
        end
    end
    return names
end

local function allOff(names)
    for _, name in ipairs(names) do
        if string.sub(name, 1, 5) ~= "side:" then
            setRelay(name, false)
        else
            rs.setAnalogOutput(string.sub(name, 6), 0)
        end
    end
end

local function pulseOne(name, duration)
    if string.sub(name, 1, 5) == "side:" then
        local side = string.sub(name, 6)
        rs.setAnalogOutput(side, 15)
        sleep(duration)
        rs.setAnalogOutput(side, 0)
    else
        setRelay(name, true)
        sleep(duration)
        setRelay(name, false)
    end
end

local function sampleMotion()
    local craft = pose.get()
    local vel = pose.getVelocity()
    local ang = pose.getAngularVelocity()
    local localV = pose.worldToLocal(vel, craft)
    local yawRate = ang.x * craft.up.x + ang.y * craft.up.y + ang.z * craft.up.z
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

--- Describe dominant role for humans (not used for control).
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

function calibrate.run(opts)
    opts = opts or {}
    local pulse = opts.pulse or 0.6
    local settle = opts.settle or 0.35
    local useSides = opts.use_sides == true
    local linFloor = (opts.thresholds and opts.thresholds.linear) or 0.05
    local yawFloor = (opts.thresholds and opts.thresholds.yaw) or 0.03

    print("Calibrate (Reassembly / wrench mode)")
    print("Each relay = one thruster. Motion vs CoM → force + torque.")
    print("(Modems cannot report block position; we measure effect instead.)")
    print()

    local names = calibrate.listRelays(useSides)
    if #names == 0 then
        return nil, "no redstone_relay peripherals found"
    end
    print("Found " .. #names .. " candidates")

    local ok, err = pcall(pose.get)
    if not ok then
        return nil, tostring(err)
    end

    local comOk, com = pcall(sublevel.getCenterOfMass)
    if comOk and com then
        print(string.format("CoM (world): %.2f, %.2f, %.2f", com.x, com.y, com.z))
    end

    allOff(names)
    sleep(0.2)

    local thrusters = {}
    local unused = {}

    for _, name in ipairs(names) do
        print("Probing " .. name .. " ...")
        allOff(names)
        sleep(settle)
        local before = sampleMotion()
        pulseOne(name, pulse)
        sleep(settle)
        local after = sampleMotion()
        allOff(names)

        -- Wrench proxy: Δv_local ≈ force direction; Δω_yaw ≈ torque about CoM
        local w = {
            name = name,
            fx = after.forward - before.forward,
            fy = after.right - before.right,
            tz = after.yaw - before.yaw,
        }
        w.mag = wrenchMag(w)

        -- Rough lever-arm hint (blocks-ish): τ ≈ r × F → r_perp ≈ tz / |F_horiz|
        local fHoriz = math.sqrt(w.fx * w.fx + w.fy * w.fy)
        if fHoriz > linFloor then
            w.lever_est = w.tz / fHoriz
        else
            w.lever_est = nil
        end

        local role = calibrate.describe(w)
        if w.mag < linFloor and math.abs(w.tz) < yawFloor then
            unused[#unused + 1] = name
            print(string.format("  -> unused  fx=%.3f fy=%.3f tz=%.3f", w.fx, w.fy, w.tz))
        else
            thrusters[#thrusters + 1] = w
            local lever = w.lever_est and string.format(" lever~%.2f", w.lever_est) or ""
            print(string.format(
                "  -> thruster [%s] fx=%.3f fy=%.3f tz=%.3f%s",
                role,
                w.fx,
                w.fy,
                w.tz,
                lever
            ))
        end
        sleep(0.15)
    end

    allOff(names)

    if #thrusters == 0 then
        return nil, "no thrusters responded (props dry / no RPM / clutches open?)"
    end

    -- Normalize scores so allocation is scale-stable across craft masses
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
        version = 2,
        mode = "wrench",
        thrusters = thrusters,
        unused = unused,
        -- Prefer yaw a bit so turn commands aren't drowned by big main thrusters
        weights = { fx = 1.0, fy = 1.0, tz = 1.4 },
        alloc_threshold = 0.12,
        alloc_rounds = 8,
        gains = {
            forward = 1.0,
            strafe = 1.0,
            yaw = 1.0,
            norm = maxMag,
        },
        dock_assist = {
            engage_distance = 12,
            max_speed = 0.35,
            tol_pos = 0.35,
            tol_yaw_deg = 5,
        },
        feedback = {
            kp_yaw = 1.2,
            kp_lat = 0.8,
            max_trim = 1.0,
        },
        calibrated_at = tostring(util.now()),
        -- legacy empty map so old code paths no-op cleanly
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
