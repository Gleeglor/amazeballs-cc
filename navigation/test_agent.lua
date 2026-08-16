-- Realtime host bridge: poll /realtime_inbox.json, run drive/pose commands,
-- write /realtime_outbox.json. Force-stops motors between cases + on watchdog.
--
-- Host (outside Minecraft) writes inbox; this agent replies on outbox.
-- Run: test_agent   or   boat → testagent
package.path = package.path .. ";/lib/?.lua;/lib/?/init.lua"

local util = require("util")
local drive = require("drive")
local pose = require("pose")

local INBOX = "/realtime_inbox.json"
local OUTBOX = "/realtime_outbox.json"
local STATUS = "/realtime_status.json"
local POLL = 0.08
local WATCHDOG_SEC = 3.0
local HOLD_MAX_SEC = 4.0

local lastId = nil
local lastAlive = os.clock()
local thrusting = false
local running = true

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
    }
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            st[k] = v
        end
    end
    util.writeJSON(STATUS, st)
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
    local duties = drive.getLastDuties()
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

        local t0 = os.clock()
        while os.clock() - t0 < seconds do
            -- Keep duties alive (CCA can drop); re-apply lightly each tick.
            drive.applyCommand(control, fx, fy, tz)
            drive.flushMotors(4)
            sleep(0.1)
            lastAlive = os.clock()
        end

        local after = samplePose()
        safeStop()

        local dyaw = 0
        if after and before then
            dyaw = (after.yaw or 0) - (before.yaw or 0)
            while dyaw > math.pi do
                dyaw = dyaw - 2 * math.pi
            end
            while dyaw < -math.pi do
                dyaw = dyaw + 2 * math.pi
            end
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
        if after then
            result.yaw_rate_end = after.yaw_rate
        end
        reply(req, true, result)
        return
    end

    -- Navigate toward world XZ (base dock default 340,165). Uses drive.stepToward.
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
        local tx = tonumber(req.x) or 340
        local tz = tonumber(req.z) or 165
        local ty = tonumber(req.y) or before.y
        local timeout = tonumber(req.timeout) or 90
        if timeout > 180 then
            timeout = 180
        end
        if timeout < 5 then
            timeout = 5
        end
        local arriveDist = tonumber(req.arrive_dist) or 3.5
        local mode = req.mode or "cruise"
        local target = { x = tx, y = ty, z = tz }
        local pid = drive.newPidStates()
        thrusting = true
        local t0 = os.clock()
        local lastErr = nil
        local arrived = false
        while os.clock() - t0 < timeout do
            lastAlive = os.clock()
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
        })
        return
    end

    reply(req, false, nil, "unknown cmd: " .. tostring(req.cmd))
end

-- Boot: always stop motors first.
print("Realtime test agent")
print("  inbox  " .. INBOX)
print("  outbox " .. OUTBOX)
print("  Q / shutdown command stops agent")
print("Zeroing motors...")
safeStop()
writeStatus({ boot = true })

local quitKey = keys.q

while running do
    local timer = os.startTimer(POLL)
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

    local req = util.readJSON(INBOX)
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
        pcall(function()
            if fs.exists(INBOX) then
                fs.delete(INBOX)
            end
        end)
        writeStatus({ last_cmd = req.cmd })
    else
        writeStatus({})
    end
end

safeStop()
writeStatus({ alive = false, shutdown = true })
print("Agent stopped; motors zeroed.")
