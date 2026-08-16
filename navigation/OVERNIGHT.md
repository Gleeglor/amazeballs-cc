# Overnight status — boat guidance + control + calibrator prototype

**Updated:** 2026-08-16T10:35:00+02:00

## FINAL VERDICT — LIVE PROVEN (2026-08-16)

| Check | Result |
|-------|--------|
| Bridge `agent_alive` | **true** (computer_id **12**, HTTP) |
| Host `npm run serve` :8765 | **up** |
| `npm deploy` + `reload_libs` | **ok** — drive/boat/paths/test_agent on boat |
| Live `SKIP_DEPLOY=1 npm test` | **GREEN** (W/S/A/D control) |
| Live path smoke (status-pose, no cmd supersede) | **PASS** — coherent along-route progress |
| Offline `sim npm test` | **98/98 pass** |

### Live nav sample (prove not spin-blip-reverse)

Toward Port A water hold (~350.1, 189.5), ~28s status sampling while `navigate_to` ran:

- along_route **+6.5**, lateral **0.9**, dist_improve **+6.5**
- reverse_ticks **1**, yaw_sign_flips **3** (mostly intentional 180° reorient)
- Earlier B-leg sample: along **+7.9**, lateral **1.3**, dist_improve **+7.9**

### Exact `boat run` pull state on boat

After HTTP deploy + soft reboot / `reload_libs`, in-game:

```text
boat
run
```

Pulls `boat.lua` → `followNamed` → `drive.followPath` with:

- `arrive_dist = 20`, `engage_distance = 22`, `timeout = 360`, `hold_ticks = 2`
- Path legs from `boat_config.json` route (`to_port_a` / `to_port_b` / `a_to_b` / `b_to_a`)
- Soft water holds only (never shore 341,163 / 383,285)
- Cruise = **point-and-go**: `|bearing|>55°` → tiny fx + yaw; `22–55°` → fx≈0.70 + small yaw; else fx≈0.90, tz=0; longer motor flush; no reverse / no trim hunt on cruise

`test_agent` status heartbeats now include **pose** so host can monitor nav without superseding the active cmd.

**Commit:** see git HEAD after this push (message starts with point-and-go cruise).

---

## What you can run offline (no boat / no test_agent)

```bash
cd cc-scripts/navigation/sim
npm test
```

## How THEY run tests later

### Offline

```bash
cd cc-scripts/navigation/sim && npm test
```

### Live control (when boat + bridge ready)

1. Host: `cd realtime_tests && npm run serve`
2. Boat `/realtime_bridge.json`: LAN/tunnel `base_url` (never `127.0.0.1`)
3. Boat: `test_agent`
4. Host:
   ```bash
   npm run deploy && # then reload_libs or soft reboot
   SKIP_DEPLOY=1 npm test
   npm run boat-run-smoke
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

## Key fixes (this session)

1. Point-and-go cruise (55° / 22° bands, higher sustained fx, tiny fx while yawing, longer flush).
2. `test_agent` status always posts pose for live smoke without superseding nav.
3. Soft water holds + `arrive_dist=20` on `boat run` unchanged.
