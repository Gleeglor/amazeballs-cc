-- In-game smoke tests (run via agent run_tests or: tests/live_smoke).
package.path = package.path .. ";/lib/?.lua;/lib/?/init.lua;./lib/?.lua;./?.lua"

local motors = require("motors")
local pose = require("pose")
local dock = require("dock")

print("live_smoke: motors clamp")
assert(motors.clampRpm(100) == 24)
assert(motors.clampRpm(-100) == -24)
assert(motors.dutyToRpm(1) == 24)
assert(motors.dutyToRpm(-1) == -24)

print("live_smoke: pose")
local craft = pose.get()
if craft then
    print(string.format("  at %.1f %.1f %.1f", craft.x, craft.y, craft.z))
else
    print("  (not on sublevel — skip)")
end

print("live_smoke: dock API")
local locked = dock.isLocked()
print("  locked=" .. tostring(locked))
assert(dock.withinTolerance(0.4, 10) == true)
assert(dock.withinTolerance(0.6, 10) == false)
assert(dock.withinTolerance(0.4, 25) == false)

print("live_smoke: OK")
