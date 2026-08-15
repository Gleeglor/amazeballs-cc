-- Recorded path load/save/sample.
local util = require("util")
local pose = require("pose")

local path = {}
local PATH_DIR = "/paths"

function path.dir()
    util.ensureDir(PATH_DIR)
    return PATH_DIR
end

function path.file(name)
    name = string.gsub(name, "%.json$", "")
    return PATH_DIR .. "/" .. name .. ".json"
end

function path.save(name, waypoints, meta)
    local data = {
        version = 1,
        name = name,
        meta = meta or {},
        waypoints = waypoints,
    }
    local ok, err = util.writeJSON(path.file(name), data)
    return ok, err
end

function path.load(name)
    local data = util.readJSON(path.file(name))
    if not data or type(data.waypoints) ~= "table" then
        return nil
    end
    return data
end

function path.list()
    path.dir()
    local names = {}
    for _, f in ipairs(fs.list(PATH_DIR)) do
        if string.match(f, "%.json$") then
            names[#names + 1] = string.gsub(f, "%.json$", "")
        end
    end
    table.sort(names)
    return names
end

--- Sample current craft pose into a waypoint table.
function path.sampleWaypoint(t0)
    local p = pose.get()
    return {
        x = p.position.x,
        y = p.position.y,
        z = p.position.z,
        yaw = p.yaw,
        t = (t0 and (os.clock() - t0)) or 0,
    }
end

--- Record until the user presses a key (or timeout). interval in seconds.
function path.record(interval, shouldStop)
    interval = interval or 0.25
    local waypoints = {}
    local t0 = os.clock()
    while true do
        if shouldStop and shouldStop() then
            break
        end
        waypoints[#waypoints + 1] = path.sampleWaypoint(t0)
        sleep(interval)
    end
    return waypoints
end

function path.nearestIndex(waypoints, craft)
    craft = craft or pose.get()
    local bestI, bestD = 1, math.huge
    for i, wp in ipairs(waypoints) do
        local dx = wp.x - craft.position.x
        local dz = wp.z - craft.position.z
        local d = dx * dx + dz * dz
        if d < bestD then
            bestD = d
            bestI = i
        end
    end
    return bestI, math.sqrt(bestD)
end

function path.last(waypoints)
    if not waypoints or #waypoints == 0 then
        return nil
    end
    return waypoints[#waypoints]
end

return path
