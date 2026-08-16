-- Dual port registry: Port A ↔ Port B with virtual docking-port blocks.
-- Shore docks and the boat each expose a stub "docking_port" (Create PSI-style).
local ports = {}

-- Corridor A → B (used for berth heading).
local AX, AZ = 341, 163
local BX, BZ = 383, 285
local dx, dz = BX - AX, BZ - AZ
local yaw_a_to_b = math.atan2(dx, dz)
local yaw_b_to_a = math.atan2(-dx, -dz)

--- Vessel-side docking port block (on the boat).
ports.BOAT_DOCK = {
    kind = "docking_port",
    name = "boat_dock",
    role = "vessel",
    block_id = "create:portable_storage_interface",
    note = "Hull-mounted Create portable_storage_interface facing shore PSI",
}

ports.PORT_A = {
    id = "port_a",
    label = "Port A",
    x = AX,
    z = AZ,
    -- Face open corridor toward B for clear departure.
    yaw = yaw_a_to_b,
    yaw_deg = yaw_a_to_b * 180 / math.pi,
    standoff = 10,
    arrive_dist = 4.5,
    dock_tol = 2.5,
    dock_block = {
        kind = "docking_port",
        name = "port_a_dock",
        role = "shore",
        x = AX,
        z = AZ,
        -- Place at berth facing water. Create: Portable Storage Interface.
        block_id = "create:portable_storage_interface",
    },
}

ports.PORT_B = {
    id = "port_b",
    label = "Port B",
    x = BX,
    z = BZ,
    yaw = yaw_b_to_a,
    yaw_deg = yaw_b_to_a * 180 / math.pi,
    standoff = 10,
    arrive_dist = 4.5,
    dock_tol = 2.5,
    dock_block = {
        kind = "docking_port",
        name = "port_b_dock",
        role = "shore",
        x = BX,
        z = BZ,
        block_id = "create:portable_storage_interface",
    },
}

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

--- Approach waypoint: stand off along berth heading (away from shore corridor partner).
function ports.approachOf(port)
    local yaw = port.yaw or 0
    local d = port.standoff or 10
    -- Back away opposite to berth forward (forward is toward partner).
    return {
        x = port.x - math.sin(yaw) * d,
        z = port.z - math.cos(yaw) * d,
        yaw = yaw,
    }
end

--- Straight corridor waypoints between two ports (inclusive).
function ports.corridorWaypoints(fromPort, toPort, spacing)
    spacing = spacing or 16
    local x0, z0 = fromPort.x, fromPort.z
    local x1, z1 = toPort.x, toPort.z
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
    -- Final berth pose uses destination heading.
    wps[#wps].yaw = toPort.yaw
    wps[#wps].x = toPort.x
    wps[#wps].z = toPort.z
    return wps
end

return ports
