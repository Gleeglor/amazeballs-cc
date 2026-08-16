-- Follow A* waypoints with surge/yaw; optical + collision memory.
local util = require("util")
local pose = require("pose")
local motors = require("motors")
local wrench = require("wrench")
local calibrate = require("boat_calibrate")
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

local function replan(map, craft, goalX, goalZ, surgeSign)
    route.clearAroundWorld(map, craft.x, craft.z, 1)
    applyAxes(-0.4 * (surgeSign or 1), 0, 0)
    for _ = 1, 6 do
        motors.flush(8)
        sleep(0.1)
    end
    motors.panicNow()
    motors.flush(32)
    craft = pose.get() or craft
    local newPath, err = route.astar(map, craft.x, craft.z, goalX, goalZ)
    if newPath then
        return route.simplifyPath(newPath, 4), nil
    end
    return nil, err
end

--- Pick a chase point ~lookAhead blocks ahead on the path (not the next 4m cell).
local function chasePoint(path, craft, lookAhead)
    lookAhead = lookAhead or 36
    local best = path[#path]
    for i = 1, #path do
        local wp = path[i]
        local d = math.sqrt((wp.x - craft.x) ^ 2 + (wp.z - craft.z) ^ 2)
        if d >= lookAhead then
            return wp, i
        end
    end
    return best, #path
end

function cruise.followPath(path, opts)
    opts = opts or {}
    local arrive = opts.arrive or 8
    local map = route.loadMap()
    local stuck = 0
    local control = calibrate.load()
    local surgeSign = (control and tonumber(control.surge_sign)) or 1
    local yawSign = (control and tonumber(control.yaw_sign)) or 1
    local goalX, goalZ = path[#path].x, path[#path].z
    path = route.simplifyPath(path, 4)
    ui.setMode("route")

    while true do
        local craft = pose.get()
        if not craft then
            sleep(0.2)
        else
            local goalDist = math.sqrt((goalX - craft.x) ^ 2 + (goalZ - craft.z) ^ 2)
            if goalDist < arrive then
                break
            end

            local opticalHit = route.scanOptical(map, craft, 12)
            local wp = chasePoint(path, craft, goalDist < 40 and 12 or 40)
            local dx = wp.x - craft.x
            local dz = wp.z - craft.z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist < 0.5 then
                dist = 0.5
            end
            local dirx, dirz = dx / dist, dz / dist
            local align = craft.forward.x * dirx + craft.forward.z * dirz
            local side = craft.right.x * dirx + craft.right.z * dirz

            local yawCmd
            if align < 0 and math.abs(side) < 0.2 then
                yawCmd = 1 * yawSign -- target behind: spin
            else
                yawCmd = util.clamp(side * 2.8, -1, 1) * yawSign
            end

            local surge = 0
            if opticalHit then
                yawCmd = ((side >= 0) and 1 or -1) * yawSign
                surge = -0.25 * surgeSign
            elseif align > 0.15 then
                -- Move whenever bow has any component toward target (don't wait for perfect align)
                surge = util.clamp(0.35 + 0.65 * align, 0.35, 1.0) * surgeSign
            elseif align > -0.35 then
                -- Mostly sideways: creep while turning so we don't sit forever
                surge = 0.2 * surgeSign
            end
            -- else deeply astern: yaw only until we swing around

            applyAxes(surge, 0, yawCmd)
            local spd = select(1, pose.speed(craft))
            local remapped
            remapped, stuck = route.observeCollision(map, craft, math.abs(surge), spd, stuck, 6)
            if opticalHit or remapped then
                local newPath, err = replan(map, craft, goalX, goalZ, surgeSign)
                if newPath then
                    path = newPath
                    stuck = 0
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
                waypoint = string.format("d=%.0f a=%.2f", goalDist, align),
            })
        end
        motors.flush(8)
        sleep(0.08)
    end
    motors.panicNow()
    motors.flush(64)
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
        for _ = 1, 200 do
            state = dock.step(p, state)
            if state == "locked" then
                break
            end
            sleep(0.1)
        end
        motors.panicNow()
        motors.flush(64)
        return state == "locked", state
    end
    return true, "arrived"
end

return cruise
