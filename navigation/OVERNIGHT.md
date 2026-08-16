# Overnight status — boat realtime bridge + dock

**Updated:** 2026-08-16 (~03:00 local)

## Goal
1. Real boat bridge tests green (W/S/A/D/strafe/stop on the actual boat).
2. Navigate to **base dock x=340, z=165** (y = current pose Y), then `allOff`.

## Multiplayer vs local FS (important)

The boat is on a **multiplayer server**. Local Prism `saves/.../computercraft/computer/` only has cannon hubs — **`npm run list` / FS discover will not see the boat**. Use the **HTTP poll bridge**.

| Mode | Use when |
|------|----------|
| `http` | Multiplayer (this server) |
| `fs` | Singleplayer, or optional sshfs mount of server computer dirs |

## Resume — multiplayer HTTP

### Ask server admin
In `computercraft-server.toml`, allow the host PC **before** `$private` deny, e.g.:

```toml
[[http.rules]]
	host = "YOUR.LAN.IP.HERE"
	port = 8765
	action = "allow"
```

(`[http] enabled = true` must stay on.)

**Remote hosted server?** If the multiplayer address is a public IP (not on your home LAN), the boat cannot reach `192.168.x.x` — run ngrok/cloudflare to `:8765` and allow that public hostname instead.
### Host (your PC)
```bash
cd cc-scripts/navigation/realtime_tests
cp bridge.example.json bridge.json   # mode=http, listen 0.0.0.0:8765
npm run serve                        # leave running
# other terminal:
npm test
# or tests + dock:
node overnight_loop.mjs --once
```

### Boat
1. Create `/realtime_bridge.json` with your PC LAN IP (not 127.0.0.1):
   ```json
   { "mode": "http", "base_url": "http://YOUR.LAN.IP.HERE:8765", "poll": 0.3 }
   ```
2. `updater` → `test_agent.lua` + navigation `lib/*` (and calibrate → `/boat_control.json`).
3. Run `test_agent` (chunk loaded). Expect `mode http`.

Dock after green tests: agent `navigate_to` → **(340, 165)**.

## What was finished
HTTP poll bridge + FS mode retained; docs updated; pushed on `amazeballs-cc` `main`.

| Piece | Path |
|-------|------|
| On-computer agent (FS + HTTP) | `navigation/test_agent.lua` |
| HTTP server | `realtime_tests/http_server.mjs` (`npm run serve`) |
| Host bridge / tests | `realtime_tests/bridge.mjs`, `run_tests.mjs` |
| Examples | `bridge.example.json` (http), `bridge.fs.example.json`, `realtime_bridge.example.json` |

## If still inverted / one-sided after update
- Fresh `calibrate`; re-run `npm test`; A/D notes print Δyaw°.
- Do **not** trust `navigation/sim` greens for in-game.
