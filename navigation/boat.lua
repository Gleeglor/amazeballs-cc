-- Boat autopilot: follow recorded paths, dock-assist, rednet handshake with ports.
-- Config: /boat_config.json
package.path = package.path .. ";/lib/?.lua;/lib/?/init.lua"
local util = require("util")
local path = require("path")
local drive = require("drive")
local protocol = require("protocol")
local xfer = require("xfer")
local pose = require("pose")

local CONFIG_PATH = "/boat_config.json"

local function defaultConfig()
    return {
        boat_id = "boat1",
        ports = {
            { id = "port_a", x = 341, z = 163, yaw_deg = 0, arrival = "to_port_a", depart = "a_to_b" },
            { id = "port_b", x = 383, z = 285, yaw_deg = 180, arrival = "to_port_b", depart = "b_to_a" },
        },
        -- Alternating A↔B logistics route
        route = {
            { port_id = "port_a", path = "to_port_a" },
            { port_id = "port_b", path = "to_port_b" },
        },
        cargo = "left", -- peripheral name or side-named inventory for gangway
        tidy_cargo = nil, -- optional deeper cargo inventory
        funnel_wait = 8,
        dock_timeout = 180,
        -- Create PSI berth handshake (software stub if no rednet port host)
        docking = {
            shore_block = "create:portable_storage_interface",
            boat_block = "create:portable_storage_interface",
            use_stub_handshake = true,
        },
    }
end

local function loadConfig()
    local cfg = util.readJSON(CONFIG_PATH)
    if not cfg then
        cfg = defaultConfig()
        util.writeJSON(CONFIG_PATH, cfg)
        print("Wrote default " .. CONFIG_PATH)
    end
    return cfg
end

local function findPortHost(portId)
    return protocol.lookup(portId)
end

local function waitFor(kind, cfg, portId, timeout)
    local sender, msg = protocol.receive(timeout, function(m)
        if m.kind ~= kind then
            return false
        end
        return protocol.addressedTo(m, cfg.boat_id, portId)
    end)
    return sender, msg
end

local function announceArrived(cfg, portId)
    local ids = { boat_id = cfg.boat_id, port_id = portId }
    local host = findPortHost(portId)
    if host then
        protocol.send(host, "arrived", ids, {})
    else
        protocol.broadcast("arrived", ids, {})
    end
    print("Signaled arrived -> " .. portId)
end

local function handleJob(cfg, job)
    local direction = job.direction or "export"
    local filters = job.filters
    print("Job " .. tostring(job.name) .. " (" .. direction .. ")")

    if direction == "import" and cfg.tidy_cargo and cfg.cargo then
        local n = xfer.pump(cfg.tidy_cargo, cfg.cargo, filters, {
            timeout = math.max(4, (cfg.funnel_wait or 8) / 2),
        })
        print("Staged " .. n .. " items to gangway")
    end

    local ids = { boat_id = cfg.boat_id, port_id = job.port_id }
    local host = findPortHost(job.port_id)
    if host then
        protocol.send(host, "xfer_done", ids, { name = job.name, direction = direction })
    else
        protocol.broadcast("xfer_done", ids, { name = job.name, direction = direction })
    end

    -- Port owns funnel timing; optionally tidy after export once funnels have run.
    if direction == "export" and cfg.tidy_cargo and cfg.cargo then
        sleep(cfg.funnel_wait or 8)
        local n = xfer.pump(cfg.cargo, cfg.tidy_cargo, filters, {
            timeout = cfg.funnel_wait or 8,
        })
        print("Tidied " .. n .. " items into cargo")
    end
end

