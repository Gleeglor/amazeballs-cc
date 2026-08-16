-- Boat menu entry (optional boot). Prefer agent.lua for live work.
package.path = package.path .. ";/lib/?.lua;/lib/?/init.lua;./lib/?.lua;./?.lua"

local motors = require("motors")
local calibrate = require("calibrate")
local teleop = require("teleop")
local dock = require("dock")
local route = require("route")
local pose = require("pose")
local util = require("util")

local function menu()
    while true do
        term.clear()
        term.setCursorPos(1, 1)
        print("Boat control")
        print("1) calibrate")
        print("2) teleop")
        print("3) agent (websocket)")
        print("4) show pose")
        print("5) panic stop")
        print("6) set place (current pose)")
        print("0) quit")
        write("> ")
        local line = read()
        if line == "0" then
            motors.panic(3)
            return
        elseif line == "1" then
            calibrate.run({})
            read()
        elseif line == "2" then
            teleop.run()
        elseif line == "3" then
            shell.run("agent")
        elseif line == "4" then
            print(textutils.serialise(pose.get() or {}))
            read()
        elseif line == "5" then
            motors.panic(5)
            print("stopped")
            sleep(1)
        elseif line == "6" then
            write("place name: ")
            local name = read()
            local craft = pose.get()
            if craft and name and name ~= "" then
                local places = route.loadPlaces()
                places.places = places.places or {}
                places.places[name] = { x = craft.x, y = craft.y, z = craft.z, yaw = craft.yaw }
                route.savePlaces(places)
                print("saved " .. name)
            end
            sleep(1)
        end
    end
end

motors.panic(2)
menu()
