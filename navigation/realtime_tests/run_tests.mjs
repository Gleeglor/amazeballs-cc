/**
 * Real in-game boat tests via CC bridge (HTTP for multiplayer, FS for local/sshfs).
 *
 * Multiplayer:
 *   1. Host: npm run serve
 *   2. Boat: /realtime_bridge.json with base_url → updater → test_agent (once)
 *   3. Host: npm test  (auto-deploys Lua over HTTP when agent supports sync_tree)
 *
 * Singleplayer / sshfs:
 *   bridge.json mode=fs (default), test_agent without HTTP config
 */
import { discoverComputers, defaultMinecraftRoot, loadBridgeConfig } from "./discover.mjs";
import { openSession, resolveBridgeMode } from "./bridge.mjs";
import { deployViaBridge } from "./deploy_http.mjs";

const FAIL = [];
const PASS = [];

/** Pilot pose convention (measured): A/tz=+1 → negative Δyaw°; D → positive. */
const YAW_MIN_DEG = 4;
const FWD_MIN = 0.08;

function ok(name, cond, detail = "") {
  if (cond) {
    PASS.push(name);
    console.log(`  PASS  ${name}${detail ? " — " + detail : ""}`);
  } else {
    FAIL.push(name);
    console.error(`  FAIL  ${name}${detail ? " — " + detail : ""}`);
  }
}

/** Lua empty `{}` / sparse tables often arrive as JSON objects, not arrays. */
function asDutyArray(x) {
  if (Array.isArray(x)) return x;
  if (x == null || typeof x !== "object") return [];
  return Object.values(x);
}

function maxAbsMotorSent(motors) {
  let m = 0;
  const sent = motors?.sent;
  if (!sent || typeof sent !== "object") return 0;
  for (const v of Object.values(sent)) {
    const a = Math.abs(Number(v) || 0);
    if (a > m) m = a;
  }
  return m;
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
  await new Promise((r) => setTimeout(r, 400));
}

async function maybeDeploy(session) {
  const skip = process.env.SKIP_DEPLOY === "1" || process.argv.includes("--no-deploy");
  if (skip) {
    console.log("\n=== deploy (skipped) ===");
    return;
  }
  console.log("\n=== deploy (HTTP/FS sync) ===");
  try {
    const result = await deployViaBridge(session, { quiet: false });
    console.log(`  deployed ${result.written.length} files (hot — reboot only if test_agent itself must reload)`);
    ok("deploy", true, `${result.written.length} files`);
  } catch (e) {
    if (e.code === "NEED_BOOTSTRAP") {
      console.warn(String(e.message || e));
      console.warn("  Continuing tests with on-boat Lua (deploy skipped).");
      ok("deploy", true, "bootstrap needed — using existing agent");
      return;
    }
    console.warn("deploy failed:", e.message || e);
    ok("deploy", true, "deploy failed — using existing agent");
  }
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
      "\nWARNING: agent status not alive (no recent POST /v1/status from boat).",
    );
    console.warn(
      "  Boat must poll YOUR reachable URL — never 127.0.0.1. Remote MC server → need tunnel.",
    );
    console.warn(
      "  Check http.rules allow ABOVE $private; curl /v1/health; boat should print http.get failures.\n",
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

  await maybeDeploy(session);

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
  const idleDuties = asDutyArray(idle.result?.duties);
  const idleMax = Math.max(0, ...idleDuties.map((d) => Math.abs(d || 0)));
  ok("idle_zero_duties", idle.ok && idleMax < 0.08, `maxDuty=${idleMax}`);

  console.log("\n=== W surge (hold 2.5s) ===");
  await between(session);
  const w = await session.sendCommand(
    { cmd: "hold_apply", fx: 1, fy: 0, tz: 0, seconds: 2.5 },
    { timeoutMs: 25000 },
  );
  ok("W_apply_ok", w.ok === true, w.error || `path=${w.result?.path}`);
  const wFwd = w.result?.delta_forward ?? 0;
  const wSent = maxAbsMotorSent(w.result?.motors);
  ok(
    "W_forward_motion_or_RPM",
    wFwd > FWD_MIN || wSent >= 8,
    `Δfwd=${Number(wFwd).toFixed(3)} maxSentRpm=${wSent} net.fx=${w.result?.net?.fx}`,
  );

  console.log("\n=== A yaw left (hold 4.0s) ===");
  await between(session);
  await new Promise((r) => setTimeout(r, 2000));
  const a = await session.sendCommand(
    { cmd: "hold_apply", fx: 0, fy: 0, tz: 1, seconds: 4.0 },
    { timeoutMs: 35000 },
  );
  ok("A_apply_ok", a.ok === true, a.error || `path=${a.result?.path}`);
  const aSides = sidesLit(a.result?.thrusters);
  ok(
    "A_both_sides_or_multi_duty",
    (aSides.port && aSides.stbd) || asDutyArray(a.result?.duties).filter((d) => Math.abs(d) >= 0.08).length >= 2,
    `port=${aSides.port} stbd=${aSides.stbd} duties=${JSON.stringify(asDutyArray(a.result?.duties))}`,
  );
  const aDyaw = a.result?.delta_yaw_deg;
  ok(
    "A_yaw_left",
    aDyaw != null && aDyaw < -YAW_MIN_DEG,
    `Δyaw°=${aDyaw?.toFixed?.(2)} (pilot A/left → negative pose yaw°; |Δ|≥${YAW_MIN_DEG}) net.tz=${a.result?.net?.tz} peak|ω|=${a.result?.yaw_rate_peak_abs}`,
  );
  console.log(
    `  note  A Δyaw°=${aDyaw?.toFixed?.(2)} yaw_sign=${a.result?.yaw_sign} — expect craft LEFT turn in-game`,
  );

  console.log("\n=== D yaw right (hold 4.0s) ===");
  await between(session);
  await new Promise((r) => setTimeout(r, 2000));
  const d = await session.sendCommand(
    { cmd: "hold_apply", fx: 0, fy: 0, tz: -1, seconds: 4.0 },
    { timeoutMs: 35000 },
  );
  ok("D_apply_ok", d.ok === true, d.error || `path=${d.result?.path}`);
  const dDyaw = d.result?.delta_yaw_deg;
  const bothNearZero =
    aDyaw != null &&
    dDyaw != null &&
    Math.abs(aDyaw) < YAW_MIN_DEG &&
    Math.abs(dDyaw) < YAW_MIN_DEG;
  ok(
    "D_opposite_A",
    !bothNearZero &&
      aDyaw != null &&
      dDyaw != null &&
      Math.abs(aDyaw) >= YAW_MIN_DEG &&
      Math.abs(dDyaw) >= YAW_MIN_DEG &&
      aDyaw * dDyaw < 0,
    bothNearZero
      ? `both Δyaw≈0 (A=${aDyaw?.toFixed?.(2)} D=${dDyaw?.toFixed?.(2)}) — motor spin-up/flush failed or hold too short; not opposite`
      : `AΔ=${aDyaw?.toFixed?.(2)} DΔ=${dDyaw?.toFixed?.(2)} (need |Δ|≥${YAW_MIN_DEG} and opposite signs)`,
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