local function dockSession(cfg, portId)
    local dockLib = require("dock")
    local portsLib = require("ports")
    local berth = portsLib.get(portId)
    local control = drive.loadControl()
    if berth and control then
        print("Soft water hold " .. portId .. " (≤20 blocks, gentle)")
        local craft = pose.get()
        local y = craft.position.y
        local softTol = (portsLib.SAFETY and portsLib.SAFETY.soft_tol) or 20
        local hold = portsLib.holdOf(berth)
        hold.y = y
        local approach = portsLib.approachOf(berth)
        approach.y = y
        local function horiz(p, t)
            local dx = p.position.x - t.x
            local dz = p.position.z - t.z
            return math.sqrt(dx * dx + dz * dz)
        end
        if horiz(craft, hold) <= softTol then
            drive.allOff(control)
            print("Already within soft hold")
        else
            local pid = drive.newPidStates()
            local t0 = os.clock()
            local timeout = (cfg.dock_timeout) or 120
            while os.clock() - t0 < timeout * 0.55 do
                local err, arrived = drive.stepToward(control, approach, "cruise", pid, 0.15)
                drive.flushMotors(4)
                craft = pose.get()
                if arrived or horiz(craft, hold) <= softTol or (err and err.distance and err.distance < softTol) then
                    break
                end
                sleep(0.15)
            end
            if horiz(pose.get(), hold) > softTol then
                pid = drive.newPidStates()
                local t1 = os.clock()
                while os.clock() - t1 < timeout * 0.45 do
                    local err, arrived = drive.stepToward(control, hold, "creep", pid, 0.12)
                    drive.flushMotors(4)
                    if arrived or (err and err.distance and err.distance <= softTol) then
                        break
                    end
                    sleep(0.12)
                end
            end
            drive.allOff(control)
        end
        print("Soft hold done")
    end
    announceArrived(cfg, portId)
    if cfg.docking and cfg.docking.use_stub_handshake ~= false then
        local okH, hs = dockLib.handshakeStub(cfg.boat_id or "boat1", portId, {
            timeout = math.min(cfg.funnel_wait or 8, 12),
        })
        print("Handshake: " .. tostring(okH) .. " mode=" .. tostring(hs and hs.mode))
        if okH then
            return true
        end
    end
    local deadline = os.clock() + ((cfg.dock_timeout) or 180)
    while os.clock() < deadline do
        local sender, msg = protocol.receive(2, function(m)
            return protocol.addressedTo(m, cfg.boat_id, portId)
                and (m.kind == "job" or m.kind == "depart" or m.kind == "berth_busy" or m.kind == "wait")
        end)
        if not msg then
            -- keep waiting
        elseif msg.kind == "berth_busy" or msg.kind == "wait" then
            print("Berth busy — holding")
            drive.allOff()
        elseif msg.kind == "job" then
            msg.port_id = portId
            handleJob(cfg, msg)
        elseif msg.kind == "depart" then
            print("Depart cleared")
            return true
        end
    end
    print("Dock session timeout")
    return false
end

