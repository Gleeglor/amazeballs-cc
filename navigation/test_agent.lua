-- Realtime host bridge: FS inbox/outbox (SP/sshfs) or HTTP poll (multiplayer).
-- Force-stops motors between cases + on watchdog.
--
-- Multiplayer: write /realtime_bridge.json { "mode":"http", "base_url":"http://HOST:8765" }
--   then host runs: npm run serve  (navigation/realtime_tests)
-- Singleplayer: omit that file (or mode=fs); host writes /realtime_inbox.json
-- Run: test_agent   or   boat → testagent
package.path = package.path .. ";/lib/?.lua;/lib/?/init.lua"

local util = require("util")
local drive = require("drive")
local pose = require("pose")

local INBOX = "/realtime_inbox.json"
local OUTBOX = "/realtime_outbox.json"
local STATUS = "/realtime_status.json"
local BRIDGE_CFG = "/realtime_bridge.json"
local POLL = 0.08
local WATCHDOG_SEC = 3.0
local HOLD_MAX_SEC = 8.0
-- Paths the host may overwrite via write_file / sync_tree (HTTP deploy).
local WRITE_ALLOW = {
    ["test_agent.lua"] = true,
    ["test_agent"] = true,
    ["boat.lua"] = true,
    ["calibrate.lua"] = true,
    ["stopmotors.lua"] = true,
    ["port.lua"] = true,
    ["startup"] = true,
    ["startup.lua"] = true,
    ["boat_config.json"] = true,
    ["lib/util.lua"] = true,
    ["lib/pose.lua"] = true,
    ["lib/drive.lua"] = true,
    ["lib/nav_calibrate.lua"] = true,
    ["lib/path.lua"] = true,
    ["lib/protocol.lua"] = true,
    ["lib/filters.lua"] = true,
    ["lib/xfer.lua"] = true,
    ["lib/schedule.lua"] = true,
    ["lib/ports.lua"] = true,
    ["lib/dock.lua"] = true,
    ["paths/to_port_a.json"] = true,
    ["paths/to_port_b.json"] = true,
    ["paths/a_to_b.json"] = true,
    ["paths/b_to_a.json"] = true,
}
-- Host may read these (config dump / resume).
local READ_ALLOW = {
    ["boat_control.json"] = true,
    ["boat_config.json"] = true,
    ["realtime_bridge.json"] = true,
    ["realtime_status.json"] = true,
}

local lastId = nil
local lastAlive = os.clock()
local thrusting = false
local running = true

-- Transport: "fs" (default) or "http"
local transport = {
    mode = "fs",
    base_url = nil,
    poll = POLL,
}

local function loadBridgeConfig()
    local cfg = util.readJSON(BRIDGE_CFG)
    if type(cfg) ~= "table" then
        return
    end
    local mode = string.lower(tostring(cfg.mode or "fs"))
    if mode == "http" then
        local base = tostring(cfg.base_url or cfg.baseUrl or "")
        base = string.gsub(base, "/+$", "")
        if base == "" then
            print("ERROR: /realtime_bridge.json mode=http needs base_url")
            return
        end
        transport.mode = "http"
        transport.base_url = base
        local p = tonumber(cfg.poll)
        if p and p >= 0.1 and p <= 2.0 then
            transport.poll = p
        else
            transport.poll = 0.3
        end
    end
end

