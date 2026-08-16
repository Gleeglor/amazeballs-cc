-- Boat computer / monitor UI (in-place clearLine, no full clear each frame).
local ui = {}

ui.mode = "idle"
ui.status = ""
ui.ws = "down"
ui.lastTest = ""
ui._cleared = false

function ui.setMode(m)
    ui.mode = m or "idle"
end

function ui.setStatus(s)
    ui.status = tostring(s or "")
end

function ui.setWs(s)
    ui.ws = s or "down"
end

function ui.setLastTest(s)
    ui.lastTest = tostring(s or "")
end

local function writeLine(termObj, y, text, fg)
    local w = termObj.getSize and select(1, termObj.getSize()) or 51
    termObj.setCursorPos(1, y)
    if termObj.clearLine then
        termObj.clearLine()
    end
    if fg and termObj.setTextColor then
        termObj.setTextColor(fg)
    end
    termObj.write(string.sub(tostring(text or ""), 1, w))
    if fg and termObj.setTextColor then
        termObj.setTextColor(colors and colors.white or 1)
    end
end

function ui.draw(ctx)
    ctx = ctx or {}
    local t = term
    if not ui._cleared then
        if t.setBackgroundColor then
            t.setBackgroundColor(colors and colors.black or 0)
        end
        t.clear()
        ui._cleared = true
    end
    writeLine(t, 1, "Boat Agent  ws=" .. ui.ws .. "  mode=" .. ui.mode, colors and colors.lime)
    writeLine(t, 2, ui.status)
    local poseStr = "pose: ?"
    if ctx.x then
        poseStr = string.format(
            "xyz %.1f %.1f %.1f  yaw %.1f°",
            ctx.x,
            ctx.y or 0,
            ctx.z,
            (ctx.yaw or 0) * 180 / math.pi
        )
    end
    writeLine(t, 3, poseStr)
    writeLine(
        t,
        4,
        string.format(
            "spd %.2f  thrust %.2f  held=%s  dock=%s",
            ctx.speed or 0,
            ctx.thrust or 0,
            tostring(ctx.held or "-"),
            tostring(ctx.dock or "-")
        )
    )
    writeLine(t, 5, "wp: " .. tostring(ctx.waypoint or "-"))
    writeLine(t, 6, "test: " .. ui.lastTest)
    writeLine(t, 7, "W/S surge  A/D yaw  Z/C strafe  X stop  Q quit")
    writeLine(t, 8, "name             duty  want  sent  get")

    local h = select(2, t.getSize())
    local y = 9
    local names = {}
    if ctx.duties then
        for name in pairs(ctx.duties) do
            names[#names + 1] = name
        end
    end
    if ctx.sent then
        for name in pairs(ctx.sent) do
            if not ctx.duties or ctx.duties[name] == nil then
                names[#names + 1] = name
            end
        end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        if y >= h then
            break
        end
        local d = (ctx.duties and ctx.duties[name]) or 0
        local want = (ctx.desired and ctx.desired[name]) or 0
        local s = (ctx.sent and ctx.sent[name])
        local act = (ctx.actual and ctx.actual[name])
        local err = ctx.errors and ctx.errors[name]
        local line = string.format(
            "%-14s %+0.2f %4d %4s %4s",
            string.sub(name, 1, 14),
            d,
            math.floor(want + 0.0),
            s ~= nil and tostring(math.floor(s + 0.0)) or "?",
            act ~= nil and tostring(math.floor(act + 0.0)) or "?"
        )
        if err then
            line = line .. " !" .. tostring(err)
        end
        writeLine(t, y, line, (err and colors and colors.red) or nil)
        y = y + 1
    end
    while y < h do
        writeLine(t, y, "")
        y = y + 1
    end

    if peripheral then
        local mon = peripheral.find("monitor")
        if mon then
            mon.setCursorPos(1, 1)
            if mon.clearLine then
                mon.clearLine()
            end
            mon.write("Boat " .. ui.mode .. " " .. tostring(ctx.held or ""))
            mon.setCursorPos(1, 2)
            if mon.clearLine then
                mon.clearLine()
            end
            mon.write(poseStr)
        end
    end
end

return ui
