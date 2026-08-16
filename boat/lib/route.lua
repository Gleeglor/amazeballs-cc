-- A* routing on coarse XZ grid with obstacle memory + optical lookahead.
local util = require("util")
local pose = require("pose")

local route = {}

route.CELL = 4
route.PLACES_PATH = "/places.json"
route.MAP_PATH = "/obstacle_map.json"
-- Plan with boat beam: treat neighbors of blocked cells as blocked.
route.INFLATE = 1

local function key(cx, cz)
    return tostring(cx) .. "," .. tostring(cz)
end

function route.worldToCell(x, z)
    return math.floor(x / route.CELL), math.floor(z / route.CELL)
end

function route.cellToWorld(cx, cz)
    return (cx + 0.5) * route.CELL, (cz + 0.5) * route.CELL
end

function route.loadPlaces()
    return util.readJSON(route.PLACES_PATH) or { places = {} }
end

function route.savePlaces(data)
    return util.writeJSON(route.PLACES_PATH, data)
end

function route.loadMap()
    local m = util.readJSON(route.MAP_PATH)
    if not m then
        return { blocked = {} }
    end
    m.blocked = m.blocked or {}
    return m
end

function route.saveMap(map)
    return util.writeJSON(route.MAP_PATH, map)
end

function route.isBlocked(map, cx, cz)
    return map.blocked[key(cx, cz)] == true
end

--- True if cell or any neighbor within inflate is blocked.
function route.isBlockedSoft(map, cx, cz, inflate)
    inflate = inflate or 0
    for dx = -inflate, inflate do
        for dz = -inflate, inflate do
            if route.isBlocked(map, cx + dx, cz + dz) then
                return true
            end
        end
    end
    return false
end

function route.markBlocked(map, cx, cz, radius)
    radius = radius or 1
    for dx = -radius, radius do
        for dz = -radius, radius do
            map.blocked[key(cx + dx, cz + dz)] = true
        end
    end
end

function route.markBlockedWorld(map, x, z, radius)
    local cx, cz = route.worldToCell(x, z)
    route.markBlocked(map, cx, cz, radius)
end

--- Unblock cells under/near the boat so planning can leave a scraped cell.
function route.clearAroundWorld(map, x, z, radius)
    radius = radius or 1
    local cx, cz = route.worldToCell(x, z)
    for dx = -radius, radius do
        for dz = -radius, radius do
            map.blocked[key(cx + dx, cz + dz)] = nil
        end
    end
end

--- Mark cells ahead of bow as blocked (collision memory).
function route.markAhead(map, craft, distBlocks, radius)
    craft = craft or pose.get()
    if not craft then
        return
    end
    distBlocks = distBlocks or route.CELL
    radius = radius or 2
    local fx, fz = craft.forward.x, craft.forward.z
    local rx, rz = craft.right.x, craft.right.z
    -- Wall of blocked cells across the bow (and a bit further) so A* must detour.
    for d = 0.5, 2.5, 1 do
        local bx = craft.x + fx * distBlocks * d
        local bz = craft.z + fz * distBlocks * d
        route.markBlockedWorld(map, bx, bz, radius)
        for s = -2, 2 do
            if s ~= 0 then
                route.markBlockedWorld(map, bx + rx * s * route.CELL, bz + rz * s * route.CELL, 1)
            end
        end
    end
    route.saveMap(map)
end

