# Overnight status — boat guidance + control + calibrator prototype

**Updated:** 2026-08-16T05:24:00+02:00

## DONE — mandate complete

| Phase | Status |
|-------|--------|
| 1 `npm test` GREEN | **DONE** — 11/11 (`TEST_EXIT:0`, `/tmp/ex_finish_out.log` / `/tmp/finish_npm_test.log`) |
| 2 Soft dual-dock A↔B | **DONE** — B dist≈19.51, A dist≈19.49 (≤20 water holds) |
| 3 Park Port A soft | **DONE** — final pose ~`(342.5, 207.2)` near Port A water hold |

`DUAL DOCK OK — soft water hold at Port A (gentle, ≤20)` + `ALL_OK`.

## How to boot

1. **Host bridge** (LAN reachable from the Minecraft *server*):
   ```bash
   cd cc-scripts/navigation/realtime_tests
   npm run serve   # 0.0.0.0:8765
   ```
2. Boat `/realtime_bridge.json`: `{ "mode":"http", "base_url":"http://<PUBLIC_OR_LAN_IP>:8765", "poll":0.3 }`  
   Never `127.0.0.1` (CC `http` runs on the MC server).
3. On the boat CC computer:
   ```text
   test_agent
   ```
   `startup` runs `shell.run("test_agent")` after deploy/reboot.
4. Deploy + clean reload:
   ```bash
   npm run run-reboot          # deploy → os.reboot → wait heartbeat
   # or: npm run deploy && bridge reload_libs
   SKIP_DEPLOY=1 npm test
   npm run dual-dock           # soft B then soft park A
   ```

## Ports (landmarks vs soft water holds)

| Port | Shore landmark (PSI) | Soft water hold (nav target) | Arrive |
|------|----------------------|------------------------------|--------|
| **A** | 341, 163 | ~350.1, 189.5 (28-block offshore standoff) | horiz ≤ **20** then stop |
| **B** | 383, 285 | ~373.9, 258.5 | horiz ≤ **20** then stop |

Never drive onto shore coords. Handshake stubs OK without rednet port PCs.

## Tests (control green)

```bash
cd realtime_tests
SKIP_DEPLOY=1 npm test
```

Expect: ping, load_control, idle stop, W motion, A yaw (Δyaw° negative), D opposite yaw, final stop — **11 passed**.

## Calibrator

- Mid-window probe already in `nav_calibrate` / `calibrate.lua`.
- Prefer `boat` → `calibrate` only when babysitter is watching (full spin).
- Remote calibrate via bridge is optional; control green + soft nav is the overnight bar.

## `boat` / `go_port` soft route

```text
boat
run          # A↔B soft water corridor (config route → followPath)
```

Or host:
```bash
npm run boat-run-smoke           # follow_path A↔B (or --go-port)
node dual_dock_live.mjs          # go_port B then A, arrive_dist 20
```

Expect clear forward progress (not yaw-only spin). Soft arrive ≤20 of **water holds**.

Agent cmd: `go_port` with `arrive_dist: 20`, `handshake: false`, gentle cruise/creep.

## Known limits

- **Host lock / rival clients:** only one host may thruster-command; use flock + `/v1/lock`. Force unlock: `POST /v1/unlock {"force":true}`.
- **Long `go_port`:** claim TTL is 10 min; nav heartbeats refresh claim. Abort stuck nav: `POST /v1/abort {"abort":true}`.
- **Encode:** large results sanitized (`jsonSafe`); slim fallback if needed.
- **Soft-arrive pulsing:** only in last ~4 blocks past tol (was ≤38 and stalled boats).
- **Handshake:** software stub only (no physical PSI required for prototype).
- **Ender Modem unlinked:** irrelevant for HTTP bridge.

## Key fixes this overnight

1. Soft water holds + gentle RPM caps in `drive.stepToward` / `ports.lua`.
2. Bridge: long claim TTL + nav heartbeat refresh; `/v1/abort`; force unlock.
3. `run_and_reboot.mjs` deploy→reboot→wait pattern.
4. Soft-arrive pulse band narrowed so creep can close 20–35 block gaps.
5. `go_port` prefers direct cruise-to-hold when mid-corridor.

## GitHub

Push to `amazeballs-cc` `main` after this status write.
