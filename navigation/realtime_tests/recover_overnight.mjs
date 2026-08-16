/**
 * Wait for test_agent after reboot, finish deploy, soft-reload, green tests, dock to Port A.
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
const PORT_A = { x: 341, z: 163 };

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

async function waitForAgent(session, maxMs = 3_600_000) {
  const t0 = Date.now();
  while (Date.now() - t0 < maxMs) {
    try {
      const p = await session.ping({ timeoutMs: 8000 });
      if (p.ok) {
        appendLog(`Agent ping OK computer_id=${p.result?.computer_id}`);
        return true;
      }
    } catch {
      /* retry */
    }
    const st = await session.readStatus().catch(() => null);
    if (st?.alive && st.bridge === "http") {
      // still try ping
    }
    await new Promise((r) => setTimeout(r, 10000));
    if ((Date.now() - t0) % 60000 < 12000) {
      appendLog("Still waiting for test_agent (run test_agent on boat if idle)…");
    }
  }
  return false;
}

async function main() {
  appendLog("recover_overnight started — waiting for boat test_agent");
  const session = openSession({ mode: "http" });
  const ok = await waitForAgent(session);
  if (!ok) {
    appendLog("FATAL: agent never returned — resume: on boat run `test_agent`, then `node recover_overnight.mjs`");
    process.exit(2);
  }

  // Ensure startup exists for future reboots
  try {
    await session.sendCommand(
      { cmd: "write_file", path: "startup", content: 'shell.run("test_agent")\n' },
      { timeoutMs: 15000 },
    );
  } catch (e) {
    appendLog("startup write: " + String(e.message || e).slice(0, 120));
  }

  appendLog("Full HTTP deploy…");
  const dep = await deployViaBridge(session, { reboot: false, quiet: false });
  appendLog(`Deployed ${dep.written.length} files`);

  const rl = await session.sendCommand({ cmd: "reload_libs" }, { timeoutMs: 20000 }).catch((e) => ({
    ok: false,
    error: String(e.message || e),
  }));
  appendLog(`reload_libs ok=${rl.ok} ${rl.error || JSON.stringify(rl.result || {})}`);

  appendLog("Running npm test…");
  const test = await runNpmTest();
  appendLog(`npm test exit=${test.code}`);

  if (test.code === 0) {
    appendLog("Tests GREEN — dual dock live (B then park A)…");
    await new Promise((resolve) => {
      const child = spawn("node", ["dual_dock_live.mjs"], {
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
      child.on("close", (code) => {
        appendLog(`dual_dock_live exit=${code}`);
        resolve(code);
      });
    });
  } else {
    appendLog("Tests still failing — see console; leave motors stopped");
    await session.stopMotors({ timeoutMs: 10000 }).catch(() => {});
  }

  appendLog("recover_overnight done");
}

main().catch((e) => {
  console.error(e);
  appendLog("recover_overnight crash: " + String(e.message || e));
  process.exit(1);
});
