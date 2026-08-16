# Overnight status — boat realtime bridge + dual dock

**Updated:** 2026-08-16T03:50:00+02:00

## Goal
1. Control green: `npm run deploy` + `npm test` (A/D Δyaw, W motion, idle stop, both-sides yaw).
2. Dual-dock prototype: Port A (341,163) ↔ Port B (383,285) with berth align + PSI handshake stubs.
3. Leave boat parked/aligned at Port A; scripts on GitHub main; resume docs here.

## Live bridge
- Host: `realtime_tests` HTTP on `0.0.0.0:8765` — **UP**
- Agent: **DOWN after reboot** (2026-08-16 ~01:46Z). Files on disk include new `test_agent.lua` + `drive.lua`, but **`startup` was not writable on the old agent**, so reboot dropped to craft shell without auto-restart.

## CRITICAL — resume agent (one boat action)
On the boat computer (chunk loaded):

```text
test_agent
```

(New `test_agent.lua` is already on the computer from the pre-reboot deploy.)

Then on host:

```bash
cd cc-scripts/navigation/realtime_tests
npm run recover          # waits → full deploy → reload_libs → npm test → Port A
# or manually:
npm run deploy
# send reload_libs via bridge, then:
SKIP_DEPLOY=1 npm test
```

Bootstrap if `test_agent` file missing:

```text
wget https://raw.githubusercontent.com/Gleeglor/amazeballs-cc/main/navigation/test_agent.lua test_agent
test_agent
```

## Phase progress
| Phase | Status |
|-------|--------|
| 1 Control green | **BLOCKED** — agent down after reboot; code fix ready (RPM 96, tz synth, cardinal yaw) |
| 2 Dual dock A↔B | **CODE READY** — `lib/ports.lua`, `lib/dock.lua`, paths, boat route, `berth_align` |
| 3 Working leave state | PENDING agent |

## Root cause (Phase 1 fail before reboot)
- Live holds: motors commanded but **Δyaw≈0 / Δfwd≈0** at **24 RPM** cap; calib `tz` tiny (~0.01) so Reassembly net.tz≈0.04.
- Fix landed on disk: `DEFAULT_MAX_RPM=96`, synthesize geometric `tz` for side thrusters, pure-yaw → cardinal override, longer holds, `reload_libs`, `startup` writer, dual-dock libs.

## Ports / physical blocks (user places)
| Port | XZ | Shore block | Boat block |
|------|-----|-------------|------------|
| **A** | 341, 163 | `create:portable_storage_interface` facing berth | matching PSI on hull |
| **B** | 383, 285 | same | same |

Software berth poses + redstone/funnel **stubs** in `lib/dock.lua` / `port.lua`. Align via `berth_align` / `boat` → `run`.

## Startup path (after agent back)
1. Boat: `test_agent` (or `boat` → `testagent`) — keep HTTP bridge `npm run serve`.
2. Host: `npm run deploy` then `reload_libs` (or reboot **only after** `startup` is written).
3. Green: `SKIP_DEPLOY=1 npm test`
4. Logistics: `boat` → `run` alternates `to_port_a` / `to_port_b` with dock handshake stubs.
5. Or bridge: `navigate_to` → Port A, `berth_align`, then toward B.

## Never reboot without startup
Old agents reject `startup` writes. Sequence:
1. Deploy new `test_agent` (adds `startup` to WRITE_ALLOW)
2. Soft `reload_libs` if possible, **or** write `startup` then reboot
3. `npm run recover` automates post-reconnect

## Log
- `03:42` Mandate start. Bridge UP, agent id=12.
- `03:43` Deploy OK (13 files). `npm test`: 9 pass / 2 fail (`A_yaw_left`, `D_opposite_A`) — Δyaw=0.
- `03:45` Pose frozen under thrust at 24 RPM; net.tz≈-0.04.
- `03:48` Patched drive/test_agent/dock/ports; dual-dock paths generated.
- `03:49` **Reboot without startup → agent lost.** `recover_overnight.mjs` waiting.
- `03:50` Pushing amazeballs-cc; waiting for `test_agent` on boat.
- `2026-08-16T01:48:53.161Z` recover_overnight started — waiting for boat test_agent
