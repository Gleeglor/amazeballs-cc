-- CLI: calibrate
package.path = package.path .. ";/lib/?.lua;/lib/?/init.lua;./lib/?.lua;./?.lua"
local calibrate = require("calibrate")
local motors = require("motors")
local args = { ... }
local opts = {}
for _, a in ipairs(args) do
    if tostring(a):lower() == "noramp" then
        opts.ramp = false
    end
end
motors.panic(2)
local ok, err = calibrate.run(opts)
if not ok then
    print("calibrate failed: " .. tostring(err))
end
motors.panic(3)
