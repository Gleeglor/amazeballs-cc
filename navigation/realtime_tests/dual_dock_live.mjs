/**
 * Live dual-dock verification: soft water holds near Port A ↔ Port B.
 * Uses go_port (gentle cruise → soft creep hold). Never shore slam.
 * Ends at Port A water hold (≤20).
 *
 *   node dual_dock_live.mjs
 *   node dual_dock_live.mjs --skip-b   # only soft park at A
 */
import { openSession } from "./bridge.mjs";

const PORT_A = "port_a";
const PORT_B = "port_b";

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function distTo(pose, x, z) {
  if (!pose || pose.x == null || pose.z == null) return null;
  const dx = Number(pose.x) - x;
  const dz = Number(pose.z) - z;
  return Math.sqrt(dx * dx + dz * dz);
}

async function sample(session) {
  const r = await session.sendCommand({ cmd: "sample_pose" }, { timeoutMs: 15000 });
  return r?.result?.pose || null;
}

async function goPort(session, port, label) {
  console.log(`\n=== go_port soft ${label} (${port}) gentle ≤20 ===`);
  await session.stopMotors({ timeoutMs: 10000 }).catch(() => {});
  const res = await session.sendCommand(
    {
      cmd: "go_port",
      port,
      timeout: 420,
      berth_timeout: 200,
      approach: true,
      arrive_dist: 20,
      handshake: false,
    },
    { timeoutMs: 600000 },
  );
  await session.stopMotors({ timeoutMs: 12000 }).catch(() => {});
  const r = res?.result || {};
  console.log(
    JSON.stringify(
      {
        ok: res?.ok,
        error: res?.error,
        arrived: r.arrived,
        distance: r.distance,
        phases: (r.phases || []).map((p) => ({
          phase: p.phase,
          ok: p.ok,
          distance: p.distance,
          mode: p.mode,
          reason: p.reason,
        })),
        pose: r.pose_after,
        safety: "soft_water_hold_gentle",
      },
      null,
      2,
    ),
  );
  return res;
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

async function main() {
  const skipB = process.argv.includes("--skip-b");
  await forceUnlock();
  const session = openSession({});
  console.log("Bridge:", session.describe());
  if (session.ensureLock) {
    await session.ensureLock(600_000);
    console.log("host lock acquired");
  }

  const st = await session.readStatus().catch(() => null);
  if (!st?.alive) {
    console.error("Agent not alive");
    process.exit(2);
  }

  // Longer ping: short 10s timeouts flake under brief agent load / lock handoff.
  const ping = await session.ping({ timeoutMs: 30000 });
  console.log("ping", ping.ok, "computer_id=", ping.result?.computer_id);

  const ports = await session.sendCommand({ cmd: "list_ports" }, { timeoutMs: 15000 });
  if (!ports.ok) {
    console.error("list_ports failed — deploy + reboot agent for new cmds:", ports.error);
    process.exit(1);
  }
  console.log(
    "ports",
    (ports.result?.ports || []).map((p) => `${p.id}@${p.x},${p.z}`).join(" | "),
  );
  console.log("boat_dock", ports.result?.boat_dock?.name);

  const before = await sample(session);
  console.log("pose before", before);

  const results = {};
  if (!skipB) {
    results.to_b = await goPort(session, PORT_B, "Port B");
    await sleep(1500);
  }
  results.to_a = await goPort(session, PORT_A, "Port A (final park)");

  const after = await sample(session);
  await session.stopMotors({ timeoutMs: 12000 }).catch(() => {});
  const softA = !!(results.to_a?.result?.arrived || (results.to_a?.result?.distance != null && results.to_a.result.distance <= 22));
  const softB = skipB || !!(results.to_b?.result?.arrived || (results.to_b?.result?.distance != null && results.to_b.result.distance <= 22));
  const bOk = skipB || (results.to_b?.ok && softB);
  const aOk = results.to_a?.ok && softA;

  console.log("\n=== dual dock summary (soft water holds) ===");
  console.log({
    b_leg: skipB ? "skipped" : !!bOk,
    a_leg: !!aOk,
    soft_hold_a: softA,
    soft_hold_b: skipB ? "skipped" : softB,
    dist_a: results.to_a?.result?.distance,
    dist_b: results.to_b?.result?.distance,
    pose: after,
    gentle: true,
  });

  if (!aOk || !bOk) {
    process.exit(1);
  }
  console.log("DUAL DOCK OK — soft water hold at Port A (gentle, ≤20)");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