--- Optical sensor lookahead if present.
function route.scanOptical(map, craft, maxRange)
    maxRange = maxRange or 12
    craft = craft or pose.get()
    if not peripheral then
        return false
    end
    local sensors = { peripheral.find("laser_sensor") }
    if #sensors == 0 then
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.hasType(name, "laser_sensor") or peripheral.hasType(name, "optical_sensor") then
                sensors[#sensors + 1] = peripheral.wrap(name)
            end
        end
    end
    local hit = false
    for _, s in ipairs(sensors) do
        if s.setRange then
            pcall(function()
                s.setRange(maxRange)
            end)
        end
        local ok, dist = pcall(function()
            return s.getDistance and s.getDistance()
        end)
        if ok and type(dist) == "number" and dist > 0 and dist < maxRange then
            local blockOk, block = pcall(function()
                return s.getBlock and s.getBlock()
            end)
            local isWater = false
            if blockOk and type(block) == "string" then
                isWater = block:find("water", 1, true) ~= nil
            elseif blockOk and type(block) == "table" and block.name then
                isWater = tostring(block.name):find("water", 1, true) ~= nil
            end
            if not isWater and craft then
                local x = craft.x + craft.forward.x * dist
                local z = craft.z + craft.forward.z * dist
                route.markBlockedWorld(map, x, z, 2)
                hit = true
            end
        end
    end
    if hit then
        route.saveMap(map)
    end
    return hit
end

local function heuristic(ax, az, bx, bz)
    return math.abs(ax - bx) + math.abs(az - bz)
end

--- A* from world (sx,sz) to (gx,gz). Returns list of {x,z} waypoints or nil.
function route.astar(map, sx, sz, gx, gz, maxExpand)
    maxExpand = maxExpand or 12000
    local inflate = route.INFLATE or 0
    local scx, scz = route.worldToCell(sx, sz)
    local gcx, gcz = route.worldToCell(gx, gz)
    -- Always allow start/goal cells (boat may sit on scraped obstacle memory).
    route.clearAroundWorld(map, sx, sz, 1)
    map.blocked[key(gcx, gcz)] = nil

    local open = {}
    local came = {}
    local gScore = {}
    local fScore = {}
    local sk = key(scx, scz)
    gScore[sk] = 0
    fScore[sk] = heuristic(scx, scz, gcx, gcz)
    open[sk] = { cx = scx, cz = scz }

    local dirs = {
        { 1, 0 },
        { -1, 0 },
        { 0, 1 },
        { 0, -1 },
        { 1, 1 },
        { 1, -1 },
        { -1, 1 },
        { -1, -1 },
    }

    local expanded = 0
    while true do
        local bestK, bestF = nil, 1e18
        for k, node in pairs(open) do
            local f = fScore[k] or 1e18
            if f < bestF then
                bestF = f
                bestK = k
            end
        end
        if not bestK then
            return nil, "no path"
        end
        local cur = open[bestK]
        open[bestK] = nil
        expanded = expanded + 1
        if expanded > maxExpand then
            return nil, "expand limit"
        end
        if cur.cx == gcx and cur.cz == gcz then
            local path = {}
            local ck = bestK
            while ck do
                local cx, cz = string.match(ck, "^(-?%d+),(-?%d+)$")
                cx, cz = tonumber(cx), tonumber(cz)
                local wx, wz = route.cellToWorld(cx, cz)
                table.insert(path, 1, { x = wx, z = wz, cx = cx, cz = cz })
                ck = came[ck]
            end
            -- Keep goal exact world coords for docking precision.
            if #path > 0 then
                path[#path].x = gx
                path[#path].z = gz
            end
            return path
        end
        for _, d in ipairs(dirs) do
            local nx, nz = cur.cx + d[1], cur.cz + d[2]
            local isStart = nx == scx and nz == scz
            local isGoal = nx == gcx and nz == gcz
            local blocked = (not isStart and not isGoal) and route.isBlockedSoft(map, nx, nz, inflate)
            if not blocked then
                local nk = key(nx, nz)
                local step = (d[1] ~= 0 and d[2] ~= 0) and 1.414 or 1
                local tent = (gScore[bestK] or 1e18) + step
                if tent < (gScore[nk] or 1e18) then
                    came[nk] = bestK
                    gScore[nk] = tent
                    fScore[nk] = tent + heuristic(nx, nz, gcx, gcz)
                    open[nk] = { cx = nx, cz = nz }
                end
            end
        end
    end
end

function route.pathToPlace(placeName, fromX, fromZ)
    local places = route.loadPlaces()
    local p = places.places and places.places[placeName]
    if not p then
        return nil, "unknown place"
    end
    local map = route.loadMap()
    return route.astar(map, fromX, fromZ, p.x, p.z)
end

--- Detect stuck under thrust; mark ahead and return true if remapped.
function route.observeCollision(map, craft, commandedThrust, speed, ticksStuck, threshold)
    threshold = threshold or 6
    if math.abs(commandedThrust or 0) < 0.25 then
        return false, 0
    end
    if math.abs(speed or 0) < 0.08 then
        ticksStuck = (ticksStuck or 0) + 1
    else
        return false, 0
    end
    if ticksStuck >= threshold then
        route.markAhead(map, craft, route.CELL * 1.0, 2)
        return true, 0
    end
    return false, ticksStuck
end

--- Thin waypoint list: keep every stride-th cell plus the last.
function route.simplifyPath(path, stride)
    if not path or #path <= 2 then
        return path
    end
    stride = stride or 3
    local out = { path[1] }
    for i = stride, #path - 1, stride do
        out[#out + 1] = path[i]
    end
    out[#out + 1] = path[#path]
    return out
end

return route
