-- Record a water path by sampling CC:Sable pose while you pilot.
-- Usage: recorder [name] [interval]
-- Stop: press Q.
package.path = package.path .. ";/lib/?.lua;/lib/?/init.lua"
local path = require("path")
local pose = require("pose")

local args = { ... }
local name = args[1] or "route"
local interval = tonumber(args[2]) or 0.25

print("=== Path recorder ===")
print("Path name: " .. name)
print("Sample interval: " .. interval .. "s")
print("Pilot the boat. Press Q to stop and save.")
print()

local ok, err = pcall(pose.get)
if not ok then
    print("FAILED: " .. tostring(err))
    return
end

path.dir()
local waypoints = {}
local t0 = os.clock()
local stop = false

local function sampleLoop()
    while not stop do
        local wp = path.sampleWaypoint(t0)
        waypoints[#waypoints + 1] = wp
        if #waypoints % 10 == 0 then
            print(string.format(
                "  #%d  x=%.1f y=%.1f z=%.1f yaw=%.1fdeg",
                #waypoints,
                wp.x,
                wp.y,
                wp.z,
                pose.yawDeg(wp.yaw)
            ))
        end
        sleep(interval)
    end
end

local function keyLoop()
    while not stop do
        local ev = { os.pullEvent("key") }
        if ev[2] == keys.q then
            stop = true
            return
        end
    end
end

parallel.waitForAny(sampleLoop, keyLoop)

if #waypoints < 2 then
    print("Too few waypoints (" .. #waypoints .. "). Not saved.")
    return
end

local last = waypoints[#waypoints]
local meta = {
    samples = #waypoints,
    duration = os.clock() - t0,
    end_pose = { x = last.x, y = last.y, z = last.z, yaw = last.yaw },
}

local wrote, werr = path.save(name, waypoints, meta)
if not wrote then
    print("Save failed: " .. tostring(werr))
    return
end

print(string.format(
    "Saved %d waypoints to %s (%.1fs)",
    #waypoints,
    path.file(name),
    meta.duration
))
print("Park pose = last waypoint. Use this path with boat follow.")
