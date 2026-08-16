# Realtime in-game boat tests (filesystem bridge)

**This is the source of truth for boat controls** — not `navigation/sim/`.

The host (your Linux box) talks to the boat ComputerCraft computer by reading/writing files under the world save:

`saves/<world>/computercraft/computer/<id>/`

| File | Who writes | Purpose |
|------|------------|---------|
| `realtime_inbox.json` | Host | Command for the agent |
| `realtime_outbox.json` | Agent | Result for the host |
| `realtime_status.json` | Agent | Heartbeat / watchdog |

## Setup (once)

1. Push/pull scripts: on the boat computer run `updater` (or reboot) and select **`test_agent.lua`** plus navigation `lib/*` (and `boat.lua` if you use the menu).
2. Calibrate if needed: `calibrate` → `/boat_control.json`.
3. Optional host config:

```bash
cd cc-scripts/navigation/realtime_tests
cp bridge.example.json bridge.json
# edit world + computer_id
npm run list   # shows discovered computers + scores
```

## Run tests

**In Minecraft (boat computer):**

```text
test_agent
```

Or from the boat menu: `testagent`  
(Q quits the agent; motors are force-stopped.)

**On the host (same machine as Prism):**

```bash
cd cc-scripts/navigation/realtime_tests
npm test
```

Leave Minecraft running with the chunk loaded and `test_agent` active.

## What the suite checks

| Case | Expectation |
|------|-------------|
| `ping` | Agent replies |
| `load_control` | `/boat_control.json` loads (`yaw_sign`, thrusters) |
| idle `apply 0,0,0` | Duties near zero |
| hold **W** | Forward motion and/or net Fx |
| hold **A** (`tz=+1`) | Yaw activity; preferably port+starboard duties |
| hold **D** (`tz=-1`) | Δyaw opposite sign to A |
| stop between cases | Motors zeroed (watchdog if host dies mid-hold) |

Printed `Δyaw°` for A/D tells you whether in-game left/right matches pilot intent.

## Protocol (JSON)

Inbox example:

```json
{ "id": "uuid", "cmd": "hold_apply", "fx": 0, "fy": 0, "tz": 1, "seconds": 1.2 }
```

Commands: `ping`, `stop`, `load_control`, `sample_pose`, `apply`, `hold_apply`, `navigate_to` / `go_dock`, `shutdown`.

Dock helper (after tests green):

```bash
node -e "import('./bridge.mjs').then(async m=>{ const {resolveComputer}=await import('./discover.mjs'); const t=resolveComputer({}); console.log(await m.sendCommand(t.dir,{cmd:'navigate_to',x:340,z:165,timeout:120},{timeoutMs:150000})); })"
# or: npm run overnight:once
```

## Selecting the computer

```bash
npm run list
```

Highest score usually wins (has `boat.lua` / `boat_control.json` / `lib/drive.lua`). Override with `bridge.json`:

```json
{ "world": "New World (3)", "computer_id": "0" }
```

`os.getComputerID()` on the boat matches `<id>` in the save folder.

## Safety

- Agent stops all motors on boot, between host `stop`s, after each hold, on quit, and if no host command arrives for ~3s while thrusting.
- Hold duration capped at 4s on the agent.