local function followNamed(name)
    local data = path.load(name)
    if not data then
        print("Missing path: " .. name)
        return false
    end
    print("Following /paths/" .. name .. ".json (" .. #data.waypoints .. " wps)")
    local ok, reason = drive.followPath(drive.loadControl(), data.waypoints, {})
    print("Follow result: " .. tostring(reason))
    return ok
end

local function runRoute(cfg)
    local control = drive.loadControl()
    if not control then
        print("No /boat_control.json — run calibrate first")
        return
    end

    local route = cfg.route
    if type(route) ~= "table" or #route == 0 then
        print("No route in boat_config.json")
        return
    end

    local idx = 1
    while true do
        local leg = route[idx]
        if not leg then
            idx = 1
            leg = route[idx]
        end
        print("--- Leg " .. idx .. " -> " .. tostring(leg.port_id) .. " via " .. tostring(leg.path))
        if not followNamed(leg.path) then
            print("Path follow failed; retry in 5s")
            sleep(5)
        else
            dockSession(cfg, leg.port_id)
            -- brief clear-off before next path
            drive.allOff(control)
            sleep(1)
            idx = idx + 1
            if idx > #route then
                idx = 1
            end
        end
    end
end

local function splitArgs(str)
    local out = {}
    if not str or str == "" then
        return out
    end
    for token in string.gmatch(str, "%S+") do
        out[#out + 1] = token
    end
    return out
end

local function runCalibrate(argStr)
    local navCal = require("nav_calibrate")
    local opts = navCal.parseArgs(splitArgs(argStr))
    print("=== Calibrate (from boat menu) ===")
    print("Open water, props submerged. Q from control first if you were piloting.")
    print(string.format("rpm/motor=%s  shared_power=%s RF/t (0=off)", tostring(opts.probe_rpm), tostring(opts.power_budget_rf)))
    print()
    drive.stopAllMotors({ drain_timeout = 0.5 })
    local control, err = navCal.run({
        pulse = 2.0,
        settle = 0.8,
        window_start = 0.5,
        window_end = 1.5,
        use_sides = false,
        invert_analog = opts.invert_analog,
        probe_rpm = opts.probe_rpm,
        power_budget_rf = opts.power_budget_rf,
        fe_per_rpm = opts.fe_per_rpm,
    })
    if not control then
        print("FAILED: " .. tostring(err))
        return false
    end
    navCal.printReport(control)
    return true
end

local function menu(cfg)
    print("Boat " .. cfg.boat_id)
    print("Commands: control | calibrate [power N] [rpm N] | record <name> | stop | run | follow <path> | dock <port> | list | pose | testagent | quit")
    while true do
        write("> ")
        local line = read()
        if not line then
            break
        end
        local cmd, a = string.match(line, "^(%S+)%s*(.*)$")
        cmd = cmd and string.lower(cmd) or ""
        a = a and string.match(a, "^%s*(.-)%s*$") or ""
        if cmd == "quit" or cmd == "exit" then
            drive.allOff(nil, { scan_all = true })
            break
        elseif cmd == "stop" or cmd == "halt" then
            drive.allOff(nil, { scan_all = true })
            print("All thrusters / motors stopped")
        elseif cmd == "list" then
            for _, n in ipairs(path.list()) do
                print("  " .. n)
            end
        elseif cmd == "calibrate" or cmd == "calib" then
            runCalibrate(a)
        elseif cmd == "control" or cmd == "manual" then
            local _, reason = drive.manualLoop(drive.loadControl(), {})
            print("Control ended (" .. tostring(reason) .. ")")
        elseif cmd == "record" then
            local name = (a ~= "" and a) or "route"
            print("Recording '" .. name .. "' while you drive...")
            local wps, reason = drive.manualLoop(drive.loadControl(), { recordName = name })
            if reason == "saved" then
                print("Saved " .. #wps .. " waypoints to " .. path.file(name))
            else
                print("Record ended: " .. tostring(reason))
            end
        elseif cmd == "follow" and a ~= "" then
            followNamed(a)
        elseif cmd == "dock" and a ~= "" then
            dockSession(cfg, a)
        elseif cmd == "run" then
            runRoute(cfg)
        elseif cmd == "pose" then
            local p = pose.get()
            print(string.format("pos=%.2f,%.2f,%.2f yaw=%.1fdeg", p.position.x, p.position.y, p.position.z, pose.yawDeg(p.yaw)))
        elseif cmd == "testagent" or cmd == "test_agent" or cmd == "realtime" then
            print("Starting realtime test agent (host: navigation/realtime_tests)...")
            shell.run("test_agent")
        else
            print("Unknown. control | calibrate | record <name> | stop | run | follow <path> | dock <port> | list | pose | testagent | quit")
        end
    end
end

-- main
-- Motors keep last RPM when the computer dies — always zero on boot.
print("Zeroing electric motors...")
drive.stopAllMotors({ drain_timeout = 0.75 })

local cfg = loadConfig()

local hasModem = protocol.open()
if hasModem then
    protocol.host(cfg.boat_id)
    print("Boat host: " .. cfg.boat_id)
else
    print("No wireless modem (ok for control/record/follow; needed for docks)")
end

local args = { ... }
if args[1] == "stop" or args[1] == "halt" then
    drive.allOff(nil, { scan_all = true })
    print("All thrusters / motors stopped")
elseif args[1] == "calibrate" or args[1] == "calib" then
    local rest = {}
    for i = 2, #args do
        rest[#rest + 1] = args[i]
    end
    runCalibrate(table.concat(rest, " "))
elseif args[1] == "run" then
    if not hasModem then
        print("Wireless modem required for run")
        return
    end
    runRoute(cfg)
elseif args[1] == "control" or args[1] == "manual" then
    drive.manualLoop(drive.loadControl(), {})
elseif args[1] == "record" then
    local name = args[2] or "route"
    local wps, reason = drive.manualLoop(drive.loadControl(), { recordName = name })
    if reason == "saved" then
        print("Saved " .. #wps .. " waypoints to " .. path.file(name))
    else
        print("Record ended: " .. tostring(reason))
    end
elseif args[1] == "testagent" or args[1] == "test_agent" or args[1] == "realtime" then
    shell.run("test_agent")
else
    menu(cfg)
end
