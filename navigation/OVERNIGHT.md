# Overnight status — boat realtime bridge + dual dock

**Updated:** 2026-08-16T03:52:30+02:00

## Goal
1. Control green: `npm run deploy` + `npm test` (A/D Δyaw, W motion, idle stop, both-sides yaw).
2. Dual-dock prototype: Port A (341,163) ↔ Port B (383,285) with berth align + handshake stubs.
3. Leave boat parked/aligned at Port A; scripts on GitHub main; resume docs here.

## Live bridge
- Host: `realtime_tests` HTTP on `0.0.0.0:8765` — **UP** (hardened: stale claim auto-clear, `POST /v1/clear`)
- Agent: **DOWN** — craft computer idle after reboot without `startup` (stranded at shell)
- `recover_overnight` v2: **passive health wait** (no ping spam) → seize → startup-first deploy → reload_libs → npm test → dual-dock → park A

## Blocked on (host cannot fix alone)
Boat CC process must re-enter `test_agent`. Chunk is expected loaded; computer is at craft shell because reboot ran before `startup` was writable on the old allowlist. Host keeps polling forever — **no human action required from the sleeping user if anything else restarts the program** (chunk reload / another player / modem / future auto-boot). Host will seize the agent the instant `/v1/status` is fresh.

## Phase progress
| Phase | Status |
|-------|--------|
| 1 Control green | CODE READY — previously green once; re-verify when agent returns |
| 2 Dual dock A↔B | CODE READY — `go_port`, ports/dock, paths, `dual_dock_live.mjs` |
| 3 Working leave state | PENDING agent heartbeat |

## Offline hardenings this turn
- Deploy order: `test_agent.lua` → `startup` → rest; **refuse reboot** if startup not written
- `reboot` cmd always rewrites `startup` + `startup.lua`
- Bridge: clear pending on host timeout; server expires stale claims (45s)
- Recover v2: health-only wait, clear inbox, startup verify, dual-dock + Port A fallback

## Ports
- **Port A:** 341, 163 (park here) — `port_a_dock`
- **Port B:** 383, 285 — `port_b_dock`
- Boat: `boat_dock` stub

## Log
- `03:46` Keeper: live `npm test` **11/11** before later reboot loss (earlier session).
- `03:49` Reboot without startup → agent lost. Push `d7484e8`.
- `03:50` recover_overnight waiting.
- `03:52` Hardened bridge/deploy/recover; restarted waiters; still no boat HTTP hits.