local function httpFailMsg(kind, url, err, status)
    local bits = { kind, "failed" }
    if status then
        bits[#bits + 1] = "status=" .. tostring(status)
    end
    bits[#bits + 1] = "url=" .. tostring(url)
    bits[#bits + 1] = "err=" .. tostring(err or "?")
    return table.concat(bits, " ")
end

local function httpGetJson(url)
    if not http or not http.get then
        return nil, httpFailMsg("http.get", url, "http API unavailable")
    end
    local res, err = http.get(url, { ["Accept"] = "application/json" })
    if not res then
        return nil, httpFailMsg("http.get", url, err or "request failed")
    end
    local code = res.getResponseCode and res.getResponseCode() or nil
    local body = res.readAll()
    res.close()
    if code and (code < 200 or code >= 300) then
        return nil, httpFailMsg("http.get", url, "bad HTTP status", code)
    end
    if not body or body == "" then
        return nil, httpFailMsg("http.get", url, "empty body", code)
    end
    local ok, data = pcall(textutils.unserialiseJSON, body)
    if not ok or type(data) ~= "table" then
        return nil, httpFailMsg("http.get", url, "bad JSON", code)
    end
    return data
end

--- Make values safe for textutils.serialiseJSON (rejects NaN/inf/functions/cycles).
local function jsonSafe(v, seen, depth)
    depth = depth or 0
    if depth > 12 then
        return nil
    end
    local t = type(v)
    if t == "nil" or t == "boolean" or t == "string" then
        return v
    end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            return nil
        end
        return v
    end
    if t ~= "table" then
        return tostring(v)
    end
    seen = seen or {}
    if seen[v] then
        return nil
    end
    seen[v] = true
    local out = {}
    for k, val in pairs(v) do
        local kt = type(k)
        local key = k
        if kt ~= "string" and kt ~= "number" then
            key = tostring(k)
        end
        out[key] = jsonSafe(val, seen, depth + 1)
    end
    seen[v] = nil
    return out
end

local function httpPostJson(url, payload)
    if not http or not http.post then
        return false, httpFailMsg("http.post", url, "http API unavailable")
    end
    local safe = jsonSafe(payload)
    local okEnc, encoded = pcall(textutils.serialiseJSON, safe)
    if not okEnc then
        -- Last resort: strip result body so host still gets ok/error/id.
        local slim = {
            id = type(payload) == "table" and payload.id or nil,
            ok = type(payload) == "table" and payload.ok or false,
            cmd = type(payload) == "table" and payload.cmd or nil,
            error = (type(payload) == "table" and payload.error) or "encode failed",
            result = { encode_fallback = true },
            ts = os.epoch("utc"),
        }
        okEnc, encoded = pcall(textutils.serialiseJSON, slim)
        if not okEnc then
            return false, httpFailMsg("http.post", url, "encode failed")
        end
    end
    local res, err = http.post(url, encoded, {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
    })
    if not res then
        return false, httpFailMsg("http.post", url, err or "request failed")
    end
    local code = res.getResponseCode and res.getResponseCode() or nil
    res.close()
    if code and (code < 200 or code >= 300) then
        return false, httpFailMsg("http.post", url, "bad HTTP status", code)
    end
    return true
end

local function safeStop()
    pcall(function()
        drive.allOff(nil, { scan_all = true })
    end)
    thrusting = false
end

local function samplePose()
    local ok, craft = pcall(pose.get)
    if not ok or not craft then
        return nil, tostring(craft)
    end
    local velOk, vel = pcall(pose.getVelocity)
    local angOk, ang = pcall(pose.getAngularVelocity)
    local yawRate = 0
    if angOk and ang then
        yawRate = pose.yawRate(craft, ang)
    end
    local localV = { forward = 0, right = 0, up = 0 }
    if velOk and vel then
        localV = pose.worldToLocal(vel, craft)
    end
    return {
        x = craft.position.x,
        y = craft.position.y,
        z = craft.position.z,
        yaw = craft.yaw,
        yaw_deg = pose.yawDeg(craft.yaw),
        yaw_rate = yawRate,
        vel_forward = localV.forward,
        vel_right = localV.right,
        vel_up = localV.up,
    }
end

local function dutiesList(control, duties)
    local out = {}
    local n = 0
    if type(control) == "table" and type(control.thrusters) == "table" then
        n = #control.thrusters
    end
    if type(duties) == "table" then
        local m = #duties
        if m > n then
            n = m
        end
        -- Also cover sparse / object-like tables from JSON round-trips.
        for k, v in pairs(duties) do
            local i = tonumber(k)
            if i and i == math.floor(i) and i > n then
                n = i
            end
        end
    end
    for i = 1, n do
        local d = 0
        if type(duties) == "table" then
            d = tonumber(duties[i]) or 0
        end
        out[i] = d
    end
    return out
end

local function thrusterRows(control, duties)
    local rows = {}
    if not control or type(control.thrusters) ~= "table" then
        return rows
    end
    local sideOpts = { yaw_sign = drive.getYawSign(control) }
    for i, t in ipairs(control.thrusters) do
        rows[#rows + 1] = {
            i = i,
            name = t.name,
            kind = t.kind,
            facing = t.facing or t.role,
            fx = t.fx,
            fy = t.fy,
            tz = t.tz,
            side_score = t.side_score,
            duty = (duties and duties[i]) or 0,
            side = drive.thrusterSide(t, sideOpts),
        }
    end
    return rows
end

local function netFromDuties(control, duties)
    if not control or not duties then
        return { fx = 0, fy = 0, tz = 0 }
    end
    return drive.netWrench(control.thrusters, duties)
end

local function writeOut(payload)
    payload.ts = os.epoch("utc")
    if transport.mode == "http" then
        local ok, err = httpPostJson(transport.base_url .. "/v1/result", payload)
        if not ok then
            print(tostring(err))
        end
        return
    end
    util.writeJSON(OUTBOX, payload)
end

local function writeStatus(extra)
    local st = {
        alive = true,
        thrusting = thrusting,
        last_id = lastId,
        ts = os.epoch("utc"),
        computer_id = os.getComputerID and os.getComputerID() or nil,
        label = os.getComputerLabel and os.getComputerLabel() or nil,
        bridge = transport.mode,
    }
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            st[k] = v
        end
    end
    -- Always attach pose so host can smoke-test nav without superseding the cmd.
    if st.pose == nil then
        local p = samplePose()
        if p then
            st.pose = p
        end
    end
    if transport.mode == "http" then
        local ok, err = httpPostJson(transport.base_url .. "/v1/status", st)
        if not ok then
            print(tostring(err))
        end
        return
    end
    util.writeJSON(STATUS, st)
end

local function pollNextCommand()
    if transport.mode == "http" then
        local url = transport.base_url .. "/v1/cmd"
        local data, err = httpGetJson(url)
        if not data then
            print(tostring(err))
            return nil, err
        end
        if data.cmd == nil or data.cmd == false then
            return nil
        end
        if type(data) == "table" and data.id and data.cmd then
            return data
        end
        return nil
    end
    return util.readJSON(INBOX)
end

local function reply(req, ok, result, err)
    writeOut({
        id = req.id,
        ok = ok and true or false,
        cmd = req.cmd,
        result = result,
        error = err,
    })
end

local function doApply(control, fx, fy, tz)
    local ok, pathOrErr = drive.applyCommand(control, fx, fy, tz)
    drive.flushMotors(8)
    local duties = dutiesList(control, drive.getLastDuties())
    local motors = drive.getMotorSnapshot()
    return {
        apply_ok = ok and true or false,
        path = pathOrErr,
        duties = duties,
        motors = motors,
        thrusters = thrusterRows(control, duties),
        net = netFromDuties(control, duties),
        yaw_sign = drive.getYawSign(control),
        control_version = control and control.version or nil,
    }
end

--- Push pending motor RPMs with CCA anti-spam gaps (flushMotors alone only lands ~1/call).
local function drainMotors(budgetSec)
    if drive.drainMotorsBlocking then
        return drive.drainMotorsBlocking(budgetSec)
    end
    budgetSec = tonumber(budgetSec) or 1.0
    if budgetSec < 0.05 then
        budgetSec = 0.05
    end
    local t0 = os.clock()
    local writes = 0
    while os.clock() - t0 < budgetSec do
        if not drive.motorsPending() then
            break
        end
        local n = drive.flushMotors(1)
        writes = writes + (n or 0)
        sleep(0.03)
        lastAlive = os.clock()
    end
    return writes
end

local function wrapYawDelta(afterYaw, beforeYaw)
    local dyaw = (afterYaw or 0) - (beforeYaw or 0)
    while dyaw > math.pi do
        dyaw = dyaw - 2 * math.pi
    end
    while dyaw < -math.pi do
        dyaw = dyaw + 2 * math.pi
    end
    return dyaw
end

--- Normalize host path → relative under computer root; reject escapes.
local function safeDeployPath(raw)
    local p = tostring(raw or "")
    p = string.gsub(p, "\\", "/")
    p = string.gsub(p, "^/+", "")
    if p == "" or string.find(p, "%.%.") or string.find(p, ":") then
        return nil, "bad path"
    end
    if not WRITE_ALLOW[p] then
        return nil, "path not allowed: " .. p
    end
    return p
end

local function ensureParentDir(path)
    local dir = string.match(path, "^(.*)/[^/]+$")
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

local function softReloadLibs()
    safeStop()
    package.loaded["util"] = nil
    package.loaded["pose"] = nil
    package.loaded["drive"] = nil
    package.loaded["path"] = nil
    package.loaded["dock"] = nil
    package.loaded["ports"] = nil
    package.loaded["protocol"] = nil
    local nu = require("util")
    local np = require("pose")
    local nd = require("drive")
    -- ports/dock/path are require()'d per command after package.loaded clear
    for k in pairs(util) do
        util[k] = nil
    end
    for k, v in pairs(nu) do
        util[k] = v
    end
    for k in pairs(pose) do
        pose[k] = nil
    end
    for k, v in pairs(np) do
        pose[k] = v
    end
    for k in pairs(drive) do
        drive[k] = nil
    end
    for k, v in pairs(nd) do
        drive[k] = v
    end
    pcall(function()
        drive.stopAllMotors({ drain_timeout = 0.4 })
    end)
    return true
end

local function safeReadPath(raw)
    local p = tostring(raw or "")
    p = string.gsub(p, "\\", "/")
    p = string.gsub(p, "^/+", "")
    if p == "" or string.find(p, "%.%.") or string.find(p, ":") then
        return nil, "bad path"
    end
    if not READ_ALLOW[p] then
        return nil, "path not allowed: " .. p
    end
    return p
end

local function writeDeployFile(relPath, content, append)
    ensureParentDir(relPath)
    local mode = append and "a" or "w"
    local f, err = fs.open(relPath, mode)
    if not f then
        return false, tostring(err or "open failed")
    end
    f.write(tostring(content or ""))
    f.close()
    return true, fs.getSize(relPath)
end

local function handle(req)
    local cmd = string.lower(tostring(req.cmd or ""))
    if cmd == "ping" then
        reply(req, true, {
            pong = true,
            computer_id = os.getComputerID and os.getComputerID() or nil,
            label = os.getComputerLabel and os.getComputerLabel() or nil,
        })
        return
    end

    if cmd == "shutdown" or cmd == "quit" then
        safeStop()
        reply(req, true, { shutdown = true })
        running = false
        return
    end

    if cmd == "stop" then
        safeStop()
        reply(req, true, { stopped = true, motors = drive.getMotorSnapshot() })
        return
    end

    if cmd == "load_control" then
        safeStop()
        local control = drive.loadControl()
        if not control then
            reply(req, false, nil, "no boat_control.json (run calibrate)")
            return
        end
        local summary = {
            version = control.version,
            yaw_sign = drive.getYawSign(control),
            alloc_mode = control.alloc_mode or control.teleop_mode,
            com_compensate = control.com_compensate,
            n_thrusters = #(control.thrusters or {}),
            thrusters = thrusterRows(control, nil),
        }
        reply(req, true, summary)
        return
    end

    if cmd == "sample_pose" then
        local p, err = samplePose()
        if not p then
            reply(req, false, nil, err or "pose failed")
            return
        end
        reply(req, true, { pose = p })
        return
    end

    if cmd == "apply" then
        local control = drive.loadControl()
        if not control then
            reply(req, false, nil, "no boat_control.json")
            return
        end
        local fx = tonumber(req.fx) or 0
        local fy = tonumber(req.fy) or 0
        local tz = tonumber(req.tz) or 0
        thrusting = math.abs(fx) + math.abs(fy) + math.abs(tz) >= 1e-4
        local result = doApply(control, fx, fy, tz)
        local p = samplePose()
        result.pose = p
        reply(req, result.apply_ok, result, result.apply_ok and nil or tostring(result.path))
        if not thrusting then
            safeStop()
        end
        return
    end

    if cmd == "hold_apply" then
        local control = drive.loadControl()
        if not control then
            reply(req, false, nil, "no boat_control.json")
            return
        end
        local fx = tonumber(req.fx) or 0
        local fy = tonumber(req.fy) or 0
        local tz = tonumber(req.tz) or 0
        local seconds = tonumber(req.seconds) or 1.0
        if seconds < 0.2 then
            seconds = 0.2
        end
        if seconds > HOLD_MAX_SEC then
            seconds = HOLD_MAX_SEC
        end

        local before, berr = samplePose()
        if not before then
            reply(req, false, nil, berr or "pose before failed")
            return
        end

        thrusting = true
        local result = doApply(control, fx, fy, tz)
        if not result.apply_ok then
            safeStop()
            reply(req, false, result, tostring(result.path))
            return
        end

        -- Spin-up: CCA anti-spam only lands ~1 setRPM per flush; drain before timing the hold.
        local drainSec = math.min(1.25, math.max(0.35, seconds * 0.35))
        local drainWrites = drainMotors(drainSec)

        local t0 = os.clock()
        local peakAbsYawRate = 0
        local midSamples = 0
        while os.clock() - t0 < seconds do
            drive.applyCommand(control, fx, fy, tz)
            drainMotors(0.12)
            sleep(0.05)
            lastAlive = os.clock()
            local mid = samplePose()
            if mid then
                midSamples = midSamples + 1
                local wr = math.abs(tonumber(mid.yaw_rate) or 0)
                if wr > peakAbsYawRate then
                    peakAbsYawRate = wr
                end
            end
        end

        local after = samplePose()
        -- Snapshot motors while still commanded (safeStop clears sent/desired).
        local motorsEnd = drive.getMotorSnapshot()
        local pendingEnd = drive.motorsPending()
        safeStop()

        local dyaw = 0
        if after and before then
            dyaw = wrapYawDelta(after.yaw, before.yaw)
        end
        local dx, dy, dz = 0, 0, 0
        if after and before then
            dx = (after.x or 0) - (before.x or 0)
            dy = (after.y or 0) - (before.y or 0)
            dz = (after.z or 0) - (before.z or 0)
        end
        local localDelta = { forward = 0, right = 0, up = 0 }
        local craftOk, craft = pcall(pose.get)
        if craftOk and craft then
            localDelta = pose.worldToLocal({ x = dx, y = dy, z = dz }, craft)
        end

        result.hold_seconds = seconds
        result.drain_seconds = drainSec
        result.drain_writes = drainWrites
        result.mid_samples = midSamples
        result.pose_before = before
        result.pose_after = after
        result.delta_yaw = dyaw
        result.delta_yaw_deg = dyaw * 180 / math.pi
        result.delta_x = dx
        result.delta_y = dy
        result.delta_z = dz
        result.delta_horiz = math.sqrt(dx * dx + dz * dz)
        result.delta_forward = localDelta.forward
        result.delta_right = localDelta.right
        result.motors = motorsEnd
        result.motors_pending = pendingEnd and true or false
        if after then
            result.yaw_rate_end = after.yaw_rate
        end
        result.yaw_rate_peak_abs = peakAbsYawRate
        reply(req, true, result)
        return
    end

    if cmd == "write_file" then
        local rel, perr = safeDeployPath(req.path)
        if not rel then
            reply(req, false, nil, perr)
            return
        end
        local content = req.content
        if content == nil then
            reply(req, false, nil, "need content")
            return
        end
        local okW, sizeOrErr = writeDeployFile(rel, content, req.append and true or false)
        if not okW then
            reply(req, false, nil, tostring(sizeOrErr))
            return
        end
        reply(req, true, { path = rel, size = sizeOrErr, append = req.append and true or false })
        return
    end

    if cmd == "sync_tree" then
        local files = req.files
        if type(files) ~= "table" then
            reply(req, false, nil, "need files=[{path,content},...]")
            return
        end
        local written = {}
        local n = 0
        for _, entry in ipairs(files) do
            if type(entry) == "table" then
                local rel, perr = safeDeployPath(entry.path)
                if not rel then
                    reply(req, false, { written = written }, perr)
                    return
                end
                local okW, sizeOrErr = writeDeployFile(rel, entry.content, false)
                if not okW then
                    reply(req, false, { written = written, failed = rel }, tostring(sizeOrErr))
                    return
                end
                n = n + 1
                written[n] = { path = rel, size = sizeOrErr }
            end
        end
        -- Also accept object-map { "lib/drive.lua": "..." } from JSON hosts
        if n == 0 then
            for pathKey, content in pairs(files) do
                if type(pathKey) == "string" and type(content) == "string" then
                    local rel, perr = safeDeployPath(pathKey)
                    if not rel then
                        reply(req, false, { written = written }, perr)
                        return
                    end
                    local okW, sizeOrErr = writeDeployFile(rel, content, false)
                    if not okW then
                        reply(req, false, { written = written, failed = rel }, tostring(sizeOrErr))
                        return
                    end
                    n = n + 1
                    written[n] = { path = rel, size = sizeOrErr }
                end
            end
        end
        reply(req, true, { n = n, written = written })
        return
    end

    if cmd == "reboot" or cmd == "restart_agent" then
        -- ALWAYS (re)write startup before reboot — never strand at craft shell.
        local f = fs.open("startup", "w")
        if f then
            f.write('shell.run("test_agent")\n')
            f.close()
        end
        local f2 = fs.open("startup.lua", "w")
        if f2 then
            f2.write('shell.run("test_agent")\n')
            f2.close()
        end
        reply(req, true, { rebooting = true, note = "os.reboot — startup/startup.lua → test_agent" })
        sleep(0.4)
        os.reboot()
        return
    end

    if cmd == "reload_libs" or cmd == "soft_reload" then
        local okR, errR = pcall(softReloadLibs)
        if not okR then
            reply(req, false, nil, tostring(errR))
            return
        end
        reply(req, true, { reloaded = true })
        return
    end

    if cmd == "read_file" then
        local rel, perr = safeReadPath(req.path)
        if not rel then
            reply(req, false, nil, perr)
            return
        end
        if not fs.exists(rel) then
            reply(req, false, nil, "missing: " .. rel)
            return
        end
        local f = fs.open(rel, "r")
        if not f then
            reply(req, false, nil, "open failed")
            return
        end
        local content = f.readAll()
        f.close()
        reply(req, true, { path = rel, content = content, size = #tostring(content or "") })
        return
    end

    -- Navigate toward world XZ. Soft arrive ≤20. Shore landmarks remap to water holds.
    if cmd == "navigate_to" or cmd == "go_dock" then
        local control = drive.loadControl()
        if not control then
            reply(req, false, nil, "no boat_control.json")
            return
        end
        local before, berr = samplePose()
        if not before then
            reply(req, false, nil, berr or "pose failed")
            return
        end
        local tx = tonumber(req.x) or 341
        local tz = tonumber(req.z) or 163
        local ty = tonumber(req.y) or before.y
        -- SAFETY: remap shore landmarks → offshore water hold.
        do
            package.loaded["ports"] = nil
            local portsMod = require("ports")
            local sx, sz = 341, 163
            local sx2, sz2 = 383, 285
            if (math.abs(tx - sx) < 4 and math.abs(tz - sz) < 4)
                or (math.abs(tx - sx2) < 4 and math.abs(tz - sz2) < 4)
            then
                local port = portsMod.get((math.abs(tx - sx) < 4) and "port_a" or "port_b")
                local hold = portsMod.holdOf(port)
                if hold then
                    tx, tz = hold.x, hold.z
                end
            end
        end
        local timeout = tonumber(req.timeout) or 180
        if timeout > 420 then
            timeout = 420
        end
        if timeout < 5 then
            timeout = 5
        end
        local arriveDist = tonumber(req.arrive_dist) or 20
        if arriveDist < 16 then
            arriveDist = 20
        end
        local mode = req.mode or "cruise"
        if mode == "dock" then
            mode = "creep"
        end
        local target = { x = tx, y = ty, z = tz }
        if req.yaw ~= nil then
            target.yaw = tonumber(req.yaw)
        elseif req.yaw_deg ~= nil then
            target.yaw = math.rad(tonumber(req.yaw_deg) or 0)
        end
        local pid = drive.newPidStates()
        thrusting = true
        local t0 = os.clock()
        local lastErr = nil
        local arrived = false
        local lastBeat = 0
        while os.clock() - t0 < timeout do
            lastAlive = os.clock()
            if (os.clock() - lastBeat) >= 0.8 then
                writeStatus({
                    last_cmd = "navigate_to",
                    nav = true,
                    mode = mode,
                    target = { x = tx, z = tz },
                    gentle = true,
                })
                lastBeat = os.clock()
            end
            local okStep, errOrMsg, arr = pcall(function()
                return drive.stepToward(control, target, mode, pid, 0.15)
            end)
            if not okStep then
                safeStop()
                reply(req, false, { pose = samplePose() }, tostring(errOrMsg))
                return
            end
            lastErr = errOrMsg
            arrived = arr
            drive.flushMotors(4)
            if arrived or (lastErr and (lastErr.distance or 99) <= arriveDist) then
                arrived = true
                break
            end
            sleep(0.15)
        end
        safeStop()
        local after = samplePose()
        reply(req, true, {
            arrived = arrived and true or false,
            target = target,
            timeout = timeout,
            elapsed = os.clock() - t0,
            distance = lastErr and lastErr.distance or nil,
            err = lastErr,
            pose_before = before,
            pose_after = after,
            gentle = true,
        })
        return
    end

    if cmd == "list_ports" then
        package.loaded["ports"] = nil
        local portsMod = require("ports")
        reply(req, true, {
            boat_dock = portsMod.BOAT_DOCK,
            ports = portsMod.list(),
        })
        return
    end

    if cmd == "handshake_stub" or cmd == "dock_handshake" then
        package.loaded["dock"] = nil
        package.loaded["ports"] = nil
        package.loaded["protocol"] = nil
        local dockMod = require("dock")
        local portId = tostring(req.port or req.port_id or "port_a")
        local boatId = tostring(req.boat_id or "boat1")
        local okH, result = dockMod.handshakeStub(boatId, portId, {
            timeout = tonumber(req.timeout) or 12,
            stub_sleep = tonumber(req.stub_sleep) or 0.4,
        })
        reply(req, okH and true or false, result, okH and nil or (result and result.error))
        return
    end

    -- Full port call: cruise → berth_align → docking_port handshake stub.
    if cmd == "go_port" or cmd == "dual_dock_leg" then
        local control = drive.loadControl()
        if not control then
            reply(req, false, nil, "no boat_control.json")
            return
        end
        package.loaded["ports"] = nil
        package.loaded["dock"] = nil
        package.loaded["protocol"] = nil
        local portsMod = require("ports")
        local dockMod = require("dock")
        local port = portsMod.get(req.port or req.port_id or req.id)
        if not port then
            reply(req, false, nil, "unknown port (use port_a / port_b)")
            return
        end
        local before, berr = samplePose()
        if not before then
            reply(req, false, nil, berr or "pose failed")
            return
        end
        local cruiseTimeout = tonumber(req.timeout) or 300
        if cruiseTimeout > 420 then
            cruiseTimeout = 420
        end
        local berthTimeout = tonumber(req.berth_timeout) or 60
        local arriveDist = tonumber(req.arrive_dist) or port.arrive_dist or 20
        if arriveDist < 16 then
            arriveDist = 20
        end
        local skipHandshake = req.handshake == false or req.skip_handshake == true
        local doApproach = req.approach ~= false

        local function runNav(target, mode, timeout, distLim)
            local pid = drive.newPidStates()
            thrusting = true
            local t0 = os.clock()
            local lastBeat = 0
            local lastErr, arrived = nil, false
            while os.clock() - t0 < timeout do
                lastAlive = os.clock()
                -- Abort if host raised /v1/abort (does not claim inbox cmds).
                do
                    local abortFlag = httpGetJson(transport.base_url .. "/v1/abort")
                    if type(abortFlag) == "table" and abortFlag.abort then
                        safeStop()
                        return false, { distance = 999, aborted = true }, os.clock() - t0
                    end
                end
                -- Keep HTTP /v1/status fresh so host does not declare agent dead mid-leg.
                if (os.clock() - lastBeat) >= 0.8 then
                    writeStatus({
                        last_cmd = "go_port",
                        nav = true,
                        mode = mode,
                        target = { x = target.x, z = target.z },
                    })
                    lastBeat = os.clock()
                end
                local okStep, errOrMsg, arr = pcall(function()
                    return drive.stepToward(control, target, mode, pid, 0.15)
                end)
                if not okStep then
                    safeStop()
                    return false, tostring(errOrMsg), nil
                end
                lastErr, arrived = errOrMsg, arr
                drive.flushMotors(4)
                if arrived or (lastErr and (lastErr.distance or 99) <= distLim) then
                    return true, lastErr, os.clock() - t0
                end
                sleep(0.15)
            end
            safeStop()
            return (lastErr and (lastErr.distance or 99) <= distLim * 1.4), lastErr, os.clock() - t0
        end

        local phases = {}
        -- SAFETY: never navigate to shore landmark. Soft hold = offshore water only.
        -- Reached if horiz ≤ ~20 of water hold. Gentle cruise / creep only.
        local hold = portsMod.holdOf(port)
        local softArrive = tonumber(req.arrive_dist) or port.arrive_dist
            or (portsMod.SAFETY and portsMod.SAFETY.soft_arrive_dist) or 20
        local softTol = port.dock_tol or (portsMod.SAFETY and portsMod.SAFETY.soft_tol) or 20
        if softArrive < 16 then softArrive = 20 end
        if softTol < 16 then softTol = 20 end

        local function horizToHold(pose)
            if not pose or not hold then
                return 999
            end
            local dx = (pose.x or 0) - hold.x
            local dz = (pose.z or 0) - hold.z
            return math.sqrt(dx * dx + dz * dz)
        end

        local okB = false
        local errB, elB = nil, 0
        if horizToHold(before) <= softTol then
            safeStop()
            okB = true
            phases[#phases + 1] = {
                phase = "soft_water_hold",
                ok = true,
                skipped = true,
                reason = "already_within_20",
                distance = horizToHold(before),
                target = hold,
            }
        else
            -- Prefer direct cruise to WATER HOLD. Only use farther approach when it
            -- is clearly closer than the hold (avoids driving away from a mid-corridor boat).
            local ap = portsMod.approachOf(port)
            local dHold0 = horizToHold(before)
            local dAp = 999
            if ap then
                local dx = (before.x or 0) - ap.x
                local dz = (before.z or 0) - ap.z
                dAp = math.sqrt(dx * dx + dz * dz)
            end
            if doApproach and ap and dAp + 10 < dHold0 then
                ap.y = before.y
                local okA, errA, elA = runNav(ap, "cruise", math.min(cruiseTimeout, 240), softArrive)
                phases[#phases + 1] = {
                    phase = "approach_water",
                    ok = okA,
                    elapsed = elA,
                    distance = errA and errA.distance,
                    target = { x = ap.x, z = ap.z },
                }
            end
            local mid = samplePose()
            if mid and horizToHold(mid) <= softTol then
                safeStop()
                okB = true
                phases[#phases + 1] = {
                    phase = "soft_water_hold",
                    ok = true,
                    skipped = true,
                    reason = "within_20_after_approach",
                    distance = horizToHold(mid),
                }
            else
                local waterHold = {
                    x = hold.x,
                    y = before.y,
                    z = hold.z,
                    yaw = hold.yaw or port.yaw,
                }
                -- Gentle cruise toward hold, then creep polish.
                local okC, errC, elC = runNav(waterHold, "cruise", math.min(cruiseTimeout, 300), softArrive)
                phases[#phases + 1] = {
                    phase = "cruise_to_hold",
                    ok = okC,
                    elapsed = elC,
                    distance = errC and errC.distance,
                    target = { x = waterHold.x, z = waterHold.z },
                }
                local mid2 = samplePose()
                if mid2 and horizToHold(mid2) <= softTol then
                    safeStop()
                    okB = true
                    errB, elB = errC, elC
                else
                    okB, errB, elB = runNav(waterHold, "creep", math.max(berthTimeout, 180), softTol)
                    phases[#phases + 1] = {
                        phase = "soft_water_hold",
                        ok = okB,
                        elapsed = elB,
                        distance = errB and errB.distance,
                        yaw_err = errB and errB.yaw,
                        target = { x = waterHold.x, z = waterHold.z },
                        shore_landmark = { x = port.shore_x or port.x, z = port.shore_z or port.z },
                    }
                end
            end
            safeStop()
        end

        local handshake = nil
        if not skipHandshake then
            local okH, hs = dockMod.handshakeStub(tostring(req.boat_id or "boat1"), port.id, {
                timeout = tonumber(req.handshake_timeout) or 10,
            })
            handshake = hs
            handshake.ok = okH and hs.ok
            phases[#phases + 1] = { phase = "handshake", ok = handshake.ok, mode = hs.mode }
        end

        local after = samplePose()
        local distFinal = horizToHold(after)
        local arrived = okB or (distFinal <= softTol)
        if arrived then
            safeStop()
        end
        reply(req, true, {
            port_id = port.id,
            soft_dock = true,
            water_hold = { x = hold.x, z = hold.z, yaw = hold.yaw },
            shore_landmark = { x = port.shore_x or port.x, z = port.shore_z or port.z },
            arrived = arrived and true or false,
            distance = distFinal,
            soft_tol = softTol,
            phases = phases,
            handshake = handshake and { ok = handshake.ok, mode = handshake.mode } or nil,
            pose_before = before,
            pose_after = after,
            safety = "soft_water_hold_horiz_le_20_gentle",
        })
        return
    end

    -- Soft water hold only (NOT exact shore coords). Optional yaw nudge in cruise.
    if cmd == "berth_align" or cmd == "hold_pose" then
        local control = drive.loadControl()
        if not control then
            reply(req, false, nil, "no boat_control.json")
            return
        end
        package.loaded["ports"] = nil
        local portsMod = require("ports")
        local before, berr = samplePose()
        if not before then
            reply(req, false, nil, berr or "pose failed")
            return
        end
        -- If port id given, use water hold; else treat x/z as already a water target.
        local hold = nil
        if req.port or req.port_id then
            local port = portsMod.get(req.port or req.port_id)
            if port then
                hold = portsMod.holdOf(port)
            end
        end
        local tx = hold and hold.x or tonumber(req.x) or before.x
        local tz = hold and hold.z or tonumber(req.z) or before.z
        local ty = tonumber(req.y) or before.y
        local tyaw = hold and hold.yaw or tonumber(req.yaw)
        if tyaw == nil and req.yaw_deg ~= nil then
            tyaw = math.rad(tonumber(req.yaw_deg) or 0)
        end
        -- Refuse known shore landmarks as final targets (force offshore).
        local sx, sz = 341, 163
        local sx2, sz2 = 383, 285
        if (math.abs(tx - sx) < 3 and math.abs(tz - sz) < 3)
            or (math.abs(tx - sx2) < 3 and math.abs(tz - sz2) < 3)
        then
            local port = portsMod.get((math.abs(tx - sx) < 3) and "port_a" or "port_b")
            hold = portsMod.holdOf(port)
            tx, tz = hold.x, hold.z
            tyaw = hold.yaw
        end
        local timeout = tonumber(req.timeout) or 40
        if timeout > 90 then
            timeout = 90
        end
        local target = { x = tx, y = ty, z = tz, yaw = tyaw }
        local pid = drive.newPidStates()
        thrusting = true
        local t0 = os.clock()
        local lastErr, arrived = nil, false
        local softTol = (portsMod.SAFETY and portsMod.SAFETY.soft_tol) or 20
        if softTol < 16 then softTol = 20 end
        while os.clock() - t0 < timeout do
            lastAlive = os.clock()
            writeStatus({ last_cmd = "berth_align", soft = true, target = { x = tx, z = tz } })
            local okStep, errOrMsg, arr = pcall(function()
                return drive.stepToward(control, target, "creep", pid, 0.12)
            end)
            if not okStep then
                safeStop()
                reply(req, false, { pose = samplePose() }, tostring(errOrMsg))
                return
            end
            lastErr, arrived = errOrMsg, arr
            drive.flushMotors(4)
            if arrived or (lastErr and (lastErr.distance or 99) <= softTol) then
                arrived = true
                break
            end
            sleep(0.12)
        end
        safeStop()
        reply(req, true, {
            arrived = arrived and true or false,
            soft_dock = true,
            target = target,
            elapsed = os.clock() - t0,
            err = lastErr,
            pose_before = before,
            pose_after = samplePose(),
            safety = "soft_water_hold_only_never_shore",
            handshake = {
                kind = "psi_stub",
                note = "No exact shore align — open-water hold only",
            },
        })
        return
    end

    if cmd == "follow_path" then
        local control = drive.loadControl()
        if not control then
            reply(req, false, nil, "no boat_control.json")
            return
        end
        local name = tostring(req.name or req.path or "")
        name = string.gsub(name, "%.json$", "")
        if name == "" then
            reply(req, false, nil, "need name=")
            return
        end
        package.loaded["path"] = nil
        local pathMod = require("path")
        local data = pathMod.load(name)
        if not data then
            reply(req, false, nil, "missing path: " .. name)
            return
        end
        thrusting = true
        local before = samplePose()
        local okF, reason = drive.followPath(control, data.waypoints, {
            engage_distance = tonumber(req.engage_distance) or 22,
            arrive_dist = tonumber(req.arrive_dist) or 20,
            timeout = tonumber(req.timeout) or 240,
        })
        safeStop()
        reply(req, okF and true or false, {
            name = name,
            reason = reason,
            pose_before = before,
            pose_after = samplePose(),
            n_waypoints = #(data.waypoints or {}),
        }, okF and nil or tostring(reason))
        return
    end

    reply(req, false, nil, "unknown cmd: " .. tostring(req.cmd))
end

-- Boot: always stop motors first.
loadBridgeConfig()
-- Survive reboots: ensure craft shell re-enters the agent.
pcall(function()
    if not fs.exists("startup") and not fs.exists("startup.lua") then
        local f = fs.open("startup", "w")
        if f then
            f.write('shell.run("test_agent")\n')
            f.close()
            print("Wrote /startup -> test_agent")
        end
    end
end)
print("Realtime test agent")
if transport.mode == "http" then
    print("  mode    http")
    print("  base    " .. tostring(transport.base_url))
    print("  poll    " .. tostring(transport.poll) .. "s")
    if string.find(tostring(transport.base_url or ""), "127%.0%.0%.1", 1, false)
        or string.find(tostring(transport.base_url or ""), "localhost", 1, true)
    then
        print("ERROR: base_url is loopback — MC server will never reach your PC.")
        print("  Use player PC LAN IP (same LAN) or a public tunnel URL (remote VPS).")
    end
    if not http then
        print("ERROR: http API disabled — ask server admin to enable CC http + whitelist host")
    else
        print("  HTTP errors print every poll (status + URL) — watch this screen.")
    end
else
    print("  mode    fs")
    print("  inbox   " .. INBOX)
    print("  outbox  " .. OUTBOX)
end
print("  Q / shutdown command stops agent")
print("Zeroing motors...")
safeStop()
writeStatus({ boot = true })

local quitKey = keys.q
local pollSec = transport.poll or POLL
local statusEvery = 0
local STATUS_INTERVAL = 1.0

while running do
    local timer = os.startTimer(pollSec)
    while true do
        local ev = { os.pullEventRaw() }
        if ev[1] == "terminate" then
            running = false
            break
        elseif ev[1] == "key" and ev[2] == quitKey then
            print("Quit key")
            running = false
            break
        elseif ev[1] == "timer" and ev[2] == timer then
            break
        end
    end
    if not running then
        break
    end

    -- Watchdog: host died while thrusting
    if thrusting and (os.clock() - lastAlive) > WATCHDOG_SEC then
        print("Watchdog: stopping thrusters")
        safeStop()
        writeStatus({ watchdog = true })
    end

    local req = pollNextCommand()
    if type(req) == "table" and req.id and req.id ~= lastId and req.cmd then
        lastId = req.id
        lastAlive = os.clock()
        print(string.format("cmd %s id=%s", tostring(req.cmd), tostring(req.id)))
        local ok, err = pcall(handle, req)
        if not ok then
            writeOut({
                id = req.id,
                ok = false,
                cmd = req.cmd,
                error = tostring(err),
                ts = os.epoch("utc"),
            })
            safeStop()
        end
        if transport.mode == "fs" then
            pcall(function()
                if fs.exists(INBOX) then
                    fs.delete(INBOX)
                end
            end)
        end
        writeStatus({ last_cmd = req.cmd })
        statusEvery = os.clock()
    else
        -- Heartbeat: FS every poll; HTTP ~1/s to avoid flooding.
        if transport.mode == "fs" or (os.clock() - statusEvery) >= STATUS_INTERVAL then
            writeStatus({})
            statusEvery = os.clock()
        end
    end
end

safeStop()
writeStatus({ alive = false, shutdown = true })
print("Agent stopped; motors zeroed.")
