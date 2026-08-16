# Overnight status — boat guidance + control + calibrator prototype

**Updated:** 2026-08-16T10:15:00+02:00

## What you can run offline (no boat / no test_agent)

```bash
cd cc-scripts/navigation/sim
npm test
```

Covers allocation, physics, CoM bugs, **and soft-nav invariants** (`soft_nav.test.mjs`): soft arrive ≤20, pulse band last ~4 blocks, surge≥yaw (anti spin), water holds offshore, shipped path JSON ends on holds not shore.

## DONE — prior live mandate (when agent was up)

| Phase | Status |
|-------|--------|
| 1 `npm test` GREEN | **DONE** — control suite (incl. S reverse) |
| 2 Soft dual-dock A↔B | **DONE** — water holds ≤20 |
| 3 Park Port A soft | **DONE** — soft water hold near Port A |

Live thruster / dual-dock / reboot loops are **optional** — pull this repo and run offline tests anytime. Keep `test_agent` only when you want live checks.

## How THEY run tests later

### Offline (preferred anytime)

```bash
cd cc-scripts/navigation/sim && npm test
```

### Live control (when boat + bridge ready)

1. Host: `cd realtime_tests && npm run serve`
2. Boat `/realtime_bridge.json`: LAN/tunnel `base_url` (never `127.0.0.1`)
3. Boat: `test_agent` (or deploy then soft-reload)
4. Host:
   ```bash
   SKIP_DEPLOY=1 npm test          # control green (W/S/A/D)
   npm run boat-run-smoke          # follow_path A↔B soft corridor
   # optional: npm run dual-dock   # go_port B then A
   ```

### In-game boat route (no host)

```text
boat
run          # followPath soft water corridor; arrive_dist 20
```

## Ports (landmarks vs soft water holds)

| Port | Shore landmark (PSI) | Soft water hold (nav target) | Arrive |
|------|----------------------|------------------------------|--------|
| **A** | 341, 163 | ~350.1, 189.5 (28-block offshore) | horiz ≤ **20** then stop |
| **B** | 383, 285 | ~373.9, 258.5 | horiz ≤ **20** then stop |

Never drive onto shore coords.

## Key fixes (control + soft route)

1. Soft water holds + gentle RPM in `drive.stepToward` / `ports.lua`.
2. Surge-biased cruise (turnKeep ≥0.55, yawAuth < surge) — fixes yaw-only spin.
3. Auth ceiling **0.78** on low-max (24 RPM) boats so soft cruise ≈18–19 RPM beats drag (old 0.55 ≈13 RPM stalled).
4. Soft-arrive pulse only in last ~4 blocks past tol.
5. `boat` `run` / `followNamed` passes `arrive_dist=20` explicitly.
6. Offline `soft_nav` unit tests mirror Lua invariants.

## GitHub

Push to `amazeballs-cc` `main` after this status write.
