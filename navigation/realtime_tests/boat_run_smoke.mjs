/**
 * One-shot smoke for A↔B soft water progress (host side).
 *
 * Prefers agent `follow_path` (same as `boat` → `run` legs). Falls back to `go_port`.
 *
 *   npm run boat-run-smoke
 *   npm run boat-run-smoke -- --go-port   # force go_port only
 */
import { openSession } from "./bridge.mjs";

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function forceUnlock() {
  try {
    await fetch("http://127.0.0.1:8765/v1/unlock", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ force: true }),
    });
  } catch {
    /* ignore */
  }
}

async function follow(session, name) {
  console.log(`\n=== follow_path ${name} ===`);
  await session.stopMotors({ timeoutMs: 10000 }).catch(() => {});
  const res = await session.sendCommand(
    {
      cmd: "follow_path",
      path: name,
      arrive_dist: 20,
      timeout: 360,
    },
    { timeoutMs: 420000 },
  );
  await session.stopMotors({ timeoutMs: 10000 }).catch(() => {});
  console.log(JSON.stringify({ ok: res?.ok, error: res?.error, result: res?.result }, null, 2));
  return res;
}

async function goPort(session, port) {
  console.log(`\n=== go_port ${port} (alt to boat run) ===`);
  await session.stopMotors({ timeoutMs: 10000 }).catch(() => {});
  const res = await session.sendCommand(
    {
      cmd: "go_port",
      port,
      timeout: 360,
      arrive_dist: 20,
      handshake: false,
      approach: true,
    },
    { timeoutMs: 420000 },
  );
  await session.stopMotors({ timeoutMs: 10000 }).catch(() => {});
  console.log(
    JSON.stringify(
      {
        ok: res?.ok,
        error: res?.error,
        arrived: res?.result?.arrived,
        distance: res?.result?.distance,
      },
      null,
      2,
    ),
  );
  return res;
}

async function main() {
  const forceGo = process.argv.includes("--go-port");
  await forceUnlock();
  const session = await openSession({ claimMs: 600000 });
  try {
    const ping = await session.sendCommand({ cmd: "ping" }, { timeoutMs: 15000 });
    if (!ping?.ok) {
      throw new Error("agent ping failed — is test_agent running?");
    }
    console.log("agent ok", ping.result || ping);

    if (forceGo) {
      await goPort(session, "port_b");
      await sleep(1500);
      await goPort(session, "port_a");
    } else {
      let a = await follow(session, "to_port_b");
      if (!a?.ok && String(a?.error || "").includes("unknown")) {
        console.log("follow_path unavailable — using go_port");
        a = await goPort(session, "port_b");
      }
      await sleep(1500);
      let b = await follow(session, "to_port_a");
      if (!b?.ok && String(b?.error || "").includes("unknown")) {
        b = await goPort(session, "port_a");
      }
      const ok = !!(a?.ok || a?.result?.arrived) && !!(b?.ok || b?.result?.arrived);
      console.log(ok ? "\nBOAT RUN SMOKE OK" : "\nBOAT RUN SMOKE INCOMPLETE");
      process.exit(ok ? 0 : 1);
    }
    console.log("\nBOAT RUN SMOKE OK (go_port)");
  } finally {
    await session.stopMotors({ timeoutMs: 8000 }).catch(() => {});
    await forceUnlock();
    session.close?.();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
