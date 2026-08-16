-- Rate-limited Create Addition electric_motor control.
-- Hard budget: ±24 RPM per thruster. Zeros flush first. Never spam setSpeed.
local util = require("util")

local motors = {}

motors.MAX_RPM = 24
motors.FLUSH_GAP = 0.12 -- seconds between writes to the same motor

local desired = {} -- name -> rpm
local sent = {} -- name -> last successful rpm
local lastWrite = {} -- name -> clock time
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
    known = {}
end

function motors.clampRpm(rpm)
    return util.clamp(tonumber(rpm) or 0, -motors.MAX_RPM, motors.MAX_RPM)
end

function motors.dutyToRpm(duty, maxPos, maxNeg)
    duty = util.clamp(tonumber(duty) or 0, -1, 1)
    maxPos = math.min(tonumber(maxPos) or motors.MAX_RPM, motors.MAX_RPM)
    maxNeg = math.min(tonumber(maxNeg) or motors.MAX_RPM, motors.MAX_RPM)
    if duty >= 0 then
        return duty * maxPos
    end
    return duty * maxNeg
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

local function isRateLimitErr(err)
    return tostring(err):lower():find("too many", 1, true) ~= nil
end

local function tryWrite(name, rpm)
    local m = wrapMotor(name)
    if not m then
        return false, "missing"
    end
    rpm = motors.clampRpm(rpm)
    local t = now()
    local last = lastWrite[name]
    local gapOk = (not last) or ((t - last) >= motors.FLUSH_GAP)

    if math.abs(rpm) < 1 then
        if sent[name] ~= nil and math.abs(sent[name] or 0) < 1 and gapOk then
            sent[name] = 0
            return true, "already_zero"
        end
        if not gapOk and sent[name] ~= nil and math.abs(sent[name] or 0) < 1 then
            return true, "already_zero"
        end
        if not gapOk then
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
                return false, "rate_limit"
            elseif not wrote then
                return false, tostring(err)
            end
        elseif m.setRPM then
            local ok, err = pcall(function()
                m.setRPM(0)
            end)
            if ok then
                wrote = true
            elseif isRateLimitErr(err) then
                return false, "rate_limit"
            elseif not wrote then
                return false, tostring(err)
            end
        elseif not wrote then
            return false, "no setSpeed"
        end
        lastWrite[name] = now()
        sent[name] = 0
        return true
    end

    if not gapOk then
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
        return false, "no setSpeed"
    end
    if not ok then
        if isRateLimitErr(err) then
            return false, "rate_limit"
        end
        return false, tostring(err)
    end
    lastWrite[name] = now()
    sent[name] = rpm
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

--- Drain until all desired match sent, sleeping between attempts.
function motors.drain(timeout)
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
        doSleep(motors.FLUSH_GAP)
    end
end

function motors.panic(timeout)
    for name in pairs(known) do
        desired[name] = 0
    end
    for name in pairs(desired) do
        desired[name] = 0
    end
    -- Also discover live motors
    local ok, list = pcall(motors.discover)
    if ok then
        for _, name in ipairs(list) do
            desired[name] = 0
            known[name] = true
        end
    end
    return motors.drain(timeout or 5)
end

function motors.allOff()
    return motors.panic(5)
end

--- Apply duty map { name = duty } using optional thruster max tables.
function motors.applyDuties(duties, thrustersByName)
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
