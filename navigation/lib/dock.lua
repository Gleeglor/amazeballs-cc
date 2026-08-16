-- Dock assist helpers: berth targets + docking-port handshake stubs.
-- Real Create PSI / redstone funnels are stubbed when no modem/port computer is present.
local ports = require("ports")
local protocol = require("protocol")

local dock = {}

function dock.boatBlock()
    return ports.BOAT_DOCK
end

function dock.portBlock(port)
    if type(port) == "string" then
        port = ports.get(port)
    end
    return port and port.dock_block or nil
end

--- Software handshake between vessel docking_port and shore docking_port.
-- Tries rednet when a port host exists; otherwise returns a completed stub transcript.
function dock.handshakeStub(boatId, portId, opts)
    opts = opts or {}
    boatId = boatId or "boat1"
    local port = ports.get(portId)
    if not port then
        return false, { error = "unknown port" }
    end

    local vessel = ports.BOAT_DOCK
    local shore = port.dock_block
    local transcript = {
        {
            kind = "link_request",
            from = vessel.name,
            to = shore.name,
            boat_id = boatId,
            port_id = port.id,
        },
    }

    local host = nil
    local hasModem = false
    pcall(function()
        if protocol.open() then
            hasModem = true
            host = protocol.lookup(port.id)
        end
    end)

    if hasModem and host then
        local ids = { boat_id = boatId, port_id = port.id }
        protocol.send(host, "arrived", ids, {
            docking_port = vessel.name,
            shore_port = shore.name,
        })
        transcript[#transcript + 1] = { kind = "arrived_sent", host = host }

        local deadline = os.clock() + (opts.timeout or 12)
        local gotDepart = false
        while os.clock() < deadline do
            local _, msg = protocol.receive(2, function(m)
                return protocol.addressedTo(m, boatId, port.id)
            end)
            if msg then
                transcript[#transcript + 1] = { kind = msg.kind, payload = msg }
                if msg.kind == "depart" or msg.kind == "berth_busy" then
                    gotDepart = msg.kind == "depart"
                    break
                end
                if msg.kind == "job" then
                    protocol.send(host, "xfer_done", ids, {
                        name = msg.name or "stub",
                        direction = msg.direction or "export",
                    })
                    transcript[#transcript + 1] = { kind = "xfer_done_sent" }
                end
            end
        end
        if not gotDepart then
            -- Port silent — complete locally so pathing can continue.
            transcript[#transcript + 1] = { kind = "depart_stub", reason = "port_timeout" }
        end
        return true, {
            mode = "rednet",
            ok = true,
            vessel = vessel,
            shore = shore,
            transcript = transcript,
        }
    end

    -- No port computer: full local stub (mandate: handshake stubs OK).
    transcript[#transcript + 1] = { kind = "link_ack", from = shore.name, to = vessel.name }
    transcript[#transcript + 1] = { kind = "berth_locked", port_id = port.id }
    transcript[#transcript + 1] = {
        kind = "job",
        name = "stub_xfer",
        direction = "export",
        filters = {},
    }
    transcript[#transcript + 1] = { kind = "xfer_done", name = "stub_xfer" }
    transcript[#transcript + 1] = { kind = "depart", port_id = port.id }
    sleep(opts.stub_sleep or 0.4)

    return true, {
        mode = "stub",
        ok = true,
        vessel = vessel,
        shore = shore,
        transcript = transcript,
        note = "No port rednet host — docking_port handshake completed as software stub",
    }
end

return dock
