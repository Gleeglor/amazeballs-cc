# Boat allocation + 3D physics sim

Interactive top+side play-space and unit tests for Amazeballs ComputerCraft boat drive logic.

**Default allocation** is a pure port of `navigation/lib/drive.lua` `applyReassembly` (weighted least-squares force+torque → thruster duties) over **cardinal thrusters** (`facing` × `max_force`, torque τ = r × F). `applyTeleop` remains available (near-CoM equal-push / side-differential mixer). Command vector is the same `{fx,fy,tz}` as in-game keys.

## Default fixture: `cardinal_5_boat`

Models the real boat: **1 forward + 4 maneuver** thrusters facing craft-cardinal directions.

| Name | Facing | Default position (lx, ly) | Role |
|------|--------|---------------------------|------|
| `main_fwd` | forward | (−0.95, 0) stern centerline | Primary surge |
| `bow_port` | left | (0.55, −0.75) | Strafe + yaw |
| `bow_stbd` | right | (0.55, 0.75) | Strafe + yaw |
| `stern_port` | back | (−0.65, −0.60) | Reverse + yaw |
| `stern_stbd` | back | (−0.65, 0.60) | Reverse + yaw |

Body frame: **+x forward**, **+y starboard**, CoM at origin. Positions and `max_force` are editable in the UI / JSON. Variants: `cardinal_5_sized` (unequal strengths), `cardinal_6_plus` (N≥6 smoke).

## Why this lives here (not only Cursor Canvas)

Cursor Canvas files cannot import local modules (only `cursor/canvas`). Shared allocation/physics must be importable by both the UI and `node:test`, so the playable sim is this ESM + HTML harness.

## Open the sim

From this directory, serve files over HTTP (ES modules need a server; `file://` often blocks them):

```bash
cd navigation/sim
npx --yes serve .
# open the printed URL, e.g. http://localhost:3000
```

Or any static server:

```bash
python3 -m http.server 8765
# http://localhost:8765
```

### Keys (match in-game manual)

| Key | Command |
|-----|---------|
| W / S | surge `fx` ±1 |
| A / D | yaw `tz` ±1 |
| Z / C | strafe `fy` ±1 |
| X | clear held keys (stop) |
| R | reset pose |

### What it proves

- **Reassembly (default)** on `cardinal_5_boat`: W → +Fx with Tz≈0; S → −Fx via back-facing; strafe → ±Fy with bounded yaw; A/D → ±Tz from the 4 angle thrusters; idle → duties 0.
- **Scalability**: `cardinal_6_plus` and `cardinal_5_sized` still allocate without NaN.
- **Teleop** on `near_com_strafe`: pure W equal-pushes when calib `fx` is weak → no invented yaw from identical motors.
- **3D physics**: geometric mode uses per-thruster `max_force` × facing and τ = r × F; water-plane spring keeps boats mostly planar.

### Intentional differences from in-game Lua

| Topic | Sim | In-game Lua |
|-------|-----|-------------|
| I/O | Duties only (no motors/relays) | `setActuator`, power budget, flush |
| Reassembly singular | Returns `ok: false` / zero duties | Falls back to `applyWrench` / teleop |
| Physics | JS semi-sim (not Minecraft) | Create craft motion |
| Facing | Explicit in fixtures; sync → fx/fy/tz | Calibrate classifies + writes `facing`/`role`/`max_force` |
| Cost weights | Matched to current `drive.applyReassembly` axW / deadbands | Source of truth |

## Run unit tests

Requires Node 18+:

```bash
cd navigation/sim
npm test
# equivalent: node --test allocation.test.mjs physics.test.mjs
```

No extra packages — uses the built-in `node:test` runner.

### Coverage

- Cardinal 5: W/S/strafe/A/D/idle; geometric↔wrench sync; 6+ and sized smoke.
- Teleop: idle; pure W equal-push / no net Tz; S mirrors W; pure A/D differential; strafe; chords; key→command map.
- Physics: wrench/geometric (incl. 3D r×F + per-thruster strength); integrator; drag; water plane; Reassembly W/A on cardinal_5.

## Layout

| File | Role |
|------|------|
| `allocation.mjs` | Shared CC allocation + facing sync (UI + tests) |
| `physics.mjs` | 3D rigid body + wrench/geometric forces |
| `fixtures.mjs` | Mock `boat_control.json` thruster tables |
| `app.mjs` + `index.html` | Interactive sim (top XY + side XZ) |
| `*.test.mjs` | Unit tests |

## Mapping to in-game

1. `calibrate` pulses motors → measures `fx,fy,tz` → classifies **facing** (`forward`/`back`/`left`/`right`) + `max_force` → writes `/boat_control.json` (`alloc_mode=reassembly`, version 6).
2. `boat` manual builds `{fx,fy,tz}` from keys (same as `commandFromKeys` here).
3. `drive.applyCommand` runs Reassembly LS (teleop if `alloc_mode=teleop` or LS fails).
4. This sim skips peripherals and integrates 3D forces so you can see *why* a command yawed or lifted.

After pulling Lua updates: run the in-game **updater**, then **recalibrate** so thrusters get `facing` labels, then test W/S/strafe/A/D.
