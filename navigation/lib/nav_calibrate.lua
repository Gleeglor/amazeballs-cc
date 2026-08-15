-- Auto-discover redstone_relay peripherals and classify by craft motion.
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
            local side = string.sub(name, 6)
            rs.setAnalogOutput(side, 0)
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
    -- yaw rate: angular velocity about craft up
    local yawRate = ang.x * craft.up.x + ang.y * craft.up.y + ang.z * craft.up.z
    return {
        forward = localV.forward,
        right = localV.right,
        up = localV.up,
        yaw = yawRate,
        craft = craft,
    }
end

--- Classify a single probe result into an axis label.
function calibrate.classify(delta, thresholds)
    thresholds = thresholds or {}
    local lin = thresholds.linear or 0.08
    local yaw = thresholds.yaw or 0.05
    local ratio = thresholds.mix_ratio or 0.55

    local af = math.abs(delta.forward)
    local ar = math.abs(delta.right)
    local ay = math.abs(delta.yaw)
    local maxLin = math.max(af, ar)

    if maxLin < lin and ay < yaw then
        return "unused", delta
    end

    -- Ambiguous if strong linear and strong yaw both significant
    if maxLin >= lin and ay >= yaw and math.min(maxLin, ay) / math.max(maxLin, ay, 1e-6) > ratio then
        return "ambiguous", delta
    end

    if ay >= yaw and ay >= maxLin * 0.9 then
        if delta.yaw > 0 then
            return "steer_left", delta
        else
            return "steer_right", delta
        end
    end

    if ar >= af and ar >= lin then
        if delta.right > 0 then
            return "strafe_right", delta
        else
            return "strafe_left", delta
        end
    end

    if af >= lin then
        if delta.forward > 0 then
            return "thrust_forward", delta
        else
            return "thrust_reverse", delta
        end
    end

    if ay >= yaw then
        if delta.yaw > 0 then
            return "steer_left", delta
        else
            return "steer_right", delta
        end
    end

    return "unused", delta
end

function calibrate.run(opts)
    opts = opts or {}
    local pulse = opts.pulse or 0.6
    local settle = opts.settle or 0.35
    local useSides = opts.use_sides == true

    print("Calibrate: scanning redstone_relay peripherals...")
    local names = calibrate.listRelays(useSides)
    if #names == 0 then
        return nil, "no redstone_relay peripherals found"
    end
    print("Found " .. #names .. " candidates")

    -- Ensure we can read pose
    local ok, err = pcall(pose.get)
    if not ok then
        return nil, tostring(err)
    end

    allOff(names)
    sleep(0.2)

    local relays = {
        thrust_forward = {},
        thrust_reverse = {},
        strafe_left = {},
        strafe_right = {},
        steer_left = {},
        steer_right = {},
    }
    local unused = {}
    local ambiguous = {}
    local gainsAcc = { forward = {}, strafe = {}, yaw = {} }

    for _, name in ipairs(names) do
        print("Probing " .. name .. " ...")
        allOff(names)
        sleep(settle)
        local before = sampleMotion()
        pulseOne(name, pulse)
        sleep(settle)
        local after = sampleMotion()
        allOff(names)

        local delta = {
            forward = after.forward - before.forward,
            right = after.right - before.right,
            up = after.up - before.up,
            yaw = after.yaw - before.yaw,
        }
        local label = calibrate.classify(delta, opts.thresholds)
        print(string.format(
            "  -> %s  df=%.3f dr=%.3f dyaw=%.3f",
            label,
            delta.forward,
            delta.right,
            delta.yaw
        ))

        if label == "unused" then
            unused[#unused + 1] = name
        elseif label == "ambiguous" then
            ambiguous[#ambiguous + 1] = name
        else
            relays[label][#relays[label] + 1] = name
            if label == "thrust_forward" or label == "thrust_reverse" then
                gainsAcc.forward[#gainsAcc.forward + 1] = math.abs(delta.forward)
            elseif label == "strafe_left" or label == "strafe_right" then
                gainsAcc.strafe[#gainsAcc.strafe + 1] = math.abs(delta.right)
            elseif label == "steer_left" or label == "steer_right" then
                gainsAcc.yaw[#gainsAcc.yaw + 1] = math.abs(delta.yaw)
            end
        end
        sleep(0.15)
    end

    allOff(names)

    local function avg(t)
        if #t == 0 then
            return 1.0
        end
        local s = 0
        for _, v in ipairs(t) do
            s = s + v
        end
        return s / #t
    end

    local control = {
        version = 1,
        relays = relays,
        unused = unused,
        ambiguous = ambiguous,
        gains = {
            forward = util.clamp(avg(gainsAcc.forward), 0.2, 3.0),
            strafe = util.clamp(avg(gainsAcc.strafe), 0.2, 3.0),
            yaw = util.clamp(avg(gainsAcc.yaw), 0.2, 3.0),
        },
        dock_assist = {
            engage_distance = 12,
            max_speed = 0.35,
            tol_pos = 0.35,
            tol_yaw_deg = 5,
        },
        calibrated_at = tostring(util.now()),
    }

    local wrote, werr = drive.saveControl(control)
    if not wrote then
        return nil, werr
    end
    return control
end

return calibrate
