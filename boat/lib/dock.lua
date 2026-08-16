-- Precise Simulated docking_connector FSM.
-- Lock when distance ≤ 0.5 and angle ≤ 20°. Cut thrusters on lock.
local util = require("util")
local pose = require("pose")
local motors = require("motors")
local wrench = require("wrench")
local calibrate = require("calibrate")

local dock = {}

dock.MAX_DIST = 0.5
dock.MAX_ANGLE_DEG = 20
dock.CREEP_DUTY = 0.25

local function wrapConnector()
    if not peripheral then
        return nil
    end
    local c = peripheral.find("docking_connector")
    if c then
        return c
    end
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "docking_connector") then
            return peripheral.wrap(name)
        end
    end
    return nil
end

function dock.findConnector()
    return wrapConnector()
end

function dock.isLocked(connector)
    connector = connector or wrapConnector()
    if not connector then
        return false
    end
    if connector.getConnectedName then
        local ok, name = pcall(function()
            return connector.getConnectedName()
        end)
        if ok and type(name) == "string" and name ~= "" then
            return true, name
        end
    end
    return false
end

function dock.withinTolerance(dist, angleDeg)
    dist = tonumber(dist) or 1e9
    angleDeg = tonumber(angleDeg) or 1e9
    return dist <= dock.MAX_DIST and math.abs(angleDeg) <= dock.MAX_ANGLE_DEG
end

--- Compute approach errors to a park pose {x,y,z,yaw} in craft frame.
function dock.poseError(craft, target)
    craft = craft or pose.get()
    if not craft or not target then
        return nil
    end
    local dx = (target.x or 0) - craft.x
    local dz = (target.z or 0) - craft.z
    local eForward = dx * craft.forward.x + dz * craft.forward.z
    local eRight = dx * craft.right.x + dz * craft.right.z
    local targetYaw = tonumber(target.yaw) or craft.yaw
    local eYaw = targetYaw - craft.yaw
    while eYaw > math.pi do
        eYaw = eYaw - 2 * math.pi
    end
    while eYaw < -math.pi do
        eYaw = eYaw + 2 * math.pi
    end
    local dist = math.sqrt(dx * dx + dz * dz)
    local angleDeg = eYaw * 180 / math.pi
    return {
        forward = eForward,
        right = eRight,
        yaw = eYaw,
        yaw_deg = angleDeg,
        dist = dist,
    }
end

function dock.loadControl()
    return calibrate.load()
end

local function applyAxes(surge, strafe, yaw)
    local control = dock.loadControl()
    if not control or not control.thrusters then
        return
    end
    local duties = wrench.fromAxes(control.thrusters, surge, strafe, yaw)
    local byName = wrench.dutiesByName(control.thrusters, duties)
    local thrByName = {}
    for _, t in ipairs(control.thrusters) do
        thrByName[t.name] = t
    end
    -- zero all first
    for _, t in ipairs(control.thrusters) do
        motors.setDesired(t.name, 0)
    end
    motors.applyDuties(byName, thrByName)
    motors.flush(16)
end

--- One dock-assist tick. Returns state string.
function dock.step(target, state)
    state = state or "approach"
    local craft = pose.get()
    if not craft then
        return state, "no pose"
    end
    local err = dock.poseError(craft, target)
    if not err then
        return state, "no err"
    end

    local locked = dock.isLocked()
    if locked then
        motors.panic(3)
        return "locked", "docked"
    end

    if state == "approach" then
        if err.dist < 8 then
            state = "align"
        else
            local yawCmd = util.clamp(err.yaw * 1.2, -1, 1)
            local surge = util.clamp(err.forward * 0.15, -0.6, 0.6)
            applyAxes(surge, 0, yawCmd)
            return state, err
        end
    end

    if state == "align" then
        if math.abs(err.yaw_deg) < 8 and err.dist < 4 then
            state = "creep"
        else
            local yawCmd = util.clamp(err.yaw * 1.5, -1, 1)
            local strafe = util.clamp(err.right * 0.4, -0.5, 0.5)
            local surge = util.clamp(err.forward * 0.2, -0.4, 0.4)
            applyAxes(surge, strafe, yawCmd)
            return state, err
        end
    end

    if state == "creep" then
        if dock.withinTolerance(err.dist, err.yaw_deg) then
            motors.panic(3)
            -- wait for physical lock
            return "wait_lock", err
        end
        local yawCmd = util.clamp(err.yaw * 1.2, -0.5, 0.5)
        local strafe = util.clamp(err.right * 0.5, -dock.CREEP_DUTY, dock.CREEP_DUTY)
        local surge = util.clamp(err.forward * 0.35, -dock.CREEP_DUTY, dock.CREEP_DUTY)
        applyAxes(surge, strafe, yawCmd)
        return state, err
    end

    if state == "wait_lock" then
        motors.panic(2)
        if dock.isLocked() then
            return "locked", err
        end
        if not dock.withinTolerance(err.dist, err.yaw_deg) then
            return "creep", err
        end
        return state, err
    end

    if state == "transfer" then
        motors.panic(1)
        return state, err
    end

    if state == "undock" then
        -- reverse creep away before thrusting hard
        if dock.isLocked() then
            applyAxes(-dock.CREEP_DUTY * 0.5, 0, 0)
            return state, err
        end
        motors.panic(2)
        return "idle", err
    end

    return state, err
end

--- Move items between two inventory peripherals once locked.
function dock.transfer(fromName, toName, limit)
    if not dock.isLocked() then
        return false, "not locked"
    end
    if not peripheral.isPresent(fromName) or not peripheral.isPresent(toName) then
        return false, "missing inventory"
    end
    local from = peripheral.wrap(fromName)
    local to = peripheral.wrap(toName)
    if not from or not to or not from.pushItems then
        return false, "no pushItems"
    end
    limit = limit or 64
    local moved = 0
    local size = from.size and from.size() or 27
    for slot = 1, size do
        if moved >= limit then
            break
        end
        local ok, n = pcall(function()
            return from.pushItems(toName, slot, limit - moved)
        end)
        if ok and type(n) == "number" then
            moved = moved + n
        end
    end
    return true, moved
end

return dock
