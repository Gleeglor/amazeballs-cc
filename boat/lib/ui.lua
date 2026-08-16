-- Boat computer / monitor UI.
local ui = {}

ui.mode = "idle"
ui.status = ""
ui.ws = "down"
ui.lastTest = ""

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
    termObj.write(string.sub(tostring(text), 1, w))
    if fg and termObj.setTextColor then
        termObj.setTextColor(colors and colors.white or 1)
    end
end

function ui.draw(ctx)
    ctx = ctx or {}
    local t = term
    if t.setBackgroundColor then
        t.setBackgroundColor(colors and colors.black or 0)
    end
    t.clear()
    writeLine(t, 1, "Boat Agent  ws=" .. ui.ws .. "  mode=" .. ui.mode, colors and colors.lime)
    writeLine(t, 2, ui.status)
    local poseStr = "pose: ?"
    if ctx.x then
        poseStr = string.format("xyz %.1f %.1f %.1f  yaw %.0f°", ctx.x, ctx.y or 0, ctx.z, (ctx.yaw or 0) * 180 / math.pi)
    end
    writeLine(t, 3, poseStr)
    writeLine(t, 4, string.format("spd %.2f  thrust %.2f  dock=%s", ctx.speed or 0, ctx.thrust or 0, tostring(ctx.dock or "-")))
    writeLine(t, 5, "wp: " .. tostring(ctx.waypoint or "-"))
    writeLine(t, 6, "test: " .. ui.lastTest)
    writeLine(t, 8, "W/S surge  A/D yaw  Z/C strafe  X stop  Q quit")
    if ctx.duties then
        local y = 10
        for name, d in pairs(ctx.duties) do
            local bar = string.rep("#", math.floor(math.abs(d) * 10 + 0.5))
            writeLine(t, y, string.format("%s %+0.2f %s", name, d, bar))
            y = y + 1
            if y > 18 then
                break
            end
        end
    end

    -- Optional advanced monitor / graphics
    if peripheral then
        local mon = peripheral.find("monitor")
        if mon then
            mon.clear()
            mon.setCursorPos(1, 1)
            mon.write("Boat " .. ui.mode)
            mon.setCursorPos(1, 2)
            mon.write("ws " .. ui.ws)
            mon.setCursorPos(1, 3)
            mon.write(poseStr)
        end
    end
end

return ui
