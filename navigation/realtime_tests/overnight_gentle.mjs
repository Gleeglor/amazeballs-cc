/**
 * Overnight gentle soft-hold loop.
 * Waits for test_agent, reload_libs, soft go_port water holds only.
 * Never seeks shore landmarks; arrive_dist 20; motors stop on reach.
 */
import { openSession } from "./bridge.mjs";
import fs from "node:fs";

const OVERNIGHT_MD = new URL("../OVERNIGHT.md", import.meta.url).pathname;

function log(msg) {
  const line = `${new Date().toISOString()} ${msg}`;
  console.log(line);
  try {
    fs.appendFileSync(OVERNIGHT_MD, `\n- \`${line}\`\n`);
  } catch {
    /* ignore */
  }
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function waitAgent(s, maxMs = 3600000) {
  const t0 = Date.now();
  while (Date.now() - t0 < maxMs) {
    try {
      const st = await s.readStatus();
      if (st?.alive) {
        const p = await s.ping({ timeoutMs: 12000 });
        if (p.ok) return true;
      }
    } catch {
      /* ignore */
    }
    await sleep(5000);
  }
  return false;
}

async function main() {
  const s = openSession({});
  for (;;) {
    log("gentle overnight: waiting for agent…");
    if (!(await waitAgent(s))) {
      log("gentle overnight: agent wait timed out — retrying");
      continue;
    }
    log("gentle overnight: agent alive — reload + soft park");
    await s.stopMotors({ timeoutMs: 15000 }).catch(() => {});
    for (let i = 0; i < 3; i++) {
      const rl = await s.sendCommand({ cmd: "reload_libs" }, { timeoutMs: 45000 }).catch((e) => ({
        ok: false,
        error: e.message,
      }));
      log(`reload_libs ok=${rl.ok} err=${rl.error || ""}`);
      if (rl.ok) break;
      await sleep(800);
    }
    await s.stopMotors({ timeoutMs: 12000 }).catch(() => {});

    let failed = false;
    for (const port of ["port_b", "port_a"]) {
      log(`gentle go_port ${port}`);
      try {
        const r = await s.sendCommand(
          {
            cmd: "go_port",
            port,
            timeout: 300,
            berth_timeout: 60,
            approach: true,
            arrive_dist: 20,
            handshake: false,
          },
          { timeoutMs: 420000 },
        );
        log(
          `go_port ${port} ok=${r.ok} arrived=${r.result?.arrived} dist=${r.result?.distance} err=${r.error || ""}`,
        );
      } catch (e) {
        failed = true;
        log(`go_port ${port} throw ${String(e.message || e).slice(0, 140)}`);
        break;
      }
      await s.stopMotors({ timeoutMs: 15000 }).catch(() => {});
      await sleep(2000);
    }

    if (!failed) {
      const pose = await s.sendCommand({ cmd: "sample_pose" }, { timeoutMs: 20000 }).catch(() => null);
      log(`final pose ${JSON.stringify(pose?.result?.pose || null)}`);
      log("gentle overnight soft cycle done — sleeping 10m then idle soft A");
      await sleep(600000);
      // Soft re-hold at A periodically
      try {
        await s.sendCommand(
          {
            cmd: "go_port",
            port: "port_a",
            timeout: 240,
            berth_timeout: 50,
            approach: true,
            arrive_dist: 20,
            handshake: false,
          },
          { timeoutMs: 360000 },
        );
      } catch (e) {
        log(`periodic A hold throw ${String(e.message || e).slice(0, 120)}`);
      }
      await s.stopMotors({ timeoutMs: 15000 }).catch(() => {});
    } else {
      log("gentle overnight: nav interrupted — wait for agent again");
      await sleep(10000);
    }
  }
}

main().catch((e) => {
  console.error(e);
  try {
    fs.appendFileSync(OVERNIGHT_MD, `\n- crash: ${String(e)}\n`);
  } catch {
    /* ignore */
  }
  process.exit(1);
});
