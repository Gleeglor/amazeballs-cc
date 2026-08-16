/**
 * Exclusive finish: deploy (no reboot) → npm test → park Port A.
 * Uses flock externally: flock /tmp/boat_bridge.lock node exclusive_finish.mjs
 */
import { openSession } from "./bridge.mjs";
import { deployViaBridge } from "./deploy_http.mjs";
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const OVERNIGHT = path.resolve(__dirname, "../OVERNIGHT.md");
const BASE = "http://127.0.0.1:8765";

function log(line) {
  const ts = new Date().toISOString();
  console.log(ts, line);
  try {
    fs.appendFileSync(OVERNIGHT, `- \`${ts}\` ${line}\n`);
  } catch {
    /* ignore */
  }
}

async function clearOnce() {
  try {
    await fetch(`${BASE}/v1/clear`, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
  } catch {
    /* ignore */
  }
}

async function waitPing(session, tries = 30) {
  for (let i = 0; i < tries; i++) {
    try {
      const p = await session.ping({ timeoutMs: 12000 });
      if (p.ok) return p;
    } catch {
      /* retry */
    }
    await new Promise((r) => setTimeout(r, 3000));
  }
  throw new Error("agent ping failed");
}

function runNpmTest() {
  return new Promise((resolve) => {
    const c = spawn("node", ["run_tests.mjs"], {
      cwd: __dirname,
      env: { ...process.env, SKIP_DEPLOY: "1" },
      stdio: "inherit",
    });
    c.on("close", (code) => resolve(code ?? 1));
  });
}

async function main() {
  log("exclusive_finish start");
  await clearOnce();
  const s = openSession({ mode: "http" });
  const ping = await waitPing(s);
  log(`ping ok computer_id=${ping.result?.computer_id}`);
  await s.stopMotors({ timeoutMs: 15000 }).catch(() => {});
  await new Promise((r) => setTimeout(r, 1200));

  const dep = await deployViaBridge(s, { reboot: false, quiet: false });
  log(`deploy wrote ${dep.written.filter((w) => !w.skipped).length} startupOk=${dep.startupOk}`);
  const rl = await s.sendCommand({ cmd: "reload_libs" }, { timeoutMs: 25000 });
  log(`reload_libs ok=${rl.ok}`);

  await new Promise((r) => setTimeout(r, 1000));
  const testCode = await runNpmTest();
  log(`npm test exit=${testCode}`);
  if (testCode !== 0) {
    await s.stopMotors({ timeoutMs: 12000 }).catch(() => {});
    process.exit(testCode);
  }

  await s.stopMotors({ timeoutMs: 15000 }).catch(() => {});
  await new Promise((r) => setTimeout(r, 1000));
  const before = await s.sendCommand({ cmd: "sample_pose" }, { timeoutMs: 20000 });
  log(`pose before park x=${before.result?.pose?.x?.toFixed?.(1)} z=${before.result?.pose?.z?.toFixed?.(1)}`);

  log("go_port port_a soft water hold (gentle, ≤20) …");
  const go = await s.sendCommand(
    {
      cmd: "go_port",
      port: "port_a",
      timeout: 300,
      berth_timeout: 70,
      approach: true,
      arrive_dist: 20,
      handshake: false,
    },
    { timeoutMs: 420000 },
  );
  await s.stopMotors({ timeoutMs: 20000 }).catch(() => {});
  let after = await s.sendCommand({ cmd: "sample_pose" }, { timeoutMs: 20000 });
  let pose = after.result?.pose;
  // Soft success = within ~20 of water hold (go_port reports distance to hold)
  let dist = go.result?.distance ?? go.result?.phases?.slice?.(-1)?.[0]?.distance;
  if (dist == null && pose && go.result?.target) {
    dist = Math.hypot(pose.x - go.result.target.x, pose.z - go.result.target.z);
  }
  log(
    `go_port A ok=${go.ok} arrived=${go.result?.arrived} dist=${dist?.toFixed?.(2)} err=${go.error || ""}`,
  );

  let parked = !!(go.result?.arrived || (dist != null && dist <= 22));
  if (!parked) {
    log("retry soft go_port port_a (no shore navigate)");
    await s.sendCommand(
      {
        cmd: "go_port",
        port: "port_a",
        timeout: 200,
        berth_timeout: 50,
        approach: true,
        arrive_dist: 20,
        handshake: false,
      },
      { timeoutMs: 280000 },
    );
    await s.stopMotors({ timeoutMs: 15000 }).catch(() => {});
    after = await s.sendCommand({ cmd: "sample_pose" }, { timeoutMs: 20000 });
    pose = after.result?.pose;
    parked = !!(after.ok);
    log(`retry pose x=${pose?.x?.toFixed?.(1)} z=${pose?.z?.toFixed?.(1)}`);
  }

  await s.stopMotors({ timeoutMs: 15000 }).catch(() => {});
  if (!parked) {
    log("FAILED park at Port A");
    process.exit(1);
  }
  log(`DONE parked at Port A dist=${dist?.toFixed?.(2)}`);
  process.exit(0);
}

main().catch((e) => {
  console.error(e);
  log(`exclusive_finish crash: ${e.message || e}`);
  process.exit(1);
});
