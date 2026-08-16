# Amazeballs ComputerCraft scripts

Public script repo for the Amazeballs Minecraft pack. Computers on multiplayer pull selected files from here over HTTP on every reboot.

Repo: [gleeglor/amazeballs-cc](https://github.com/Gleeglor/amazeballs-cc)

## Install on a computer

In the ComputerCraft computer shell:

```text
wget https://raw.githubusercontent.com/gleeglor/amazeballs-cc/main/install.lua install
install
```

That downloads `updater.lua`, writes a managed `startup.lua`, and opens file selection setup.

### Reinstall / change selected files

```text
install
```

Or: `updater --setup` / `updater setup` / `updater reinstall`.

Pull only (no selection UI): `install pull`

### Setup UI

| Key | Action |
|-----|--------|
| Up / Down | Move cursor |
| Space | Toggle select file (or whole folder) |
| Enter | Open folder, toggle file, or finish on **[DONE]** |
| Backspace | Go up one folder |

After **Done**, pick which downloaded program to run on boot (or `0` for none). Saved to `/cc_update.json`.

### Every reboot

`startup.lua` runs the updater, then the configured boot program.

## Roles (cannon)

| Computer | Select | Boot program |
|----------|--------|--------------|
| Hub | `hub.lua` | `hub` |
| Fire | `fire.lua` | `fire` |
| Ammo turtle | `ammo.lua` | `ammo` |

## Roles (boat)

Select the whole **`boat/`** folder (or all files under it), then boot **`agent`**.

| File | Role |
|------|------|
| `agent` | WebSocket live agent (recommended boot). Auto-reconnects, panic-stops motors on drop. |
| `boat` | Local menu (calibrate / teleop / places) |
| `lib/*` | Motors (±24 RPM Create Addition), Reassembly mix, calib, route, dock, UI |
| `rendezvous.json` | Public `wss://` URL the agent fetches from GitHub |
| `tests/live_smoke.lua` | In-game smoke checks |

### Boat one-time setup

1. Wire **Create Addition electric motors** to the boat computer (wired modems). Cap in software is **±24 RPM per motor**.
2. Install updater, select `boat/`, boot `agent`.
3. On this PC:

```bash
cd cc-scripts/tools
npm install
npm run agent          # listens on :8765
# other terminal:
cloudflared tunnel --url http://127.0.0.1:8765
```

4. Put the tunnel URL into `boat/rendezvous.json` as `"wss": "wss://...."` (use `wss://` even if cloudflared prints `https://`), commit/push, then reboot the boat computer — or write `/agent.json` on the computer:

```json
{"wss":"wss://your-tunnel.example"}
```

5. In-game: press **C** to calibrate (open water), **T** for teleop, **X** panic stop. Host can `POST /rpc` with `{"method":"pose"}` etc.

### Docking

Uses **`simulated:docking_connector`** on boat and shore. Lock when within **0.5 blocks** and **20°**. Thrusters cut on lock; item transfer via CC inventory APIs across the linked inventories.

### Host tests

```bash
cd cc-scripts/tools && npm test
```

## Keep scripts up to date (author)

1. Edit under `cc-scripts/` (update catalogs when adding files).
2. Commit and push to `gleeglor/amazeballs-cc` (`main`).
3. In-game: reboot or `updater`.

## Server requirement

ComputerCraft HTTP must allow `raw.githubusercontent.com`. WebSockets must be enabled (already on in this pack). Public tunnel host must not be blocked by `$private` deny (use a public hostname).

## Layout

```text
catalog.json / catalog.v2.json
install.lua / updater.lua
cannon/
boat/          agent, menu, lib, tests, rendezvous
tools/         agent_host.mjs, test_host.mjs
```
