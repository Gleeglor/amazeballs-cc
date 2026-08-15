-- Rednet transport protocol with boat_id / port_id addressing.
local util = require("util")

local protocol = {}
protocol.PROTOCOL = "transport"

function protocol.open()
    local name = util.openWireless()
    if not name then
        return nil, "no wireless modem"
    end
    return name
end

function protocol.host(hostname)
    rednet.host(protocol.PROTOCOL, hostname)
end

function protocol.lookup(hostname)
    return rednet.lookup(protocol.PROTOCOL, hostname)
end

--- Build a message table. kind is required; boat_id/port_id from ids table.
function protocol.msg(kind, ids, extra)
    local m = {
        kind = kind,
        boat_id = ids.boat_id,
        port_id = ids.port_id,
        t = util.now(),
    }
    if extra then
        for k, v in pairs(extra) do
            m[k] = v
        end
    end
    return m
end

function protocol.send(receiverId, kind, ids, extra)
    return rednet.send(receiverId, protocol.msg(kind, ids, extra), protocol.PROTOCOL)
end

function protocol.broadcast(kind, ids, extra)
    return rednet.broadcast(protocol.msg(kind, ids, extra), protocol.PROTOCOL)
end

--- Receive next message matching filter. filter(msg, sender) -> bool
function protocol.receive(timeout, filter)
    local deadline = timeout and (os.clock() + timeout) or nil
    while true do
        local remain = nil
        if deadline then
            remain = deadline - os.clock()
            if remain <= 0 then
                return nil
            end
        end
        local sender, msg, proto = rednet.receive(protocol.PROTOCOL, remain)
        if not sender then
            return nil
        end
        if type(msg) == "table" and type(msg.kind) == "string" then
            if not filter or filter(msg, sender) then
                return sender, msg
            end
        end
    end
end

--- True if message is for this boat/port (nil id in local means accept any for that field).
function protocol.addressedTo(msg, boat_id, port_id)
    if boat_id and msg.boat_id and msg.boat_id ~= boat_id then
        return false
    end
    if port_id and msg.port_id and msg.port_id ~= port_id then
        return false
    end
    return true
end

return protocol
