# Overnight status — boat realtime bridge + dock

**Updated:** 2026-08-16 (~02:50 local)

## Goal
1. Real CC filesystem bridge tests green (W/S/A/D/strafe/stop on the actual boat).
2. Navigate to **base dock x=340, z=165** (y = current water/pose Y), then `allOff`.

## Blocker right now
**Minecraft is running**, but **no boat ComputerCraft computer FS** exists under local saves with `boat.lua` / `boat_control.json` / `test_agent` heartbeat.

Discovered computers (all score 0 — cannon hubs only):
- `New World (1)` ids 1–3 (hub/fire/ammo)
- `New World (2)` ids 0–1 (hub)
- `New World` — `computercraft/ids.json` says next id `0`, **no `computer/0` folder yet**

Until a boat computer is open (chunk loaded) and `test_agent` is running, the host cannot run real tests or dock.

Grapple/Sable log recently saw a craft near **~(431, 7.5, 74)** — dock is **(340, 165)** (~120 m away once control works).

## What was finished (pushed / ready)
| Piece | Path |
|-------|------|
| On-computer agent | `navigation/test_agent.lua` |
| Host bridge + tests | `navigation/realtime_tests/` |
| Overnight watcher | `realtime_tests/overnight_loop.mjs` |
| FS deploy (no HTTP) | `realtime_tests/deploy_to_computer.mjs` |
| Catalog | `test_agent.lua` in `catalog.json` / `catalog.v2.json` |
| Boat menu | `testagent` / `boat testagent` |
| Lua fixes | `thrusterSide` ignores `side_score=0`; calib sets surge side from tz; `enrichControl` migrates; `stepToward` uses `applyCommand` (yaw_sign); `navigate_to` / `go_dock` on agent |
| Sim | Marked **not authority** in READMEs |

## Resume (when you’re at the boat)
1. Stand at boat computer (chunk loaded).
2. `updater` → select `test_agent.lua` + navigation `lib/*` (or from host after computer id exists:  
   `cd cc-scripts/navigation/realtime_tests && npm run list`  
   `node deploy_to_computer.mjs --world "…" --id N`).
3. Run: `test_agent` (or `boat` → `testagent`). Leave it running.
4. Host:
   ```bash
   cd cc-scripts/navigation/realtime_tests
   npm test
   # or full overnight (tests + dock):
   node overnight_loop.mjs --once
   # continuous retry:
   node overnight_loop.mjs
   ```
5. Status file: `realtime_tests/overnight_status.json`

## Expected after green tests
Agent command `navigate_to` → (340, 165), arrive within ~4 m, motors stopped.

## If still inverted / one-sided after update
- Fresh `calibrate` (v8 writes `yaw_sign=-1` + side scores).
- Re-run `npm test`; A/D notes print Δyaw°.
- Do **not** trust `navigation/sim` greens for in-game.
