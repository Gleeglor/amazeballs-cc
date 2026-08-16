/**
 * Overnight watcher: wait for test_agent heartbeat, run realtime tests,
 * then navigate to base dock (340, 165).
 *
 *   node overnight_loop.mjs
 *   node overnight_loop.mjs --once
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { discoverComputers, resolveComputer, defaultMinecraftRoot } from "./discover.mjs";
import { ping, sendCommand, stopMotors, readStatus } from "./bridge.mjs";
import { spawn } from "node:child_process";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DOCK = { x: 340, z: 165 };
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

function findAgentComputer() {
  const all = discoverComputers(defaultMinecraftRoot());
  for (const c of all) {
    const st = readStatus(c.dir);
    if (st?.alive) return { ...c, status: st, source: "heartbeat" };
  }
  // Prefer boat-ish even without heartbeat
  try {
    return { ...resolveComputer({}), status: readStatus(resolveComputer({}).dir) };
  } catch {
    return null;
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

async function goDock(dir) {
  console.log(`\n=== navigate_to dock (${DOCK.x}, ${DOCK.z}) ===`);
  await stopMotors(dir, { timeoutMs: 10000 });
  const res = await sendCommand(
    dir,
    {
      cmd: "navigate_to",
      x: DOCK.x,
      z: DOCK.z,
      timeout: 120,
      arrive_dist: 4,
      mode: "cruise",
    },
    { timeoutMs: 150000 },
  );
  await stopMotors(dir, { timeoutMs: 10000 });
  return res;
}

async function cycle(once) {
  writeStatus({ phase: "waiting_for_agent", dock: DOCK });
  console.log("Overnight loop — waiting for test_agent (realtime_status.json alive)…");
  console.log("Dock target:", DOCK);

  for (;;) {
    const target = findAgentComputer();
    if (!target?.dir) {
      writeStatus({ phase: "no_computer", message: "No CC computers scored; open world + place boat computer" });
      if (once) return { blocked: "no_computer" };
      await sleep(POLL_MS);
      continue;
    }

    const st = readStatus(target.dir);
    if (!st?.alive) {
      writeStatus({
        phase: "waiting_for_agent",
        world: target.world,
        computer_id: target.id,
        dir: target.dir,
        hint: "On boat: updater (select test_agent) then run test_agent",
      });
      console.log(`[${new Date().toISOString()}] no agent heartbeat at ${target.dir}`);
      if (once) return { blocked: "agent_not_running", target };
      await sleep(POLL_MS);
      continue;
    }

    console.log(`Agent live: world=${target.world} id=${target.id}`);
    writeStatus({ phase: "testing", world: target.world, computer_id: target.id });

    try {
      await ping(target.dir);
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
        note: "Fix Lua, deploy_to_computer or updater, re-run test_agent",
      });
      console.error("Tests failed — will retry after deploy window");
      if (once) return { blocked: "tests_failed", exit: test.code };
      await sleep(POLL_MS * 2);
      continue;
    }

    writeStatus({ phase: "navigating", dock: DOCK });
    let nav;
    try {
      nav = await goDock(target.dir);
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
        ? `Arrived near dock (${DOCK.x},${DOCK.z}) dist=${dist}`
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
