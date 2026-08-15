-- Auto-map electric motors + redstone relays (Reassembly / wrench mode).
-- Writes /boat_control.json — thruster force+torque, not axis labels.
-- Usage:
--   calibrate
--   calibrate invert
--   calibrate rpm 24
--   calibrate power 45
--   calibrate power 45 rpm 24
package.path = package.path .. ";/lib/?.lua;/lib/?/init.lua"
local calibrate = require("nav_calibrate")

local opts = calibrate.parseArgs({ ... })

print("=== Boat thruster calibrate (Reassembly-style) ===")
print("Open water, props submerged, FE on motors.")
print("Attach wired modems to each electric_motor (and relays if any).")
print("Each actuator is one thruster; we measure push + yaw torque.")
print("Motor probe/max RPM (each motor): " .. tostring(opts.probe_rpm))
print("Shared power budget: " .. tostring(opts.power_budget_rf) .. " RF/t (0 = off)")
if opts.invert_analog then
    print("Relay mode: INVERT (analog transmission — RS 0 = full, 15 = off)")
else
    print("Relay mode: normal (RS 15 = full, 0 = off). Motors always use setRPM.")
end
print()

local control, err = calibrate.run({
    pulse = 0.7,
    settle = 0.4,
    use_sides = false,
    invert_analog = opts.invert_analog,
    probe_rpm = opts.probe_rpm,
    power_budget_rf = opts.power_budget_rf,
    fe_per_rpm = opts.fe_per_rpm,
})

if not control then
    print("FAILED: " .. tostring(err))
    return
end

calibrate.printReport(control)
print("Re-run after rewiring. Then: boat -> control")
