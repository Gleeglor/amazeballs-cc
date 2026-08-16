-- Boat live agent: websocket RPC + watchdog. Boot this after updater.
-- package.path for /lib when files land as boat/lib/*.lua with dest under /lib
-- Prefer /lib so boot programs named like calibrate never shadow library modules.
package.path = "/lib/?.lua;/lib/?/init.lua;./lib/?.lua;" .. package.path

local util = require("util")
local motors = require("motors")
local pose = require("pose")
local ui = require("ui")
local calibrate = require("boat_calibrate")
local teleop = require("teleop")
local dock = require("dock")
local route = require("route")

local REPO_BASE = "https://raw.githubusercontent.com/gleeglor/amazeballs-cc/main/"
local RENDEZVOUS_URL = REPO_BASE .. "boat/rendezvous.json"
local LOCAL_AGENT = "/agent.json"

local function resolveWsUrl()
    local localCfg = util.readJSON(LOCAL_AGENT)
    if localCfg and type(localCfg.wss) == "string" and localCfg.wss ~= "" then
        return localCfg.wss
    end
    local body = util.httpGet(RENDEZVOUS_URL)
    if body then
        local ok, data = pcall(textutils.unserialiseJSON, body)
        if ok and type(data) == "table" and type(data.wss) == "string" and data.wss ~= "" then
            return data.wss
        end
    end
    return nil
end

local function send(ws, obj)
    local ok, encoded = pcall(textutils.serialiseJSON, obj)
    if ok and ws then
        pcall(function()
            ws.send(encoded)
        end)
    end
end

local function reply(ws, id, okFlag, result, err)
    send(ws, {
        type = "reply",
        id = id,
        ok = okFlag and true or false,
        result = result,
        error = err,
    })
end

local function getPoseSnapshot()
    local craft = pose.get()
    if not craft then
        return nil
    end
    local spd, localV = pose.speed(craft)
    return {
        x = craft.x,
        y = craft.y,
        z = craft.z,
        yaw = craft.yaw,
        speed = spd,
        local_vel = localV,
        yaw_rate = pose.yawRate(craft),
    }
end

local function handleRpc(ws, msg)
    local id = msg.id
    local method = msg.method
    local params = msg.params or {}

    if method == "ping" then
        reply(ws, id, true, { pong = true, t = util.now() })
    elseif method == "stop" then
        motors.panic(5)
        reply(ws, id, true, { stopped = true })
    elseif method == "pose" then
        reply(ws, id, true, getPoseSnapshot())
    elseif method == "telemetry" then
        reply(ws, id, true, {
            pose = getPoseSnapshot(),
            ws = "up",
            mode = ui.mode,
            dock = select(1, dock.isLocked()),
        })
    elseif method == "put_file" then
        local path = params.path
        local data = params.data
        if type(path) ~= "string" or type(data) ~= "string" then
            reply(ws, id, false, nil, "path/data required")
        else
            local ok, err = util.writeFile(path, data)
            reply(ws, id, ok, { path = path, bytes = #data }, err)
        end
    elseif method == "get_file" then
        local path = params.path
        local data = util.readFile(path)
        if data == nil then
            reply(ws, id, false, nil, "missing")
        else
            reply(ws, id, true, { path = path, data = data })
        end
    elseif method == "exec" then
        local code = params.code
        if type(code) ~= "string" then
            reply(ws, id, false, nil, "code required")
        else
            local fn, err = load(code, "exec", "t", _ENV)
            if not fn then
                reply(ws, id, false, nil, err)
            else
                local ok, res = pcall(fn)
                if ok then
                    reply(ws, id, true, res)
                else
                    reply(ws, id, false, nil, tostring(res))
                end
            end
        end
    elseif method == "calibrate" then
        ui.setMode("calib")
        local ok, res = pcall(function()
            return calibrate.run(params)
        end)
        motors.panic(3)
        ui.setMode("idle")
        if ok and res then
            reply(ws, id, true, { thrusters = #(res.thrusters or {}) })
        else
            reply(ws, id, false, nil, tostring(res or "calibrate failed"))
        end
    elseif method == "go" then
        local cruise = require("cruise")
        ui.setMode("route")
        local ok, res = pcall(function()
            return cruise.goPlace(params.place)
        end)
        motors.panic(3)
        ui.setMode("idle")
        if ok and res then
            reply(ws, id, true, { arrived = true })
        else
            reply(ws, id, false, nil, tostring(res or "go failed"))
        end
    elseif method == "run_tests" then
        local suite = params.suite or "all"
        local results = {}
        local function runFile(path)
            if not fs.exists(path) then
                return { ok = false, error = "missing " .. path }
            end
            local ok, err = pcall(function()
                shell.run(path)
            end)
            return { ok = ok, error = ok and nil or tostring(err) }
        end
        if suite == "all" or suite == "live" then
            results.live = runFile("/tests/live_smoke.lua")
        end
        ui.setLastTest(textutils.serialiseJSON(results))
        reply(ws, id, true, results)
    elseif method == "set_duties" then
        local control = calibrate.load()
        if not control or not control.thrusters then
            reply(ws, id, false, nil, "no calib")
        else
            local thrByName = {}
            for _, t in ipairs(control.thrusters) do
                thrByName[t.name] = t
                motors.setDesired(t.name, 0)
            end
            motors.applyDuties(params.duties or {}, thrByName)
            motors.drain(3)
            reply(ws, id, true, { ok = true })
        end
    else
        reply(ws, id, false, nil, "unknown method " .. tostring(method))
    end
end

local function agentLoop(ws)
    ui.setWs("up")
    ui.setMode("agent")
    send(ws, { type = "hello", role = "boat", version = 1 })
    local heartbeat = os.startTimer(2)
    while true do
        local e, a, b = os.pullEvent()
        if e == "timer" and a == heartbeat then
            send(ws, { type = "heartbeat", t = util.now(), pose = getPoseSnapshot() })
            heartbeat = os.startTimer(2)
            local craft = pose.get()
            ui.draw({
                x = craft and craft.x,
                y = craft and craft.y,
                z = craft and craft.z,
                yaw = craft and craft.yaw,
                speed = craft and select(1, pose.speed(craft)),
                dock = select(1, dock.isLocked()),
            })
        elseif e == "websocket_message" then
            -- a is url, b is message on some CC versions; on others a is message
            local raw = b or a
            if type(raw) == "string" then
                local ok, msg = pcall(textutils.unserialiseJSON, raw)
                if ok and type(msg) == "table" then
                    if msg.type == "rpc" or msg.method then
                        local ok2, err = pcall(handleRpc, ws, msg)
                        if not ok2 then
                            reply(ws, msg.id, false, nil, tostring(err))
                        end
                    end
                end
            end
        elseif e == "websocket_closed" then
            return "closed"
        elseif e == "key" and a == keys.x then
            motors.panic(3)
        elseif e == "key" and a == keys.t and not b then
            -- local teleop interrupt
            pcall(teleop.run)
            ui.setMode("agent")
        elseif e == "key" and a == keys.c and not b then
            pcall(function()
                calibrate.run({})
            end)
            motors.panic(3)
        end
    end
end

local function main()
    print("Boat agent starting...")
    motors.panic(5)
    ui.setMode("agent")
    while true do
        local url = resolveWsUrl()
        if not url then
            ui.setWs("no-url")
            ui.setStatus("No wss in rendezvous.json or /agent.json")
            ui.draw({})
            print("No websocket URL. Place /agent.json {\"wss\":\"wss://...\"} or push boat/rendezvous.json")
            print("Local menu: C=calibrate T=teleop X=stop")
            local timer = os.startTimer(5)
            while true do
                local e, a, b = os.pullEvent()
                if e == "timer" and a == timer then
                    break
                elseif e == "key" and a == keys.c and not b then
                    pcall(function()
                        calibrate.run({})
                    end)
                    motors.panic(3)
                elseif e == "key" and a == keys.t and not b then
                    pcall(teleop.run)
                elseif e == "key" and a == keys.x then
                    motors.panic(3)
                end
            end
        else
            ui.setStatus("Connecting " .. url)
            ui.draw({})
            print("Connecting " .. url)
            if not http or not http.websocket then
                print("http.websocket unavailable")
                sleep(5)
            else
                local ws, err = http.websocket(url)
                if not ws then
                    print("WS fail: " .. tostring(err))
                    ui.setWs("fail")
                    motors.panic(3)
                    sleep(2)
                else
                    print("WS connected")
                    local ok, reason = pcall(agentLoop, ws)
                    pcall(function()
                        ws.close()
                    end)
                    motors.panic(5)
                    ui.setWs("down")
                    print("WS ended: " .. tostring(reason or ok))
                    sleep(2)
                end
            end
        end
    end
end

main()
