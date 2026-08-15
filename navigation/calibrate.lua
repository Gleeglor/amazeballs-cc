-- Auto-map electric motors + redstone relays (Reassembly / wrench mode).
-- Writes /boat_control.json — thruster force+torque, not axis labels.
-- Usage:
--   calibrate              -- motors + normal RS (15=full, 0=off)
--   calibrate invert       -- relays with analog transmission (0=full, 15=off)
--   calibrate rpm 64       -- motor probe / max RPM (default 64)
package.path = package.path .. ";/lib/?.lua;/lib/?/init.lua"
local calibrate = require("nav_calibrate")

local args = { ... }
local invert = false
local probeRpm = 64
local i = 1
while i <= #args do
    local a = string.lower(tostring(args[i]))
    if a == "invert" or a == "--invert" or a == "inverted" then
        invert = true
    elseif a == "rpm" or a == "--rpm" then
        i = i + 1
        probeRpm = tonumber(args[i]) or probeRpm
    elseif tonumber(a) then
        -- bare number = probe rpm
        probeRpm = tonumber(a)
    end
    i = i + 1
end

print("=== Boat thruster calibrate (Reassembly-style) ===")
print("Open water, props submerged, FE on motors.")
print("Attach wired modems to each electric_motor (and relays if any).")
print("Each actuator is one thruster; we measure push + yaw torque.")
print("Motor probe/max RPM: " .. tostring(probeRpm))
if invert then
    print("Relay mode: INVERT (analog transmission — RS 0 = full, 15 = off)")
else
    print("Relay mode: normal (RS 15 = full, 0 = off). Motors always use setRPM.")
end
print()

local control, err = calibrate.run({
    pulse = 0.7,
    settle = 0.4,
    use_sides = false,
    invert_analog = invert,
    probe_rpm = probeRpm,
})

if not control then
    print("FAILED: " .. tostring(err))
    return
end

print()
print("Saved /boat_control.json  (version " .. tostring(control.version)
    .. ", mode=" .. tostring(control.mode)
    .. ", default_motor_rpm=" .. tostring(control.default_motor_rpm) .. ")")
print("Thrusters (" .. #control.thrusters .. "):")
for _, t in ipairs(control.thrusters) do
    local kind = t.kind or "?"
    print(string.format(
        "  [%s] %s  fx=%.3f fy=%.3f tz=%.3f  [%s]",
        kind,
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
print("Motors reverse for strafe/turn when needed; idle = 0 RPM.")
print("Re-run after rewiring. Then: boat -> control")
