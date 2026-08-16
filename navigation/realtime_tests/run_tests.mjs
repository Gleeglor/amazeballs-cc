/**
 * Real in-game boat tests via CC filesystem bridge.
 *
 * Prerequisites:
 *   1. Minecraft open, boat computer loaded, calibrated (/boat_control.json)
 *   2. On boat: updater (select test_agent.lua) then run `test_agent` or `boat` → testagent
 *   3. Host: cd navigation/realtime_tests && npm test
 *
 * Config (optional): copy bridge.example.json → bridge.json with world + computer_id
 */
import { resolveComputer, discoverComputers, defaultMinecraftRoot } from "./discover.mjs";
import { sendCommand, stopMotors, ping, readStatus } from "./bridge.mjs";

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

async function between(dir) {
  await stopMotors(dir, { timeoutMs: 10000 });
  await new Promise((r) => setTimeout(r, 250));
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes("--list") || args.includes("-l")) {
    const root = defaultMinecraftRoot();
    console.log("Minecraft root:", root);
    for (const c of discoverComputers(root)) {
      console.log(`  score=${c.score}  world=${JSON.stringify(c.world)}  id=${c.id}`);
      console.log(`           ${c.dir}`);
    }
    return;
  }

  let target;
  try {
    target = resolveComputer({});
  } catch (e) {
    console.error(String(e.message || e));
    process.exit(2);
  }

  console.log("Bridge target:");
  console.log(`  world=${JSON.stringify(target.world)}  computer_id=${target.id}  (${target.source})`);
  console.log(`  ${target.dir}`);

  const status = readStatus(target.dir);
  if (!status?.alive) {
    console.warn(
      "\nWARNING: realtime_status.json not alive. Start test_agent on the boat computer first.\n",
    );
  } else {
    console.log(`  agent alive (last_cmd=${status.last_cmd || "?"})`);
  }

  console.log("\n=== ping ===");
  try {
    const p = await ping(target.dir);
    ok("ping", p.ok === true, `computer_id=${p.result?.computer_id}`);
  } catch (e) {
    ok("ping", false, String(e.message || e));
    console.error("\nCannot reach agent — aborting remaining tests.");
    process.exit(1);
  }

  console.log("\n=== load_control ===");
  await between(target.dir);
  const loaded = await sendCommand(target.dir, { cmd: "load_control" }, { timeoutMs: 10000 });
  ok("load_control", loaded.ok === true, loaded.ok ? `v${loaded.result?.version} yaw_sign=${loaded.result?.yaw_sign} n=${loaded.result?.n_thrusters}` : loaded.error);
  if (!loaded.ok) {
    console.error("Need /boat_control.json on the boat (run calibrate).");
    process.exit(1);
  }

  console.log("\n=== idle stop ===");
  await between(target.dir);
  const idle = await sendCommand(target.dir, { cmd: "apply", fx: 0, fy: 0, tz: 0 });
  const idleDuties = idle.result?.duties || [];
  const idleMax = Math.max(0, ...idleDuties.map((d) => Math.abs(d || 0)));
  ok("idle_zero_duties", idle.ok && idleMax < 0.08, `maxDuty=${idleMax}`);

  console.log("\n=== W surge (hold 1.0s) ===");
  await between(target.dir);
  const w = await sendCommand(
    target.dir,
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
  await between(target.dir);
  // Settle after W
  await new Promise((r) => setTimeout(r, 800));
  const a = await sendCommand(
    target.dir,
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
  // Pilot A = craft-left. Minecraft ω·up is often CW+; report Δyaw sign for diagnosis.
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
  await between(target.dir);
  await new Promise((r) => setTimeout(r, 800));
  const d = await sendCommand(
    target.dir,
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
  await between(target.dir);
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
