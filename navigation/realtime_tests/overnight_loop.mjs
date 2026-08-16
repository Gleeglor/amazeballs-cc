/**
 * Overnight watcher: wait for test_agent heartbeat, run realtime tests,
 * then navigate to base dock (340, 165).
 *
 *   node overnight_loop.mjs
 *   node overnight_loop.mjs --once
 *
 * Multiplayer: bridge.json mode=http + npm run serve in another terminal.
 * Local discover will not find a remote boat.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { discoverComputers, defaultMinecraftRoot, loadBridgeConfig } from "./discover.mjs";
import { openSession, resolveBridgeMode, readStatus } from "./bridge.mjs";
import { spawn } from "node:child_process";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DOCK = { port: "port_a" }; // soft water hold via go_port (never shore coords)

const STATUS_PATH = path.join(__dirname, "overnight_status.json");
const POLL_MS = 15000;

function writeStatus(obj) {
  fs.writeFileSync(
    STATUS_PATH,
    JSON.stringify({ ...obj, updated_at: new Date().toISOString() }, null, 2) + "\n",
  );
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function openLiveSession() {
  const mode = resolveBridgeMode();
  if (mode === "http") {
    const session = openSession({ mode: "http" });
    let st = null;
    try {
      st = await session.readStatus();
    } catch {
      st = null;
    }
    return { session, status: st, mode };
  }

  // FS: prefer heartbeat, else resolveComputer via openSession
  const { config } = loadBridgeConfig();
  const root = config?.root || defaultMinecraftRoot();
  const all = discoverComputers(root);
  for (const c of all) {
    const st = readStatus(c.dir);
    if (st?.alive) {
      const session = openSession({
        mode: "fs",
        world: c.world,
        computerId: c.id,
        minecraftRoot: root,
      });
      return { session, status: st, mode: "fs", target: c };
    }
  }
  try {
    const session = openSession({ mode: "fs" });
    const st = await session.readStatus();
    return { session, status: st, mode: "fs" };
  } catch {
    return { session: null, status: null, mode: "fs" };
  }
}

function runNpmTest() {
  return new Promise((resolve) => {
    const child = spawn("node", ["run_tests.mjs"], {
      cwd: __dirname,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    child.stdout.on("data", (d) => {
      out += d;
      process.stdout.write(d);
    });
    child.stderr.on("data", (d) => {
      out += d;
      process.stderr.write(d);
    });
    child.on("close", (code) => resolve({ code: code ?? 1, out }));
  });
}

async function goDock(session) {
  console.log(`\n=== go_port soft water hold (${DOCK.port}) — gentle ===`);
  await session.stopMotors({ timeoutMs: 10000 });
  const res = await session.sendCommand(
    {
      cmd: "go_port",
      port: DOCK.port,
      timeout: 300,
      berth_timeout: 60,
      approach: true,
      arrive_dist: 20,
      handshake: false,
    },
    { timeoutMs: 360000 },
  );
  await session.stopMotors({ timeoutMs: 10000 });
  return res;
}

async function cycle(once) {
  const mode = resolveBridgeMode();
  writeStatus({ phase: "waiting_for_agent", dock: DOCK, mode });
  console.log(`Overnight loop (${mode}) — waiting for test_agent…`);
  console.log("Dock target:", DOCK);
  if (mode === "http") {
    console.log("Expect: npm run serve + boat /realtime_bridge.json base_url");
  }

  for (;;) {
    const live = await openLiveSession();
    if (!live.session) {
      writeStatus({
        phase: "no_computer",
        mode,
        message:
          mode === "http"
            ? "HTTP bridge not reachable or no agent yet"
            : "No local boat computer; MP boats need mode=http",
      });
      if (once) return { blocked: "no_computer" };
      await sleep(POLL_MS);
      continue;
    }

    const st = live.status || (await live.session.readStatus().catch(() => null));
    if (!st?.alive) {
      writeStatus({
        phase: "waiting_for_agent",
        mode,
        target: live.session.describe(),
        hint:
          mode === "http"
            ? "On boat: updater + /realtime_bridge.json then test_agent; host: npm run serve"
            : "On boat: updater then test_agent",
      });
      console.log(`[${new Date().toISOString()}] no agent heartbeat (${live.session.describe()})`);
      if (once) return { blocked: "agent_not_running", target: live.session.describe() };
      await sleep(POLL_MS);
      continue;
    }

    console.log(`Agent live: ${live.session.describe()}`);
    writeStatus({ phase: "testing", mode, target: live.session.describe() });

    try {
      await live.session.ping();
    } catch (e) {
      writeStatus({ phase: "ping_fail", error: String(e.message || e) });
      if (once) return { blocked: "ping_fail", error: String(e.message || e) };
      await sleep(POLL_MS);
      continue;
    }

    const test = await runNpmTest();
    if (test.code !== 0) {
      writeStatus({
        phase: "tests_failed",
        exit: test.code,
        note: "Fix Lua, updater on boat, ensure HTTP whitelist + serve",
      });
      console.error("Tests failed — will retry");
      if (once) return { blocked: "tests_failed", exit: test.code };
      await sleep(POLL_MS * 2);
      continue;
    }

    writeStatus({ phase: "navigating", dock: DOCK });
    let nav;
    try {
      nav = await goDock(live.session);
    } catch (e) {
      writeStatus({ phase: "nav_error", error: String(e.message || e) });
      if (once) return { blocked: "nav_error", error: String(e.message || e) };
      await sleep(POLL_MS);
      continue;
    }

    const arrived = nav?.ok && nav.result?.arrived;
    const dist = nav?.result?.distance;
    const after = nav?.result?.pose_after;
    writeStatus({
      phase: arrived ? "docked" : "nav_incomplete",
      arrived: !!arrived,
      distance: dist,
      pose: after,
      dock: DOCK,
      raw: nav?.result,
    });
    console.log(
      arrived
        ? `Soft water hold ${DOCK.port} arrived dist=${dist}`
        : `Nav incomplete dist=${dist} pose=${JSON.stringify(after)}`,
    );
    return { arrived: !!arrived, dist, after, nav };
  }
}

const once = process.argv.includes("--once");
cycle(once)
  .then((r) => {
    console.log("Done:", r);
    process.exit(r?.arrived ? 0 : r?.blocked ? 2 : 1);
  })
  .catch((e) => {
    console.error(e);
    writeStatus({ phase: "crash", error: String(e) });
    process.exit(1);
  });
