-- Port controller: schedule, filters, buffer <-> Sophisticated Storage, funnel redstone.
-- Config: /port_config.json
package.path = package.path .. ";/lib/?.lua;/lib/?/init.lua"
local util = require("util")
local protocol = require("protocol")
local schedule = require("schedule")
local xfer = require("xfer")

local CONFIG_PATH = "/port_config.json"

local function defaultConfig()
    return {
        port_id = "port_a",
        mode = "both", -- export | import | both
        schedule = {
            {
                name = "export_example",
                direction = "export",
                priority = 1,
                filters = { "minecraft:iron_ore", "minecraft:copper_ore" },
            },
            {
                name = "import_example",
                direction = "import",
                priority = 2,
                filters = { "minecraft:iron_ingot" },
            },
        },
        buffers = {
            dock = "minecraft:chest_0", -- set to your dock buffer peripheral name
            storage_out = "sophisticatedstorage:storage_output_0",
            storage_in = "sophisticatedstorage:storage_input_0",
        },
        funnels = {
            outbound = nil, -- redstone_relay name or "side:left"
            inbound = nil,
        },
        dock_timeout = 120,
        funnel_time = 10,
        berth_contact = nil, -- optional redstone side/peripheral that reads high when boat present
    }
end

local function loadConfig()
    local cfg = util.readJSON(CONFIG_PATH)
    if not cfg then
        cfg = defaultConfig()
        util.writeJSON(CONFIG_PATH, cfg)
        print("Wrote default " .. CONFIG_PATH)
        print("Edit peripheral names in buffers/funnels, then reboot.")
    end
    return cfg
end

local function setActuator(name, on)
    if not name or name == "" then
        return
    end
    if string.sub(name, 1, 5) == "side:" then
        local side = string.sub(name, 6)
        rs.setAnalogOutput(side, on and 15 or 0)
        return
    end
    if not peripheral.isPresent(name) then
        print("Missing actuator: " .. name)
        return
    end
    local r = peripheral.wrap(name)
    local sides = { "top", "bottom", "left", "right", "front", "back" }
    local level = on and 15 or 0
    if r.setAnalogOutput then
        for _, side in ipairs(sides) do
            pcall(function()
                r.setAnalogOutput(side, level)
            end)
        end
    elseif r.setOutput then
        for _, side in ipairs(sides) do
            pcall(function()
                r.setOutput(side, on)
            end)
        end
    end
end

local function funnelsOff(cfg)
    setActuator(cfg.funnels and cfg.funnels.outbound, false)
    setActuator(cfg.funnels and cfg.funnels.inbound, false)
end

local function berthOccupied(cfg)
    local c = cfg.berth_contact
    if not c then
        return true -- no sensor → trust rednet
    end
    if string.sub(c, 1, 5) == "side:" then
        return rs.getInput(string.sub(c, 6))
    end
    if peripheral.isPresent(c) then
        local p = peripheral.wrap(c)
        if p.getInput then
            for _, side in ipairs({ "top", "bottom", "left", "right", "front", "back" }) do
                local ok, v = pcall(p.getInput, side)
                if ok and v then
                    return true
                end
            end
        end
    end
    return rs.getInput(c)
end

local function sendToBoat(boatId, kind, cfg, extra)
    local ids = { boat_id = boatId, port_id = cfg.port_id }
    local host = protocol.lookup(boatId)
    if host then
        protocol.send(host, kind, ids, extra)
    else
        protocol.broadcast(kind, ids, extra)
    end
end

local function runExportSlot(cfg, slot)
    local buf = cfg.buffers.dock
    local src = cfg.buffers.storage_out
    print("Export " .. tostring(slot.name) .. " SS -> buffer")
    local n, reason = xfer.pump(src, buf, slot.filters, { timeout = 20 })
    print("  buffer fill: " .. n .. " (" .. tostring(reason) .. ")")
    setActuator(cfg.funnels and cfg.funnels.outbound, true)
    setActuator(cfg.funnels and cfg.funnels.inbound, false)
    sleep(cfg.funnel_time or 10)
    -- drain leftover attempt still ok
    funnelsOff(cfg)
    return n > 0 or reason == "idle"
