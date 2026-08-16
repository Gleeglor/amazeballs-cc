# Boat allocation + watercraft physics sim

> **DEPRECATED as source of truth.** Sim/unit tests can go green while in-game controls are wrong.
> Use **`navigation/realtime_tests/`** (filesystem bridge + `test_agent.lua` on the boat) for real A/D/W / motor / pose checks.

Interactive top+side play-space and unit tests for Amazeballs ComputerCraft boat drive logic.

**Default allocation** mirrors `navigation/lib/drive.lua` `applyCommand`:
1. `applyReassembly` (weighted LS) with CoM-aware wrenches + duty-space yaw null
2. if LS fails **or all duties deadband to 0** → `applyTeleop` (same cancel)
3. if still dead → `applyCardinalRoles` (facing mixer + yaw null; no calib `tz` needed)

**Sign convention:** Pilot `+tz` = **A / craft-left**. Sim fixtures use geometric left+ `tz` with `yaw_sign=+1`. In-game v8 calib stores raw Minecraft `ω·up` (Y-up ≈ CW+/right+) and sets `yaw_sign=-1` once — do **not** also negate `pose.yawRate` (v7 did both → A/D flipped after recalibrate). Override `yaw_sign` to `+1` only if A still turns right after a fresh v8 recalibrate.

**Calibrate:** 2.0s thrust pulse; wrench from the steady mid-window **0.5s→1.5s** while still thrusting (avoids startup transient and spin-down bias).

Physics is a **boat on water**: multi-point buoyancy, gravity at offset CoM, hull linear/quadratic drag, yaw damping. Thruster torque is τ = (r − r_com) × F in geometric mode. Sim sidebar CoM is fed into allocation. Planar `+yaw` is CCW from above (nose toward −X / screen-left) so A feels like a left turn in the HTML top view.

## Default fixture: `cardinal_5_boat`

| Name | Facing | Default position (lx, ly) | Role |
|------|--------|---------------------------|------|
| `main_fwd` | forward | (−0.95, 0) | Primary surge |
| `bow_port` | left | (0.55, −0.75) | Strafe + yaw |
| `bow_stbd` | right | (0.55, 0.75) | Strafe + yaw |
| `stern_port` | back | (−0.65, −0.60) | Reverse + yaw |
| `stern_stbd` | back | (−0.65, 0.60) | Reverse + yaw |

Offset-CoM fixtures: `cardinal_5_com_stbd`, `cardinal_5_com_port`, `cardinal_5_com_aft`.

Asymmetric / weird layouts (forward surge + bounded yaw/lateral):
- `asymmetric_cardinal` — strong port / weak stbd, fwd off-centerline, CoM offset
- `weird_positions` — diagonal / unequal lever arms (not a neat rectangle)
- `missing_mirrored_faces` — 1 forward + uneven L/R + one back
- `offcenter_mass_asym` — off-center CoM + asymmetric thrust
- `seeded_weird_42` / `seeded_weird_99` — deterministic adversarial layouts

**Surge priority:** pure W clamps saturated LS (does not rescale target to zero yaw), then duty-space `nullResidualYaw` never drives Fx below ~55% of baseline. Teleop/cardinal weight unequal `max_force`.

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
| A / D | yaw `tz` ±1 (A = left / +tz) |
| Z / C | strafe `fy` ±1 |
| X | clear held keys |
| R | reset pose |

Sidebar: CoM xyz, ballast, hull volume, B/W (buoyancy vs weight) in HUD; waterline on side view.

## Run unit tests

```bash
cd navigation/sim
npm test
```

Covers allocation, physics, **user CoM bugs** (`com_bugs.test.mjs`), and **in-game-equivalent** `boat_control.json` v6 cases (`lua_like_cardinal5`).

## In-game (one updater pass)

1. `updater` pulls Lua from `amazeballs-cc` **once**
2. **Recalibrate once** (longer settle) so thrusters get `facing` / `max_force` (and `lx/ly` if available)
3. `boat` → `control` smoke: W / S / A (left) / D (right) / Z / C / release (X)

Optional in `/boat_control.json`:
- `"yaw_sign": 1` — only if A still turns right after a **fresh v8** recalibrate (default v8 is `-1` with raw ω·up tz)
- Pre-v8 saves: `enrichControl` migrates polarity once (v7 undoes the old pose negate; older raw tables get `yaw_sign=-1`)
- `"com_x" / "com_y" / "com_z"` — hull CoM for τ about CoM
- `"com_compensate": false` — disable yaw-null polish

If your four angle thrusters are not pure L/R/back (diagonal mounts), facing may be `mixed` — Reassembly uses measured wrenches; cardinal fallback needs clear facings.
