-- Auto-map all redstone_relay peripherals by pulsing and reading CC:Sable motion.
-- Writes /boat_control.json — no manual axis assignment.
package.path = package.path .. ";/lib/?.lua;/lib/?/init.lua"
local calibrate = require("nav_calibrate")

print("=== Boat relay calibrate ===")
print("Open water, props submerged, kinetics on.")
print("Pulsing every redstone_relay on the modem network...")
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
print("Saved /boat_control.json")
print("Axes:")
for axis, list in pairs(control.relays) do
    if type(list) == "table" and #list > 0 then
        print("  " .. axis .. ": " .. table.concat(list, ", "))
    end
end
if #control.unused > 0 then
    print("Unused: " .. table.concat(control.unused, ", "))
end
if #control.ambiguous > 0 then
    print("Ambiguous (not driven): " .. table.concat(control.ambiguous, ", "))
end
print("Gains: forward=" .. control.gains.forward
    .. " strafe=" .. control.gains.strafe
    .. " yaw=" .. control.gains.yaw)
print("Done. Re-run after rewiring.")
