-- Auto-map all redstone_relay peripherals (Reassembly / wrench mode).
-- Writes /boat_control.json — thruster force+torque, not axis labels.
-- Usage:
--   calibrate              -- normal RS (15=full, 0=off)
--   calibrate invert       -- analog transmission (0=full, 15=off)
package.path = package.path .. ";/lib/?.lua;/lib/?/init.lua"
local calibrate = require("nav_calibrate")

local args = { ... }
local invert = false
for _, a in ipairs(args) do
    a = string.lower(tostring(a))
    if a == "invert" or a == "--invert" or a == "inverted" then
        invert = true
    end
end

print("=== Boat thruster calibrate (Reassembly-style) ===")
print("Open water, props submerged, kinetics on.")
print("Each relay is one thruster; we measure push + yaw torque.")
if invert then
    print("Mode: INVERT (analog transmission — RS 0 = full thrust, 15 = off)")
else
    print("Mode: normal (RS 15 = full thrust, 0 = off)")
    print("Tip: if you use an analog transmission, run:  calibrate invert")
end
print()

local control, err = calibrate.run({
    pulse = 0.6,
    settle = 0.35,
    use_sides = false,
    invert_analog = invert,
})

if not control then
    print("FAILED: " .. tostring(err))
    return
end

print()
print("Saved /boat_control.json  (version " .. tostring(control.version)
    .. ", mode=" .. tostring(control.mode)
    .. ", invert_analog=" .. tostring(control.invert_analog) .. ")")
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
