-- Emergency: zero every Create Addition electric_motor on the network.
-- Use when the boat keeps thrusting after the computer was turned off
-- (motors remember last setRPM until told otherwise).
package.path = package.path .. ";/lib/?.lua;/lib/?/init.lua"
local drive = require("drive")

print("Stopping all electric motors (max drain)...")
drive.stopAllMotors({ drain_timeout = 1.0 })
print("Done. If props still spin, check FE / other redstone clocks.")
