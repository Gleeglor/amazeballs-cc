/**
 * One-off host script: deploy Lua → optional section → reboot boat → wait heartbeat.
 *
 *   node run_and_reboot.mjs                  # deploy + reboot + wait alive
 *   node run_and_reboot.mjs --section test   # then SKIP_DEPLOY npm test
 *   node run_and_reboot.mjs --section dual   # then dual_dock_live.mjs
 *   node run_and_reboot.mjs --no-reboot      # deploy + reload_libs only
 *   node run_and_reboot.mjs --skip-deploy    # reboot (or reload) only
 */
import { spawn } from "node:child_process";
import { openSession } from "./bridge.mjs";
import { deployViaBridge } from "./deploy_http.mjs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BASE = "http://127.0.0.1:8765";

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function parseArgs(argv) {
  const out = { reboot: true, deploy: true, section: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--no-reboot") out.reboot = false;
    else if (a === "--skip-deploy") out.deploy = false;
    else if (a === "--section") out.section = argv[++i];
    else if (a === "--help" || a === "-h") out.help = true;
  }
  return out;
}

async function forceUnlock() {
  try {
    await fetch(`${BASE}/v1/unlock`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ force: true }),
    });
  } catch {
    /* ignore */
  }
  try {
    await fetch(`${BASE}/v1/clear`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ force: true }),
    });
  } catch {
    /* ignore */
  }
}

async function waitAlive(maxMs = 120_000) {
  const t0 = Date.now();
  while (Date.now() - t0 < maxMs) {
    try {
      const r = await fetch(`${BASE}/v1/health`);
      const j = await r.json();
      if (j.agent_alive) return j;
    } catch {
      /* retry */
    }
    await sleep(2000);
  }
  throw new Error("agent did not come alive after wait");
}

function runNode(script, env = {}) {
  return new Promise((resolve) => {
    const c = spawn("node", [script], {
      cwd: __dirname,
      env: { ...process.env, ...env },
      stdio: "inherit",
    });
    c.on("close", (code) => resolve(code ?? 1));
  });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(`Usage: node run_and_reboot.mjs [--no-reboot] [--skip-deploy] [--section test|dual]`);
    process.exit(0);
  }

  await forceUnlock();
  const session = openSession({ mode: "http" });
  console.log("Bridge:", session.describe());

  const ping = await session.ping({ timeoutMs: 20000 });
  if (!ping.ok) {
    console.error("ping failed", ping.error);
    process.exit(2);
  }
  console.log("ping ok computer_id=", ping.result?.computer_id);
  await session.stopMotors({ timeoutMs: 15000 }).catch(() => {});

  if (args.deploy) {
    const dep = await deployViaBridge(session, { reboot: false, quiet: false });
    console.log(
      "deploy wrote",
      dep.written.filter((w) => !w.skipped).length,
      "startupOk=",
      dep.startupOk,
    );
  }

  if (args.reboot) {
    // Prefer agent reboot cmd (writes startup then os.reboot).
    console.log("reboot …");
    try {
      await session.sendCommand({ cmd: "reboot" }, { timeoutMs: 15000 });
    } catch (e) {
      console.warn("reboot cmd:", e.message || e);
    }
    await forceUnlock();
    console.log("waiting for agent heartbeat …");
    const h = await waitAlive(180_000);
    console.log("agent alive age_ms=", h.agent_age_ms);
    await sleep(1500);
    const s2 = openSession({ mode: "http" });
    const p2 = await s2.ping({ timeoutMs: 30000 });
    console.log("post-reboot ping", p2.ok, p2.result?.computer_id);
    await s2.stopMotors({ timeoutMs: 15000 }).catch(() => {});
  } else {
    const rl = await session.sendCommand({ cmd: "reload_libs" }, { timeoutMs: 25000 });
    console.log("reload_libs ok=", rl.ok, rl.error || "");
  }

  // Release host lock so follow-up npm test / dual_dock can acquire their own.
  if (typeof session.unlock === "function") {
    await session.unlock();
  }
  await forceUnlock();

  if (args.section === "test") {
    const code = await runNode("run_tests.mjs", { SKIP_DEPLOY: "1" });
    process.exit(code);
  }
  if (args.section === "dual") {
    const code = await runNode("dual_dock_live.mjs");
    process.exit(code);
  }
  console.log("DONE (no section)");
}

main().catch(async (e) => {
  console.error(e);
  await forceUnlock();
  process.exit(1);
});