end

local function runImportSlot(cfg, slot)
    local buf = cfg.buffers.dock
    local dst = cfg.buffers.storage_in
    print("Import " .. tostring(slot.name) .. " buffer -> SS")
    setActuator(cfg.funnels and cfg.funnels.inbound, true)
    setActuator(cfg.funnels and cfg.funnels.outbound, false)
    sleep(cfg.funnel_time or 10)
    local n, reason = xfer.pump(buf, dst, slot.filters, { timeout = 20 })
    print("  storage fill: " .. n .. " (" .. tostring(reason) .. ")")
    funnelsOff(cfg)
    return true
end

local function serveBoat(cfg, boatId, sender)
    if cfg.berth_owner and cfg.berth_owner ~= boatId then
        sendToBoat(boatId, "berth_busy", cfg, {})
        return
    end
    if not berthOccupied(cfg) then
        print("arrived but berth contact open — ignoring")
        return
    end

    cfg.berth_owner = boatId
    print("Serving boat " .. boatId)

    local slots = schedule.plan(cfg)
    if #slots == 0 then
        print("No schedule slots for mode " .. tostring(cfg.mode))
        sendToBoat(boatId, "depart", cfg, {})
        cfg.berth_owner = nil
        return
    end

    for _, slot in ipairs(slots) do
        local dir = slot.direction or "export"
        sendToBoat(boatId, "job", cfg, {
            name = slot.name,
            direction = dir,
            filters = slot.filters,
        })

        -- Import: wait for boat to stage cargo to gangway. Export: brief settle.
        local waitJob = (dir == "import") and 12 or 2
        protocol.receive(waitJob, function(m)
            return m.kind == "xfer_done"
                and protocol.addressedTo(m, boatId, cfg.port_id)
        end)

        local ok
        if dir == "export" then
            ok = runExportSlot(cfg, slot)
        else
            ok = runImportSlot(cfg, slot)
        end
        if not ok then
            sendToBoat(boatId, "xfer_fail", cfg, { name = slot.name })
        end
    end

    funnelsOff(cfg)
    sendToBoat(boatId, "depart", cfg, {})
    cfg.berth_owner = nil
    print("Depart sent to " .. boatId)
end

local function listPeripherals()
    print("Inventories:")
    for _, n in ipairs(util.findInventories()) do
        print("  " .. n)
    end
    print("Relays:")
    for _, n in ipairs(peripheral.getNames()) do
        if peripheral.hasType(n, "redstone_relay") then
            print("  " .. n)
        end
    end
end

-- main
local cfg = loadConfig()
if not protocol.open() then
    print("No wireless modem")
    return
end
protocol.host(cfg.port_id)
funnelsOff(cfg)
print("Port " .. cfg.port_id .. " mode=" .. tostring(cfg.mode))
print("Commands: wait (default) | list | quit")

local args = { ... }
local autoWait = args[1] ~= "menu"

local function eventLoop()
    while true do
        local sender, msg = protocol.receive(nil, function(m)
            return protocol.addressedTo(m, nil, cfg.port_id)
                and (m.kind == "arrived" or m.kind == "hello" or m.kind == "xfer_done")
        end)
        if msg and msg.kind == "arrived" and msg.boat_id then
            serveBoat(cfg, msg.boat_id, sender)
        elseif msg and msg.kind == "hello" then
            sendToBoat(msg.boat_id, "ack", cfg, {})
        end
    end
end

if autoWait then
    print("Waiting for boats...")
    eventLoop()
else
    print("menu: wait | list | quit")
    while true do
        write("> ")
        local line = read()
        if not line then
            break
        end
        local cmd = string.lower(string.match(line, "^%s*(%S*)") or "")
        if cmd == "quit" then
            funnelsOff(cfg)
            break
        elseif cmd == "list" then
            listPeripherals()
        elseif cmd == "wait" or cmd == "" then
            print("Waiting...")
            eventLoop()
        else
            print("wait | list | quit")
        end
    end
end
