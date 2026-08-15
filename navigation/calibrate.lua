-- Auto-map all redstone_relay peripherals (Reassembly / wrench mode).
-- Writes /boat_control.json — thruster force+torque, not axis labels.
package.path = package.path .. ";/lib/?.lua;/lib/?/init.lua"
local calibrate = require("nav_calibrate")

print("=== Boat thruster calibrate (Reassembly-style) ===")
print("Open water, props submerged, kinetics on.")
print("Each relay is one thruster; we measure push + yaw torque.")
print()

local control, err = calibrate.run({
    pulse = 0.6,
    settle = 0.35,
    use_sides = false,
})

if not control then
    print("FAILED: " .. tostring(err))
    return
end

print()
print("Saved /boat_control.json  (version " .. tostring(control.version) .. ", mode=" .. tostring(control.mode) .. ")")
print("Thrusters (" .. #control.thrusters .. "):")
for _, t in ipairs(control.thrusters) do
    print(string.format(
        "  %s  fx=%.3f fy=%.3f tz=%.3f  [%s]",
        t.name,
        t.fx,
        t.fy,
        t.tz,
        calibrate.describe(t)
    ))
end
if control.unused and #control.unused > 0 then
    print("Unused: " .. table.concat(control.unused, ", "))
end
print("Control will combine thrusters for strafe/turn (not 1 prop = 1 axis).")
print("Re-run after rewiring. Then: boat -> control")
