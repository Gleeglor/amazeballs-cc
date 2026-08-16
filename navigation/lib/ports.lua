-- Dual port registry with WATER-SAFE soft holds (never drive onto shore coords).
-- Shore marker XZ (341,163 / 383,285) are landmarks only — final targets stay offshore.
local ports = {}

-- Shore landmarks (dock blocks / PSI). NOT final nav targets.
local AX, AZ = 341, 163
local BX, BZ = 383, 285
local dx, dz = BX - AX, BZ - AZ
local yaw_a_to_b = math.atan2(dx, dz)
local yaw_b_to_a = math.atan2(-dx, -dz)

-- Large offshore standoff along the A↔B corridor (toward mid-water).
-- Soft arrival: within ~20 blocks of the WATER hold = reached (never slam shore).
local WATER_STANDOFF = 28
local SOFT_ARRIVE = 20
local SOFT_TOL = 20

ports.SAFETY = {
    never_seek_shore = true,
    water_standoff = WATER_STANDOFF,
    soft_arrive_dist = SOFT_ARRIVE,
    soft_tol = SOFT_TOL,
    horiz_arrive = 20,
    max_approach_speed = 0.2,
    cruise_rpm_cap = 36,
    creep_rpm_cap = 18,
    auth_ceil = 0.78,
    note = "Reached if horiz ≤20 of water hold; surge-biased gentle cruise (auth≤0.78); never seek shore coords",
}

ports.BOAT_DOCK = {
    kind = "docking_port",
    name = "boat_dock",
    role = "vessel",
    block_id = "create:portable_storage_interface",
    note = "Hull PSI — align in open water; do not drive onto shore PSI coords",
}

--- Water hold for Port A: toward B / corridor center, well offshore from shore marker.
ports.PORT_A = {
    id = "port_a",
    label = "Port A (water hold)",
    -- Landmark only (shore / PSI)
    shore_x = AX,
    shore_z = AZ,
    x = AX, -- kept for id lookups; prefer holdX/holdZ / approachOf
    z = AZ,
    yaw = yaw_a_to_b,
    yaw_deg = yaw_a_to_b * 180 / math.pi,
    standoff = WATER_STANDOFF,
    arrive_dist = SOFT_ARRIVE,
    dock_tol = SOFT_TOL,
    max_speed = 0.15,
    soft_dock = true,
    dock_block = {
        kind = "docking_port",
        name = "port_a_dock",
        role = "shore",
        x = AX,
        z = AZ,
        block_id = "create:portable_storage_interface",
    },
}

ports.PORT_B = {
    id = "port_b",
    label = "Port B (water hold)",
    shore_x = BX,
    shore_z = BZ,
    x = BX,
    z = BZ,
    yaw = yaw_b_to_a,
    yaw_deg = yaw_b_to_a * 180 / math.pi,
    standoff = WATER_STANDOFF,
    arrive_dist = SOFT_ARRIVE,
    dock_tol = SOFT_TOL,
    max_speed = 0.15,
    soft_dock = true,
    dock_block = {
        kind = "docking_port",
        name = "port_b_dock",
        role = "shore",
        x = BX,
        z = BZ,
        block_id = "create:portable_storage_interface",
    },
}

-- Precompute water holds: from shore, step toward corridor partner (open water).
ports.PORT_A.hold_x = AX + math.sin(yaw_a_to_b) * WATER_STANDOFF
ports.PORT_A.hold_z = AZ + math.cos(yaw_a_to_b) * WATER_STANDOFF
ports.PORT_B.hold_x = BX + math.sin(yaw_b_to_a) * WATER_STANDOFF
ports.PORT_B.hold_z = BZ + math.cos(yaw_b_to_a) * WATER_STANDOFF

ports.BY_ID = {
    port_a = ports.PORT_A,
    a = ports.PORT_A,
    ["341,163"] = ports.PORT_A,
    port_b = ports.PORT_B,
    b = ports.PORT_B,
    ["383,285"] = ports.PORT_B,
}

function ports.get(idOrName)
    if idOrName == nil then
        return nil
    end
    local key = string.lower(tostring(idOrName))
    return ports.BY_ID[key]
end

function ports.list()
    return { ports.PORT_A, ports.PORT_B }
end

--- Soft water hold point (final target). NEVER the shore landmark.
function ports.holdOf(port)
    if not port then
        return nil
    end
    local hx = port.hold_x or port.x
    local hz = port.hold_z or port.z
    local d = port.standoff or WATER_STANDOFF
    if port.hold_x == nil then
        local yaw = port.yaw or 0
        -- Toward corridor partner = into water between A and B
        hx = (port.shore_x or port.x) + math.sin(yaw) * d
        hz = (port.shore_z or port.z) + math.cos(yaw) * d
    end
    return {
        x = hx,
        z = hz,
        yaw = port.yaw,
        soft = true,
        shore_x = port.shore_x or port.x,
        shore_z = port.shore_z or port.z,
    }
end

--- Farther offshore approach (before soft hold). Even safer entry.
function ports.approachOf(port)
    local hold = ports.holdOf(port)
    if not hold then
        return nil
    end
    local yaw = port.yaw or 0
    local extra = math.max(12, (port.standoff or WATER_STANDOFF) * 0.5)
    return {
        x = hold.x + math.sin(yaw) * extra,
        z = hold.z + math.cos(yaw) * extra,
        yaw = yaw,
        soft = true,
    }
end

--- Corridor waypoints stay in open water (use holds, not shore markers).
function ports.corridorWaypoints(fromPort, toPort, spacing)
    spacing = spacing or 16
    local a = ports.holdOf(fromPort)
    local b = ports.holdOf(toPort)
    local x0, z0 = a.x, a.z
    local x1, z1 = b.x, b.z
    local dist = math.sqrt((x1 - x0) ^ 2 + (z1 - z0) ^ 2)
    local n = math.max(2, math.floor(dist / spacing) + 1)
    local yaw = math.atan2(x1 - x0, z1 - z0)
    local wps = {}
    for i = 0, n do
        local t = i / n
        wps[#wps + 1] = {
            x = x0 + (x1 - x0) * t,
            z = z0 + (z1 - z0) * t,
            yaw = yaw,
            t = i,
        }
    end
    wps[#wps].yaw = toPort.yaw
    wps[#wps].x = b.x
    wps[#wps].z = b.z
    return wps
end

return ports
