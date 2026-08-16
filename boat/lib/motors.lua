-- Rate-limited Create Addition electric_motor control.
-- Hard budget: ±24 RPM per thruster. Zeros flush first. Never spam setSpeed.
local util = require("util")

local motors = {}

motors.MAX_RPM = 24
motors.FLUSH_GAP = 0.12 -- seconds between writes to the same motor

local desired = {} -- name -> rpm
local sent = {} -- name -> last successful rpm
local lastWrite = {} -- name -> clock time
local lastError = {} -- name -> string
local known = {} -- name -> true
local clockFn = util.now
local sleepFn = sleep
local wrapFn = nil -- optional override for tests

local function now()
    return clockFn()
end

local function doSleep(t)
    if sleepFn then
        sleepFn(t)
    end
end

local function wrapMotor(name)
    if wrapFn then
        return wrapFn(name)
    end
    if not peripheral or not peripheral.isPresent(name) then
        return nil
    end
    if not peripheral.hasType(name, "electric_motor") then
        return nil
    end
    return peripheral.wrap(name)
end

function motors.setClock(fn)
    clockFn = fn or util.now
end

function motors.setSleep(fn)
    sleepFn = fn
end

function motors.setWrap(fn)
    wrapFn = fn
end

function motors.resetState()
    desired = {}
    sent = {}
    lastWrite = {}
    lastError = {}
    known = {}
end

function motors.clampRpm(rpm)
    rpm = tonumber(rpm) or 0
    -- integer RPM for CCA
    rpm = math.floor(rpm + (rpm >= 0 and 0.5 or -0.5))
    return util.clamp(rpm, -motors.MAX_RPM, motors.MAX_RPM)
end

function motors.dutyToRpm(duty, maxPos, maxNeg)
    duty = util.clamp(tonumber(duty) or 0, -1, 1)
    maxPos = math.min(tonumber(maxPos) or motors.MAX_RPM, motors.MAX_RPM)
    maxNeg = math.min(tonumber(maxNeg) or motors.MAX_RPM, motors.MAX_RPM)
    if duty >= 0 then
        return motors.clampRpm(duty * maxPos)
    end
    return motors.clampRpm(duty * maxNeg)
end

