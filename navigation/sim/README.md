# Boat allocation + watercraft physics sim

Interactive top+side play-space and unit tests for Amazeballs ComputerCraft boat drive logic.

**Default allocation** mirrors `navigation/lib/drive.lua` `applyCommand`:
1. `applyReassembly` (weighted LS)
2. if LS fails **or all duties deadband to 0** → `applyTeleop`
3. if still dead → `applyCardinalRoles` (facing-only mixer; no calib `tz` needed)

Physics is a **boat on water**: multi-point buoyancy, gravity at offset CoM, hull linear/quadratic drag, yaw damping. Thruster torque is τ = (r − r_com) × F in geometric mode.

## Default fixture: `cardinal_5_boat`

| Name | Facing | Default position (lx, ly) | Role |
|------|--------|---------------------------|------|
| `main_fwd` | forward | (−0.95, 0) | Primary surge |
| `bow_port` | left | (0.55, −0.75) | Strafe + yaw |
| `bow_stbd` | right | (0.55, 0.75) | Strafe + yaw |
| `stern_port` | back | (−0.65, −0.60) | Reverse + yaw |
| `stern_stbd` | back | (−0.65, 0.60) | Reverse + yaw |

## Open the sim

```bash
cd navigation/sim
npx --yes serve .
# open the printed URL, e.g. http://localhost:3000
```

Or: `python3 -m http.server 8765` → http://localhost:8765

### Keys

| Key | Command |
|-----|---------|
| W / S | surge `fx` ±1 |
| A / D | yaw `tz` ±1 |
| Z / C | strafe `fy` ±1 |
| X | clear held keys |
| R | reset pose |

Sidebar: CoM xyz, ballast, hull volume, B/W (buoyancy vs weight) in HUD; waterline on side view.

## Run unit tests

```bash
cd navigation/sim
npm test
```

## In-game mapping

1. `updater` pulls Lua from `amazeballs-cc`
2. **Recalibrate** (longer settle) so thrusters get `facing` / `max_force`
3. `boat` → `control` — W/S/A/D/Z/C; if Reassembly would zero motors, teleop/cardinal fallback now runs

If your four angle thrusters are not pure L/R/back (diagonal mounts), facing may be `mixed` — Reassembly uses measured wrenches; cardinal fallback needs clear facings.
