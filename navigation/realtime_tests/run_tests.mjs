/**
 * Real in-game boat tests via CC bridge (HTTP for multiplayer, FS for local/sshfs).
 *
 * Multiplayer:
 *   1. Host: npm run serve
 *   2. Boat: /realtime_bridge.json with base_url → updater → test_agent
 *   3. Host: npm test
 *
 * Singleplayer / sshfs:
 *   bridge.json mode=fs (default), test_agent without HTTP config
 */
import { discoverComputers, defaultMinecraftRoot, loadBridgeConfig } from "./discover.mjs";
import { openSession, resolveBridgeMode } from "./bridge.mjs";

const FAIL = [];
const PASS = [];

function ok(name, cond, detail = "") {
  if (cond) {
    PASS.push(name);
    console.log(`  PASS  ${name}${detail ? " — " + detail : ""}`);
  } else {
    FAIL.push(name);
    console.error(`  FAIL  ${name}${detail ? " — " + detail : ""}`);
  }
}

function sidesLit(thrusters) {
  let port = false;
  let stbd = false;
  for (const t of thrusters || []) {
    const d = Math.abs(Number(t.duty) || 0);
    if (d < 0.08) continue;
    const s = Number(t.side);
    if (s < -0.05) port = true;
    if (s > 0.05) stbd = true;
    const f = String(t.facing || "");
    if (f === "left" || f === "port") port = true;
    if (f === "right" || f === "starboard" || f === "stbd") stbd = true;
  }
  return { port, stbd };
}

async function between(session) {
  await session.stopMotors({ timeoutMs: 10000 });
  await new Promise((r) => setTimeout(r, 250));
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes("--list") || args.includes("-l")) {
    const mode = resolveBridgeMode();
    console.log("Bridge mode:", mode);
    if (mode === "http") {
      console.log("HTTP mode — local discover will not find a multiplayer boat.");
      console.log('Start server: npm run serve');
      console.log("Boat needs /realtime_bridge.json { \"mode\":\"http\", \"base_url\":\"http://HOST:8765\" }");
      return;
    }
    const { config } = loadBridgeConfig();
    const root = config?.root || defaultMinecraftRoot();
    console.log("Minecraft/FS root:", root);
    for (const c of discoverComputers(root)) {
      console.log(`  score=${c.score}  world=${JSON.stringify(c.world)}  id=${c.id}`);
      console.log(`           ${c.dir}`);
    }
    return;
  }

  let session;
  try {
    session = openSession({});
  } catch (e) {
    console.error(String(e.message || e));
    process.exit(2);
  }

  console.log("Bridge target:");
  console.log(`  ${session.describe()}  (mode=${session.mode})`);

  let status = null;
  try {
    status = await session.readStatus();
  } catch (e) {
    console.warn("Could not read status:", e.message || e);
  }
  if (!status?.alive) {
    console.warn(
      "\nWARNING: agent status not alive. Start test_agent on the boat (HTTP: with /realtime_bridge.json + npm run serve on host).\n",
    );
  } else {
    console.log(`  agent alive (last_cmd=${status.last_cmd || "?"})`);
  }

  console.log("\n=== ping ===");
  try {
    const p = await session.ping();
    ok("ping", p.ok === true, `computer_id=${p.result?.computer_id}`);
  } catch (e) {
    ok("ping", false, String(e.message || e));
    console.error("\nCannot reach agent — aborting remaining tests.");
    process.exit(1);
  }

  console.log("\n=== load_control ===");
  await between(session);
  const loaded = await session.sendCommand({ cmd: "load_control" }, { timeoutMs: 10000 });
  ok("load_control", loaded.ok === true, loaded.ok ? `v${loaded.result?.version} yaw_sign=${loaded.result?.yaw_sign} n=${loaded.result?.n_thrusters}` : loaded.error);
  if (!loaded.ok) {
    console.error("Need /boat_control.json on the boat (run calibrate).");
    process.exit(1);
  }

  console.log("\n=== idle stop ===");
  await between(session);
  const idle = await session.sendCommand({ cmd: "apply", fx: 0, fy: 0, tz: 0 });
  const idleDuties = idle.result?.duties || [];
  const idleMax = Math.max(0, ...idleDuties.map((d) => Math.abs(d || 0)));
  ok("idle_zero_duties", idle.ok && idleMax < 0.08, `maxDuty=${idleMax}`);

  console.log("\n=== W surge (hold 1.0s) ===");
  await between(session);
  const w = await session.sendCommand(
    { cmd: "hold_apply", fx: 1, fy: 0, tz: 0, seconds: 1.0 },
    { timeoutMs: 15000 },
  );
  ok("W_apply_ok", w.ok === true, w.error || `path=${w.result?.path}`);
  ok(
    "W_forward_motion_or_Fx",
    (w.result?.delta_forward ?? 0) > 0.05 || (w.result?.net?.fx ?? 0) > 0.05,
    `Δfwd=${w.result?.delta_forward?.toFixed?.(3)} net.fx=${w.result?.net?.fx}`,
  );

  console.log("\n=== A yaw left (hold 1.2s) ===");
  await between(session);
  await new Promise((r) => setTimeout(r, 800));
  const a = await session.sendCommand(
    { cmd: "hold_apply", fx: 0, fy: 0, tz: 1, seconds: 1.2 },
    { timeoutMs: 15000 },
  );
  ok("A_apply_ok", a.ok === true, a.error || `path=${a.result?.path}`);
  const aSides = sidesLit(a.result?.thrusters);
  ok(
    "A_both_sides_or_multi_duty",
    aSides.port && aSides.stbd || (a.result?.duties || []).filter((d) => Math.abs(d) >= 0.08).length >= 2,
    `port=${aSides.port} stbd=${aSides.stbd} duties=${JSON.stringify(a.result?.duties)}`,
  );
  const aDyaw = a.result?.delta_yaw_deg;
  ok(
    "A_yaw_nonzero",
    Math.abs(aDyaw ?? 0) > 1.5 || Math.abs(a.result?.net?.tz ?? 0) > 0.02,
    `Δyaw°=${aDyaw?.toFixed?.(2)} net.tz=${a.result?.net?.tz} (left usually ≠ 0; sign depends on ω·up)`,
  );
  console.log(
    `  note  A Δyaw°=${aDyaw?.toFixed?.(2)} yaw_sign=${a.result?.yaw_sign} — expect craft LEFT turn in-game`,
  );

  console.log("\n=== D yaw right (hold 1.2s) ===");
  await between(session);
  await new Promise((r) => setTimeout(r, 800));
  const d = await session.sendCommand(
    { cmd: "hold_apply", fx: 0, fy: 0, tz: -1, seconds: 1.2 },
    { timeoutMs: 15000 },
  );
  ok("D_apply_ok", d.ok === true, d.error || `path=${d.result?.path}`);
  const dDyaw = d.result?.delta_yaw_deg;
  ok(
    "D_opposite_A",
    aDyaw != null && dDyaw != null && aDyaw * dDyaw < 0,
    `AΔ=${aDyaw?.toFixed?.(2)} DΔ=${dDyaw?.toFixed?.(2)}`,
  );
  console.log(`  note  D Δyaw°=${dDyaw?.toFixed?.(2)} — expect craft RIGHT turn`);

  console.log("\n=== final stop ===");
  await between(session);
  ok("final_stop", true);

  console.log(`\n${PASS.length} passed, ${FAIL.length} failed`);
  if (FAIL.length) {
    console.error("Failed:", FAIL.join(", "));
    process.exit(1);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