function motors.discover()
    local list = {}
    if not peripheral then
        return list
    end
    local names = peripheral.getNames()
    table.sort(names)
    for _, name in ipairs(names) do
        if peripheral.hasType(name, "electric_motor") then
            known[name] = true
            list[#list + 1] = name
        end
    end
    return list
end

function motors.register(name)
    if name then
        known[name] = true
    end
end

function motors.listKnown()
    local list = {}
    for name in pairs(known) do
        list[#list + 1] = name
    end
    table.sort(list)
    return list
end

function motors.setDesired(name, rpm)
    if not name then
        return
    end
    known[name] = true
    desired[name] = motors.clampRpm(rpm)
end

function motors.getDesired(name)
    return desired[name] or 0
end

function motors.getSent(name)
    return sent[name]
end

function motors.getLastError(name)
    return lastError[name]
end

function motors.getSentMap()
    local out = {}
    for name, rpm in pairs(sent) do
        out[name] = rpm
    end
    return out
end

function motors.getDesiredMap()
    local out = {}
    for name, rpm in pairs(desired) do
        out[name] = rpm
    end
    return out
end

function motors.readActualSpeed(name)
    local m = wrapMotor(name)
    if not m or not m.getSpeed then
        return nil
    end
    local ok, s = pcall(function()
        return m.getSpeed()
    end)
    if ok and type(s) == "number" then
        return s
    end
    return nil
end

local function isRateLimitErr(err)
    return tostring(err):lower():find("too many", 1, true) ~= nil
end

local function tryWrite(name, rpm)
    local m = wrapMotor(name)
    if not m then
        lastError[name] = "missing"
        return false, "missing"
    end
    rpm = motors.clampRpm(rpm)
    local t = now()
    local last = lastWrite[name]
    local gapOk = (not last) or ((t - last) >= motors.FLUSH_GAP)

    if math.abs(rpm) < 1 then
        if sent[name] ~= nil and math.abs(sent[name] or 0) < 1 and gapOk then
            sent[name] = 0
            lastError[name] = nil
            return true, "already_zero"
        end
        if not gapOk and sent[name] ~= nil and math.abs(sent[name] or 0) < 1 then
            lastError[name] = nil
            return true, "already_zero"
        end
        if not gapOk then
            lastError[name] = "rate_limit"
            return false, "rate_limit"
        end
        local wrote = false
        if m.stop then
            local ok, err = pcall(function()
                m.stop()
            end)
            if ok then
                wrote = true
            elseif isRateLimitErr(err) then
                lastError[name] = "rate_limit"
                return false, "rate_limit"
            end
        end
        if m.setSpeed then
            local ok, err = pcall(function()
                m.setSpeed(0)
            end)
            if ok then
                wrote = true
            elseif isRateLimitErr(err) then
                lastError[name] = "rate_limit"
                return false, "rate_limit"
            elseif not wrote then
                lastError[name] = tostring(err)
                return false, tostring(err)
            end
        elseif m.setRPM then
            local ok, err = pcall(function()
                m.setRPM(0)
            end)
            if ok then
                wrote = true
            elseif isRateLimitErr(err) then
                lastError[name] = "rate_limit"
                return false, "rate_limit"
            elseif not wrote then
                lastError[name] = tostring(err)
                return false, tostring(err)
            end
        elseif not wrote then
            lastError[name] = "no setSpeed"
            return false, "no setSpeed"
        end
        lastWrite[name] = now()
        sent[name] = 0
        lastError[name] = nil
        return true
    end

    if not gapOk then
        lastError[name] = "rate_limit"
        return false, "rate_limit"
    end

    local ok, err
    if m.setSpeed then
        ok, err = pcall(function()
            m.setSpeed(rpm)
        end)
    elseif m.setRPM then
        ok, err = pcall(function()
            m.setRPM(rpm)
        end)
    else
        lastError[name] = "no setSpeed"
        return false, "no setSpeed"
    end
    if not ok then
        if isRateLimitErr(err) then
            lastError[name] = "rate_limit"
            return false, "rate_limit"
        end
        lastError[name] = tostring(err)
        return false, tostring(err)
    end
    lastWrite[name] = now()
    sent[name] = rpm
    lastError[name] = nil
    return true
end

--- Flush pending motor writes. Zeros first. Returns remaining pending count.
function motors.flush(maxWrites)
    maxWrites = maxWrites or 32
    local zeros = {}
    local others = {}
    for name, want in pairs(desired) do
        local have = sent[name]
        if have == nil or math.abs((have or 0) - want) >= 0.5 then
            if math.abs(want) < 1 then
                zeros[#zeros + 1] = name
            else
                others[#others + 1] = name
            end
        end
    end
    table.sort(zeros)
    table.sort(others)

    local wrote = 0
    local function attempt(list)
        for _, name in ipairs(list) do
            if wrote >= maxWrites then
                return
            end
            local want = desired[name] or 0
            local ok, reason = tryWrite(name, want)
            if ok then
                wrote = wrote + 1
            elseif reason == "rate_limit" then
                -- leave pending for next flush
            else
                -- missing peripheral etc — keep desired for retry
            end
        end
    end
    attempt(zeros)
    attempt(others)

    local pending = 0
    for name, want in pairs(desired) do
        local have = sent[name]
        if have == nil or math.abs((have or 0) - want) >= 0.5 then
            pending = pending + 1
        end
    end
    return pending
end

--- Drain without sleep() — wait via timer + pullEventRaw so keys are not discarded.
-- onEvent(e, ...) may return true to abort early.
function motors.drain(timeout, onEvent)
    timeout = timeout or 5
    local start = now()
    while true do
        local pending = motors.flush(64)
        if pending == 0 then
            return true
        end
        if now() - start > timeout then
            return false, pending
        end
        local timer = os.startTimer(motors.FLUSH_GAP)
        while true do
            local e = { os.pullEventRaw() }
            local ev = e[1]
            if onEvent and onEvent(table.unpack(e)) then
                return false, "aborted"
            end
            if ev == "timer" and e[2] == timer then
                break
            elseif ev == "terminate" then
                error("Terminated", 0)
            end
        end
    end
end

--- Zero all motors; flush once (no blocking sleep). Call flush/drain from caller.
function motors.panicNow()
    for name in pairs(known) do
        desired[name] = 0
    end
    for name in pairs(desired) do
        desired[name] = 0
    end
    local ok, list = pcall(motors.discover)
    if ok then
        for _, name in ipairs(list) do
            desired[name] = 0
            known[name] = true
        end
    end
    return motors.flush(64)
end

function motors.panic(timeout, onEvent)
    motors.panicNow()
    return motors.drain(timeout or 5, onEvent)
end

function motors.allOff()
    return motors.panic(5)
end

--- Apply duty map { name = duty }. Zeros thrusters in thrustersByName not in duties.
function motors.applyDuties(duties, thrustersByName)
    duties = duties or {}
    if thrustersByName then
        for name in pairs(thrustersByName) do
            if duties[name] == nil then
                motors.setDesired(name, 0)
            end
        end
    end
    for name, duty in pairs(duties) do
        local maxPos, maxNeg = motors.MAX_RPM, motors.MAX_RPM
        if thrustersByName and thrustersByName[name] then
            local t = thrustersByName[name]
            maxPos = t.max_rpm_pos or maxPos
            maxNeg = t.max_rpm_neg or maxNeg
        end
        motors.setDesired(name, motors.dutyToRpm(duty, maxPos, maxNeg))
    end
end

return motors
