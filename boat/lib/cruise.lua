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

function cruise.followPath(path, opts)
    opts = opts or {}
    local arrive = opts.arrive or 3
    local map = route.loadMap()
    local stuck = 0
    local i = 1
    local control = calibrate.load()
    local surgeSign = (control and tonumber(control.surge_sign)) or 1
    local yawSign = (control and tonumber(control.yaw_sign)) or 1
    ui.setMode("route")
    while i <= #path do
        local wp = path[i]
        -- Prefer final place coords on last waypoint
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
                -- Steer in body frame (avoids atan2 vs toEuler yaw mismatch → driving the wrong way)
                local inv = 1 / dist
                local dirx, dirz = dx * inv, dz * inv
                local align = craft.forward.x * dirx + craft.forward.z * dirz -- cos heading error
                local side = craft.right.x * dirx + craft.right.z * dirz -- + = target to starboard
                local yawCmd = util.clamp(side * 2.2, -1, 1) * yawSign
                local surge = 0
                if align > 0.55 then
                    -- Facing the waypoint: go bow-forward
                    surge = util.clamp(0.35 + dist * 0.02, 0.25, 0.9) * surgeSign
                elseif align < -0.35 then
                    -- Facing away: reverse briefly while turning (helps if 180° off)
                    surge = -0.35 * surgeSign
                end
                -- If nearly sideways, turn in place only (surge stays 0)
                applyAxes(surge, 0, yawCmd)
                local spd = select(1, pose.speed(craft))
                local remapped
                remapped, stuck = route.observeCollision(map, craft, math.abs(surge), spd, stuck, 10)
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
                    waypoint = string.format(
                        "%d/%d d=%.0f a=%.2f",
                        i,
                        #path,
                        dist,
                        align
                    ),
                })
            end
        end
        motors.flush(8)
        sleep(0.1)
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
