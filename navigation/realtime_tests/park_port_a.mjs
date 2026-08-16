/**
 * Host-driven dock legs (safer than one long go_port): navigate_to → berth_align → handshake.
 * Keeps each bridge command short enough that status heartbeats stay visible.
 *
 *   node park_port_a.mjs           # park at Port A only
 *   node park_port_a.mjs --also-b  # try B then return to A
 */
import { openSession } from "./bridge.mjs";

const A = { id: "port_a", x: 341, z: 163 };
const B = { id: "port_b", x: 383, z: 285 };

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function dist(pose, x, z) {
  if (!pose) return null;
  return Math.hypot((pose.x || 0) - x, (pose.z || 0) - z);
}

async function sample(session) {
  const r = await session.sendCommand({ cmd: "sample_pose" }, { timeoutMs: 20000 });
  return r?.result?.pose || null;
}

async function ensureAlive(session) {
  const p = await session.ping({ timeoutMs: 15000 });
  if (!p.ok) throw new Error("ping failed — agent down");
  return p;
}

async function leg(session, port, label) {
  console.log(`\n=== leg ${label} → (${port.x},${port.z}) ===`);
  await ensureAlive(session);
  await session.stopMotors({ timeoutMs: 12000 }).catch(() => {});

  const before = await sample(session);
  console.log("pose before", before && { x: before.x, z: before.z, yaw_deg: before.yaw_deg });

  // Prefer go_port (water hold). Fallback: navigate_to remaps shore→hold + arrive_dist 20.
  let used = "go_port";
  let res;
  try {
    res = await session.sendCommand(
      {
        cmd: "go_port",
        port: port.id,
        timeout: 240,
        berth_timeout: 60,
        approach: true,
        arrive_dist: 20,
        handshake: false,
      },
      { timeoutMs: 360000 },
    );
  } catch (e) {
    console.warn("go_port failed:", e.message || e);
    used = "stepwise_soft";
    const nav = await session.sendCommand(
      {
        cmd: "navigate_to",
        x: port.x,
        z: port.z,
        y: before?.y,
        timeout: 180,
        arrive_dist: 20,
        mode: "cruise",
      },
      { timeoutMs: 240000 },
    );
    await session.stopMotors({ timeoutMs: 12000 }).catch(() => {});
    const align = await session.sendCommand(
      {
        cmd: "berth_align",
        port: port.id,
        timeout: 50,
      },
      { timeoutMs: 90000 },
    );
    res = {
      ok: !!(nav.ok && (nav.result?.arrived || align.result?.arrived)),
      result: {
        arrived: !!(nav.result?.arrived || align.result?.arrived),
        distance: nav.result?.distance,
        phases: [
          { phase: "navigate_to", ok: nav.ok, arrived: nav.result?.arrived },
          { phase: "berth_align", ok: align.ok, arrived: align.result?.arrived },
        ],
      },
    };
  }

  await session.stopMotors({ timeoutMs: 12000 }).catch(() => {});
  const after = await sample(session);
  const d = dist(after, port.x, port.z);
  const arrived = !!(res?.result?.arrived || (d != null && d <= 6));
  console.log(
    JSON.stringify(
      {
        used,
        ok: res?.ok,
        arrived,
        distance: d ?? res?.result?.distance,
        phases: res?.result?.phases,
        pose: after && { x: after.x, z: after.z, yaw_deg: after.yaw_deg },
      },
      null,
      2,
    ),
  );
  return { arrived, distance: d, res };
}

async function main() {
  const alsoB = process.argv.includes("--also-b");
  const session = openSession({});
  console.log("Bridge:", session.describe());
  await ensureAlive(session);

  const results = {};
  if (alsoB) {
    results.b = await leg(session, B, "Port B");
    await sleep(2000);
  }
  results.a = await leg(session, A, "Port A (park)");

  const after = await sample(session);
  const dA = dist(after, A.x, A.z);
  const parked = dA != null && dA <= 6;
  console.log("\n=== summary ===", { alsoB, parked_at_a: parked, dist_to_a: dA, a_ok: results.a?.arrived });
  await session.stopMotors({ timeoutMs: 12000 }).catch(() => {});

  if (!parked || !results.a?.arrived) process.exit(1);
  if (alsoB && !results.b?.arrived) process.exit(1);
  console.log("PARKED AT PORT A");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
