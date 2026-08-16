/**
 * Wait for test_agent after reboot, finish deploy, soft-reload, green tests, dual-dock A↔B, park A.
 * Does NOT spam ping while down (that used to wedge claimed pending). Polls /v1/health + clears inbox.
 *
 *   node recover_overnight.mjs
 */
import { openSession } from "./bridge.mjs";
import { deployViaBridge } from "./deploy_http.mjs";
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const OVERNIGHT_MD = path.resolve(__dirname, "../OVERNIGHT.md");
const BASE = "http://127.0.0.1:8765";

function appendLog(line) {
  const ts = new Date().toISOString();
  const entry = `- \`${ts}\` ${line}\n`;
  try {
    fs.appendFileSync(OVERNIGHT_MD, entry);
  } catch {
    /* ignore */
  }
  console.log(ts, line);
}

async function httpJson(method, url, body) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 4000);
  try {
    const res = await fetch(url, {
      method,
      signal: ctrl.signal,
      headers: body != null ? { "Content-Type": "application/json" } : undefined,
      body: body != null ? JSON.stringify(body) : undefined,
    });
    const text = await res.text();
    let data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = { raw: text };
    }
    return { ok: res.ok, status: res.status, data };
  } finally {
    clearTimeout(t);
  }
}

async function clearInbox() {
  try {
    await httpJson("POST", `${BASE}/v1/clear`, {});
  } catch {
    /* server may be old */
  }
}

function runNpmTest() {
  return new Promise((resolve) => {
    const child = spawn("node", ["run_tests.mjs", "--no-deploy"], {
      cwd: __dirname,
      env: { ...process.env, SKIP_DEPLOY: "1" },
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

function runDualDock() {
  return new Promise((resolve) => {
    const child = spawn("node", ["dual_dock_live.mjs"], {
      cwd: __dirname,
      stdio: ["ignore", "pipe", "pipe"],
    });
    child.stdout.on("data", (d) => process.stdout.write(d));
    child.stderr.on("data", (d) => process.stderr.write(d));
    child.on("close", (code) => resolve(code ?? 1));
  });
}

/** Passive wait: health heartbeat only — no ping spam. */
async function waitForAgent(session, maxMs = 3_600_000) {
  const t0 = Date.now();
  let lastNote = 0;
  await clearInbox();

  while (Date.now() - t0 < maxMs) {
    await clearInbox();

    let health = null;
    try {
      const h = await httpJson("GET", `${BASE}/v1/health`, null);
      health = h.data;
    } catch {
      health = null;
    }

    const age = health?.agent_age_ms;
    const alive = !!(health?.agent_alive && age != null && age < 8000);

    if (alive) {
      // Confirm with a single ping (inbox was cleared).
      try {
        const p = await session.ping({ timeoutMs: 10000 });
        if (p.ok) {
          appendLog(`Agent ping OK computer_id=${p.result?.computer_id}`);
          return true;
        }
      } catch (e) {
        appendLog(`Heartbeat seen but ping failed: ${String(e.message || e).slice(0, 100)}`);
      }
    }

    const now = Date.now();
    if (now - lastNote > 60000) {
      lastNote = now;
      appendLog(
        `Still waiting for test_agent (health alive=${health?.agent_alive} age=${age ?? "n/a"}) — boat must re-run test_agent if at craft shell`,
      );
    }
    await new Promise((r) => setTimeout(r, 3000));
  }
  return false;
}

async function ensureStartup(session) {
  const content = 'shell.run("test_agent")\n';
  const w = await session.sendCommand(
    { cmd: "write_file", path: "startup", content },
    { timeoutMs: 15000 },
  );
  if (!w.ok) {
    appendLog(`startup write FAIL: ${w.error}`);
    return false;
  }
  // Prefer verify via read_file when available
  try {
    const r = await session.sendCommand({ cmd: "read_file", path: "startup" }, { timeoutMs: 10000 });
    if (r.ok && String(r.result?.content || "").includes("test_agent")) {
      appendLog("startup verified on boat");
      return true;
    }
  } catch {
    /* old agent may lack read_file */
  }
  appendLog("startup write ok (read verify skipped)");
  return true;
}

async function main() {
  appendLog("recover_overnight v2 — passive health wait (no ping spam)");
  const session = openSession({ mode: "http" });
  const ok = await waitForAgent(session);
  if (!ok) {
    appendLog("FATAL: agent never returned after 1h");
    process.exit(2);
  }

  appendLog("SEIZED agent — writing startup first, then full deploy");
  await ensureStartup(session);

  appendLog("Full HTTP deploy (no reboot)…");
  const dep = await deployViaBridge(session, { reboot: false, quiet: false });
  appendLog(`Deployed ${dep.written.length} files`);

  // Re-assert startup after deploy (deploy also ships startup; belt+suspenders)
  await ensureStartup(session);

  const rl = await session.sendCommand({ cmd: "reload_libs" }, { timeoutMs: 20000 }).catch((e) => ({
    ok: false,
    error: String(e.message || e),
  }));
  appendLog(`reload_libs ok=${rl.ok} ${rl.error || JSON.stringify(rl.result || {})}`);

  appendLog("Running npm test…");
  const test = await runNpmTest();
  appendLog(`npm test exit=${test.code}`);

  if (test.code !== 0) {
    appendLog("Tests still failing — stopping motors; will leave recover incomplete");
    await session.stopMotors({ timeoutMs: 10000 }).catch(() => {});
    process.exit(1);
  }

  appendLog("Tests GREEN — dual dock live (B then park A)…");
  const dd = await runDualDock();
  appendLog(`dual_dock_live exit=${dd}`);

  if (dd !== 0) {
    // Fallback: at least park at A
    appendLog("dual_dock failed — fallback soft go_port Port A water hold");
    try {
      await session.sendCommand(
        {
          cmd: "go_port",
          port: "port_a",
          timeout: 300,
          berth_timeout: 60,
          approach: true,
          arrive_dist: 20,
          handshake: false,
        },
        { timeoutMs: 360000 },
      );
      await ensureStartup(session);
      appendLog("Fallback soft park-at-A water hold attempted");
    } catch (e) {
      appendLog("Fallback park failed: " + String(e.message || e).slice(0, 120));
    }
    process.exit(1);
  }

  await ensureStartup(session);
  appendLog("DONE — control green + dual-dock + soft water hold A + startup on disk");
  try {
    const stamp = new Date().toISOString();
    fs.appendFileSync(
      OVERNIGHT_MD,
      `\n## DONE\n- \`${stamp}\` Mandate complete: npm test green, A↔B dual-dock soft water holds (≤20), gentle thrust. Never shore slam.\n`,
    );
  } catch {
    /* ignore */
  }
}

main().catch((e) => {
  console.error(e);
  appendLog("recover_overnight crash: " + String(e.message || e));
  process.exit(1);
});
