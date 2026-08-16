/**
 * Live dual-dock verification: Port A (341,163) ↔ Port B (383,285).
 * Uses go_port (cruise → berth_align → docking_port handshake stub).
 * Ends parked at Port A.
 *
 *   node dual_dock_live.mjs
 *   node dual_dock_live.mjs --skip-b   # only park at A
 */
import { openSession } from "./bridge.mjs";

const PORT_A = "port_a";
const PORT_B = "port_b";

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function distTo(pose, x, z) {
  if (!pose) return null;
  const dx = (pose.x || 0) - x;
  const dz = (pose.z || 0) - z;
  return Math.hypot(dx, dz);
}

async function sample(session) {
  const r = await session.sendCommand({ cmd: "sample_pose" }, { timeoutMs: 15000 });
  return r?.result?.pose || null;
}

async function goPort(session, port, label) {
  console.log(`\n=== go_port ${label} (${port}) ===`);
  const res = await session.sendCommand(
    {
      cmd: "go_port",
      port,
      timeout: 360,
      berth_timeout: 75,
      approach: true,
    },
    { timeoutMs: 480000 },
  );
  await session.stopMotors({ timeoutMs: 12000 }).catch(() => {});
  const r = res?.result || {};
  console.log(
    JSON.stringify(
      {
        ok: res?.ok,
        arrived: r.arrived,
        distance: r.distance,
        phases: (r.phases || []).map((p) => ({
          phase: p.phase,
          ok: p.ok,
          distance: p.distance,
          mode: p.mode,
        })),
        handshake: r.handshake && {
          ok: r.handshake.ok,
          mode: r.handshake.mode,
          steps: (r.handshake.transcript || []).map((t) => t.kind),
        },
        pose: r.pose_after,
      },
      null,
      2,
    ),
  );
  return res;
}

async function main() {
  const skipB = process.argv.includes("--skip-b");
  const session = openSession({});
  console.log("Bridge:", session.describe());

  const st = await session.readStatus().catch(() => null);
  if (!st?.alive) {
    console.error("Agent not alive");
    process.exit(2);
  }

  const ping = await session.ping({ timeoutMs: 10000 });
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
  const dA = distTo(after, 341, 163);
  const parked = dA != null && dA <= 5.5;
  const bOk = skipB || (results.to_b?.ok && results.to_b?.result?.arrived);
  const aOk = results.to_a?.ok && (results.to_a?.result?.arrived || parked);
  const hsA = results.to_a?.result?.handshake?.ok !== false;
  const hsB = skipB || results.to_b?.result?.handshake?.ok !== false;

  console.log("\n=== dual dock summary ===");
  console.log({
    b_leg: skipB ? "skipped" : !!bOk,
    a_leg: !!aOk,
    handshake_ok: !!(hsA && hsB),
    parked_at_a: parked,
    dist_to_a: dA,
    pose: after,
  });

  if (!aOk || !bOk || !parked || !hsA || !hsB) {
    process.exit(1);
  }
  console.log("DUAL DOCK OK — boat parked at Port A");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
