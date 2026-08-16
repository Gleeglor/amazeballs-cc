-- Follow A* waypoints with surge/yaw; optical + collision memory.
local util = require("util")
local pose = require("pose")
local motors = require("motors")
local wrench = require("wrench")
local calibrate = require("calibrate")
local route = require("route")
local dock = require("dock")
local ui = require("ui")

local cruise = {}

local function applyAxes(surge, strafe, yaw)
    local control = calibrate.load()
    if not control or not control.thrusters then
        return
    end
    local duties = wrench.fromAxes(control.thrusters, surge, strafe, yaw)
    local byName = wrench.dutiesByName(control.thrusters, duties)
    local thrByName = {}
    for _, t in ipairs(control.thrusters) do
        thrByName[t.name] = t
        motors.setDesired(t.name, 0)
    end
    motors.applyDuties(byName, thrByName)
    motors.flush(16)
    return byName
end

function cruise.followPath(path, opts)
    opts = opts or {}
    local arrive = opts.arrive or 3
    local map = route.loadMap()
    local stuck = 0
    local i = 1
    ui.setMode("route")
    while i <= #path do
        local wp = path[i]
        local craft = pose.get()
        if not craft then
            sleep(0.2)
        else
            route.scanOptical(map, craft, 12)
            local dx = wp.x - craft.x
            local dz = wp.z - craft.z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist < arrive then
                i = i + 1
            else
                local desiredYaw = math.atan2(dx, dz)
                local eYaw = desiredYaw - craft.yaw
                while eYaw > math.pi do
                    eYaw = eYaw - 2 * math.pi
                end
                while eYaw < -math.pi do
                    eYaw = eYaw + 2 * math.pi
                end
                local yawCmd = util.clamp(eYaw * 1.4, -1, 1)
                local surge = 0
                if math.abs(eYaw) < 0.6 then
                    surge = util.clamp(0.35 + dist * 0.02, 0.2, 0.85)
                end
                applyAxes(surge, 0, yawCmd)
                local spd = select(1, pose.speed(craft))
                local remapped
                remapped, stuck = route.observeCollision(map, craft, surge, spd, stuck, 10)
                if remapped then
                    local newPath, err = route.astar(map, craft.x, craft.z, path[#path].x, path[#path].z)
                    if newPath then
                        path = newPath
                        i = 1
                    else
                        print("replan failed: " .. tostring(err))
                    end
                end
                ui.draw({
                    x = craft.x,
                    y = craft.y,
                    z = craft.z,
                    yaw = craft.yaw,
                    speed = spd,
                    thrust = surge,
                    waypoint = string.format("%d/%d", i, #path),
                })
            end
        end
        motors.flush(8)
        sleep(0.1)
    end
    motors.panic(3)
    return true
end

function cruise.goPlace(placeName)
    local craft = pose.get()
    if not craft then
        return false, "no pose"
    end
    local path, err = route.pathToPlace(placeName, craft.x, craft.z)
    if not path then
        return false, err
    end
    cruise.followPath(path)
    local places = route.loadPlaces()
    local p = places.places[placeName]
    if p and p.dock then
        ui.setMode("dock")
        local state = "approach"
        for _ = 1, 600 do
            state = dock.step(p, state)
            if state == "locked" then
                break
            end
            sleep(0.1)
        end
        return state == "locked", state
    end
    return true
end

return cruise
