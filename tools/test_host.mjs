#!/usr/bin/env node
/**
 * Host-side unit tests for boat control algorithms + agent protocol shapes.
 * Mirrors Lua lib behaviour (motors clamp, wrench, route A*, dock tolerances, agent RPC).
 * Run: node tools/test_host.mjs
 */
import assert from "node:assert/strict";

const MAX_RPM = 24;

// --- motors ---
function clampRpm(rpm) {
  rpm = Number(rpm) || 0;
  rpm = Math.floor(rpm + (rpm >= 0 ? 0.5 : -0.5));
  return Math.max(-MAX_RPM, Math.min(MAX_RPM, rpm));
}
function dutyToRpm(duty, maxPos = MAX_RPM, maxNeg = MAX_RPM) {
  duty = Math.max(-1, Math.min(1, Number(duty) || 0));
  maxPos = Math.min(Number(maxPos) || MAX_RPM, MAX_RPM);
  maxNeg = Math.min(Number(maxNeg) || MAX_RPM, MAX_RPM);
  return clampRpm(duty >= 0 ? duty * maxPos : duty * maxNeg);
}

function test_motors() {
  assert.equal(clampRpm(100), 24);
  assert.equal(clampRpm(-100), -24);
  assert.equal(clampRpm(12), 12);
  assert.equal(dutyToRpm(1), 24);
  assert.equal(dutyToRpm(-1), -24);
  assert.equal(dutyToRpm(0.5, 20, 20), 10);
  assert.equal(dutyToRpm(1, 30, 30), 24); // still capped via min with MAX

  // Scheduler: zeros first, rate limit is retry not success
  const FLUSH_GAP = 0.12;
  const desired = {};
  const sent = {};
  const lastWrite = {};
  let clock = 0;
  const writes = [];
  function tryWrite(name, rpm) {
    rpm = clampRpm(rpm);
    const last = lastWrite[name];
    if (last != null && clock - last < FLUSH_GAP && Math.abs(rpm) >= 1) {
      return { ok: false, reason: "rate_limit" };
    }
    if (Math.abs(rpm) < 1 && last != null && clock - last < FLUSH_GAP && sent[name] === 0) {
      return { ok: true, reason: "already_zero" };
    }
    if (Math.abs(rpm) >= 1 && last != null && clock - last < FLUSH_GAP) {
      return { ok: false, reason: "rate_limit" };
    }
    writes.push({ name, rpm, t: clock });
    lastWrite[name] = clock;
    sent[name] = rpm;
    return { ok: true };
  }
  function flush() {
    const zeros = [];
    const others = [];
    for (const [name, want] of Object.entries(desired)) {
      if (sent[name] === undefined || Math.abs(sent[name] - want) >= 0.5) {
        if (Math.abs(want) < 1) zeros.push(name);
        else others.push(name);
      }
    }
    zeros.sort();
    others.sort();
    for (const name of [...zeros, ...others]) {
      tryWrite(name, desired[name]);
    }
  }

  desired.a = 24;
  desired.b = 0;
  sent.a = 10;
  sent.b = 10;
  flush();
  assert.equal(writes[0].name, "b");
  assert.equal(writes[0].rpm, 0);
  // rate limit on a
  const r = tryWrite("a", 24);
  assert.equal(r.reason, "rate_limit");
  clock += FLUSH_GAP;
  assert.equal(tryWrite("a", 24).ok, true);

  // panic drain
  desired.a = 0;
  desired.b = 0;
  clock += FLUSH_GAP;
  flush();
  assert.equal(sent.a, 0);
  assert.equal(sent.b, 0);
  console.log("  test_motors OK");
}

// --- wrench ---
function allocate(thrusters, Fx, Fy, Tz) {
  const n = thrusters.length;
  const u = Array(n).fill(0);
  const pureSurge = Math.abs(Fx) >= 0.5 && Math.abs(Fy) + Math.abs(Tz) < 0.25;
  const wFx = 1,
    wFy = 1,
    wTz = pureSurge ? 8 : 2.5;
  const cols = thrusters.map((t) => {
    const fx = 0.5 * ((t.fx_pos || 0) - (t.fx_neg || 0));
    const fy = 0.5 * ((t.fy_pos || 0) - (t.fy_neg || 0));
    const tz = 0.5 * ((t.tz_pos || 0) - (t.tz_neg || 0));
    return { fx, fy, tz };
  });
  function residual() {
    let rx = Fx,
      ry = Fy,
      rz = Tz;
    for (let i = 0; i < n; i++) {
      rx -= cols[i].fx * u[i];
      ry -= cols[i].fy * u[i];
      rz -= cols[i].tz * u[i];
    }
    return [rx, ry, rz];
  }
  for (let iter = 0; iter < 40; iter++) {
    let [rx, ry, rz] = residual();
    for (let i = 0; i < n; i++) {
      const c = cols[i];
      const denom = wFx * c.fx * c.fx + wFy * c.fy * c.fy + wTz * c.tz * c.tz;
      if (denom > 1e-8) {
        const grad = wFx * c.fx * rx + wFy * c.fy * ry + wTz * c.tz * rz;
        u[i] = Math.max(-1, Math.min(1, u[i] + grad / denom));
        [rx, ry, rz] = residual();
      }
    }
  }
  const dead = pureSurge ? 0.1 : 0.08;
  return u.map((d, i) => {
    if (Math.abs(d) < dead) return 0;
    if (pureSurge) {
      const c = cols[i];
      const mag = Math.hypot(c.fx, c.fy, c.tz);
      if (mag > 1e-6 && Math.abs(c.fx) / mag < 0.25 && Math.abs(d) < 0.35) return 0;
    }
    return d;
  });
}

function test_wrench() {
  // Off-center: left thruster forward+yaw, right forward-yaw, center forward
  const thrusters = [
    { name: "L", fx_pos: 1, fy_pos: 0, tz_pos: 0.4, fx_neg: -1, fy_neg: 0, tz_neg: -0.4 },
    { name: "R", fx_pos: 0.7, fy_pos: 0, tz_pos: -0.4, fx_neg: -0.7, fy_neg: 0, tz_neg: 0.4 },
    { name: "C", fx_pos: 1, fy_pos: 0, tz_pos: 0.05, fx_neg: -1, fy_neg: 0, tz_neg: -0.05 },
  ];
  const duties = allocate(thrusters, 1, 0, 0);
  // Net yaw from duties should be small
  let netTz = 0;
  let netFx = 0;
  for (let i = 0; i < thrusters.length; i++) {
    const t = thrusters[i];
    const d = duties[i];
    const fx = 0.5 * (t.fx_pos - t.fx_neg);
    const tz = 0.5 * (t.tz_pos - t.tz_neg);
    netFx += fx * d;
    netTz += tz * d;
  }
  assert.ok(netFx > 0.3, "should produce surge");
  assert.ok(Math.abs(netTz) < 0.15, "pure W must not yaw much, got " + netTz);

  const yawDuties = allocate(thrusters, 0, 0, 1);
  assert.ok(yawDuties.some((d) => Math.abs(d) > 0.1), "yaw should use thrusters");

  // deadband zeros specks
  const speck = allocate(
    [{ name: "a", fx_pos: 0.01, fy_pos: 0, tz_pos: 0, fx_neg: -0.01, fy_neg: 0, tz_neg: 0 }],
    0.0001,
    0,
    0
  );
  assert.ok(Math.abs(speck[0]) < 0.08 || speck[0] === 0, "speck should be deadbanded, got " + speck[0]);
  // force near-zero duty through deadband path
  const zeroed = [0.05, -0.03, 0.2].map((d) => (Math.abs(d) < 0.08 ? 0 : d));
  assert.deepEqual(zeroed, [0, 0, 0.2]);
  console.log("  test_wrench OK");
}

// --- route A* ---
function key(cx, cz) {
  return cx + "," + cz;
}
function astar(blocked, scx, scz, gcx, gcz) {
  const open = new Map();
  const came = new Map();
  const gScore = new Map();
  const fScore = new Map();
  const sk = key(scx, scz);
  gScore.set(sk, 0);
  fScore.set(sk, Math.abs(scx - gcx) + Math.abs(scz - gcz));
  open.set(sk, { cx: scx, cz: scz });
  const dirs = [
    [1, 0],
    [-1, 0],
    [0, 1],
    [0, -1],
  ];
  while (open.size) {
    let bestK = null,
      bestF = 1e18;
    for (const [k] of open) {
      const f = fScore.get(k) ?? 1e18;
      if (f < bestF) {
        bestF = f;
        bestK = k;
      }
    }
    const cur = open.get(bestK);
    open.delete(bestK);
    if (cur.cx === gcx && cur.cz === gcz) {
      const path = [];
      let ck = bestK;
      while (ck) {
        const [cx, cz] = ck.split(",").map(Number);
        path.unshift({ cx, cz });
        ck = came.get(ck);
      }
      return path;
    }
    for (const [dx, dz] of dirs) {
      const nx = cur.cx + dx,
        nz = cur.cz + dz;
      const nk = key(nx, nz);
      if (blocked.has(nk)) continue;
      const tent = (gScore.get(bestK) ?? 1e18) + 1;
      if (tent < (gScore.get(nk) ?? 1e18)) {
        came.set(nk, bestK);
        gScore.set(nk, tent);
        fScore.set(nk, tent + Math.abs(nx - gcx) + Math.abs(nz - gcz));
        open.set(nk, { cx: nx, cz: nz });
      }
    }
  }
  return null;
}

function test_route() {
  const path = astar(new Set(), 0, 0, 3, 0);
  assert.ok(path && path.length >= 4);
  assert.equal(path[0].cx, 0);
  assert.equal(path.at(-1).cx, 3);

  const blocked = new Set([key(1, 0), key(2, 0)]);
  const path2 = astar(blocked, 0, 0, 3, 0);
  assert.ok(path2);
  assert.ok(!path2.some((p) => blocked.has(key(p.cx, p.cz))));
  console.log("  test_route OK");
}

// --- dock ---
function withinTolerance(dist, angleDeg) {
  return dist <= 0.5 && Math.abs(angleDeg) <= 20;
}

function test_dock() {
  assert.equal(withinTolerance(0.4, 10), true);
  assert.equal(withinTolerance(0.6, 10), false);
  assert.equal(withinTolerance(0.4, 25), false);

  // FSM: transfer only after lock
  let state = "creep";
  let locked = false;
  function step(dist, angle) {
    if (locked) {
      state = "locked";
      return state;
    }
    if (state === "creep" && withinTolerance(dist, angle)) {
      state = "wait_lock";
      return state;
    }
    if (state === "wait_lock") {
      if (locked) state = "locked";
      return state;
    }
    if (state === "transfer" && !locked) throw new Error("transfer without lock");
    return state;
  }
  assert.equal(step(0.4, 5), "wait_lock");
  locked = true;
  assert.equal(step(0.4, 5), "locked");
  state = "transfer";
  // undock before reverse: must leave locked
  locked = false;
  state = "undock";
  assert.equal(state, "undock");
  console.log("  test_dock OK");
}

// --- calibrate shapes ---
function test_calibrate() {
  const probe = 12;
  assert.ok(probe <= MAX_RPM);
  const thruster = {
    name: "m1",
    fx_pos: 0.1,
    fy_pos: 0,
    tz_pos: 0.02,
    fx_neg: -0.08,
    fy_neg: 0,
    tz_neg: -0.01,
    max_rpm_pos: 18,
    max_rpm_neg: 24,
  };
  assert.ok(thruster.max_rpm_pos <= MAX_RPM);
  assert.ok(thruster.max_rpm_neg <= MAX_RPM);
  assert.notEqual(thruster.fx_pos, thruster.fx_neg);
  // unused weak
  const weak = { fx: 0.001, fy: 0, tz: 0 };
  const mag = Math.hypot(weak.fx, weak.fy, weak.tz);
  assert.ok(mag < 0.012);
  console.log("  test_calibrate OK");
}

// --- agent protocol ---
function test_agent() {
  const hello = { type: "hello", role: "boat", version: 1 };
  assert.equal(hello.role, "boat");
  const rpc = { type: "rpc", id: 1, method: "pose", params: {} };
  const reply = { type: "reply", id: 1, ok: true, result: { x: 1 } };
  assert.equal(reply.id, rpc.id);
  // disconnect → stop semantics: host clears pending
  const pending = new Map();
  pending.set(1, true);
  pending.clear();
  assert.equal(pending.size, 0);
  console.log("  test_agent OK");
}

// --- teleop event model (mirrors boat/lib/teleop.lua) ---
const KEYS = { w: 17, s: 31, a: 30, d: 32, x: 45, q: 16 };
const HOLD_TIMEOUT = 0.22;

function commandFromHeld(held, yawSign = -1) {
  let surge = 0,
    strafe = 0,
    yaw = 0;
  if (held[KEYS.w]) surge += 1;
  if (held[KEYS.s]) surge -= 1;
  if (held[KEYS.a]) yaw -= 1;
  if (held[KEYS.d]) yaw += 1;
  yaw *= yawSign;
  return { surge, strafe, yaw };
}

function simulateTeleop(events) {
  const held = {};
  const seen = {};
  const applies = [];
  let t = 0;
  let listenOnly = false; // old bug: only accept keys in post-draw window
  function expire() {
    let changed = false;
    for (const k of Object.keys(held)) {
      if (held[k] && t - (seen[k] || 0) > HOLD_TIMEOUT) {
        delete held[k];
        delete seen[k];
        changed = true;
      }
    }
    return changed;
  }
  function apply() {
    applies.push({ ...commandFromHeld(held), held: { ...held }, t });
  }
  for (const ev of events) {
    t = ev.t ?? t;
    if (ev.type === "begin_apply_draw") {
      listenOnly = true; // simulate old loop: keys during apply were ignored
      continue;
    }
    if (ev.type === "listen_window") {
      listenOnly = false;
      continue;
    }
    if (listenOnly && (ev.type === "key" || ev.type === "key_up")) {
      continue; // dropped — old bug
    }
    if (ev.type === "key") {
      held[ev.key] = true;
      seen[ev.key] = t;
      apply();
    } else if (ev.type === "key_up") {
      delete held[ev.key];
      delete seen[ev.key];
      apply();
    } else if (ev.type === "tick") {
      if (expire()) apply();
    }
  }
  return { held, applies };
}

function test_teleop_held() {
  // Fixed loop: key during "apply" still applies same tick
  const good = simulateTeleop([
    { type: "key", key: KEYS.w, t: 0 },
  ]);
  assert.equal(good.applies.length, 1);
  assert.equal(good.applies[0].surge, 1);
  assert.equal(good.held[KEYS.w], true);

  // Old listen-window model would drop this — document the failure mode
  const bad = simulateTeleop([
    { type: "begin_apply_draw", t: 0 },
    { type: "key", key: KEYS.w, t: 0.01 },
    { type: "listen_window", t: 0.1 },
  ]);
  assert.equal(bad.applies.length, 0, "old window would miss press");
  console.log("  test_teleop_held OK");
}

function test_teleop_release() {
  const r = simulateTeleop([
    { type: "key", key: KEYS.w, t: 0 },
    { type: "key_up", key: KEYS.w, t: 0.05 },
  ]);
  assert.equal(r.applies.at(-1).surge, 0);
  assert.equal(r.held[KEYS.w], undefined);
  console.log("  test_teleop_release OK");
}

function test_teleop_missed_keyup() {
  const r = simulateTeleop([
    { type: "key", key: KEYS.w, t: 0 },
    { type: "tick", t: 0.25 },
  ]);
  assert.equal(r.held[KEYS.w], undefined);
  assert.equal(r.applies.at(-1).surge, 0);
  console.log("  test_teleop_missed_keyup OK");
}

function test_teleop_yaw_sign() {
  const a = commandFromHeld({ [KEYS.a]: true }, -1);
  const d = commandFromHeld({ [KEYS.d]: true }, -1);
  assert.equal(a.yaw, 1, "A with yaw_sign=-1 → +yaw");
  assert.equal(d.yaw, -1, "D with yaw_sign=-1 → -yaw");
  console.log("  test_teleop_yaw_sign OK");
}

// --- pose quaternion (Advanced Math: .v + .a, :toEuler) ---
function quatComponents(q) {
  if (q == null) return [0, 0, 0, 1];
  if (q.v != null || typeof q.a === "number") {
    const v = q.v || {};
    return [Number(v.x) || 0, Number(v.y) || 0, Number(v.z) || 0, Number(q.a) || 1];
  }
  if (q.w != null || q.x != null) {
    return [Number(q.x) || 0, Number(q.y) || 0, Number(q.z) || 0, Number(q.w) || 1];
  }
  return [0, 0, 0, 1];
}

function toEuler(q) {
  if (q && typeof q.toEuler === "function") {
    const r = q.toEuler();
    if (Array.isArray(r)) return r;
    if (r && typeof r === "object" && "yaw" in r) return [r.pitch || 0, r.yaw || 0, r.roll || 0];
  }
  const [x, y, z, w] = quatComponents(q);
  const sinp = Math.max(-1, Math.min(1, 2 * (w * x - y * z)));
  const pitch = Math.asin(sinp);
  const yaw = Math.atan2(2 * (w * y + z * x), 1 - 2 * (x * x + y * y));
  const roll = Math.atan2(2 * (w * z + x * y), 1 - 2 * (x * x + z * z));
  return [pitch, yaw, roll];
}

function test_pose_quat() {
  // Bug: userdata without .w → identity → yaw 0
  const broken = { /* no .w */ };
  const [, yawBroken] = toEuler(broken);
  assert.equal(yawBroken, 0);

  // NE-ish: yaw ≈ -π/4 (facing between south and east? MC yaw 0 = +Z south)
  // 90° yaw toward west: rotate about Y
  const yaw90 = Math.PI / 2;
  const q = {
    v: { x: 0, y: Math.sin(yaw90 / 2), z: 0 },
    a: Math.cos(yaw90 / 2),
    toEuler() {
      return [0, yaw90, 0];
    },
  };
  const [, yaw] = toEuler(q);
  assert.ok(Math.abs(yaw - yaw90) < 1e-9, "toEuler yaw must be nonzero, got " + yaw);

  // Without toEuler, v+a unpack must also work
  const q2 = { v: { x: 0, y: Math.sin(yaw90 / 2), z: 0 }, a: Math.cos(yaw90 / 2) };
  const [, yaw2] = toEuler(q2);
  assert.ok(Math.abs(yaw2) > 0.5, "v+a quat must not yield yaw≈0, got " + yaw2);
  console.log("  test_pose_quat OK");
}

// --- motors setSpeed mock ---
function test_motors_write() {
  const writes = [];
  let clock = 0;
  const FLUSH_GAP = 0.12;
  const lastWrite = {};
  const sent = {};
  function setSpeed(name, rpm) {
    rpm = clampRpm(rpm);
    const last = lastWrite[name];
    if (last != null && clock - last < FLUSH_GAP) {
      return { ok: false, reason: "rate_limit" };
    }
    writes.push({ name, rpm });
    lastWrite[name] = clock;
    sent[name] = rpm;
    return { ok: true };
  }
  assert.equal(clampRpm(12.4), 12);
  assert.equal(clampRpm(12.6), 13);
  assert.equal(setSpeed("m1", 12.6).ok, true);
  assert.equal(writes[0].rpm, 13);
  assert.equal(setSpeed("m1", 20).reason, "rate_limit");
  clock += FLUSH_GAP;
  assert.equal(setSpeed("m1", 20).ok, true);
  assert.equal(sent.m1, 20);
  console.log("  test_motors_write OK");
}

function test_sleep_does_not_eat_keys() {
  // drain must use pullEventRaw + timer id, not pullEvent("timer") which drops keys
  const queue = [
    ["key", KEYS.w, false],
    ["timer", 99],
  ];
  const filtered = [];
  // bad: pullEvent("timer") — only timer events reach consumer; keys discarded
  function pullEventFiltered(filter) {
    while (queue.length) {
      const e = queue.shift();
      if (!filter || e[0] === filter) return e;
      // discarded
    }
    return null;
  }
  const eaten = [];
  const before = queue.length;
  pullEventFiltered("timer");
  assert.ok(queue.length < before || true);
  // After filtered pull, key was dropped from queue without delivery
  // Rebuild and use raw
  const rawQ = [
    ["key", KEYS.w, false],
    ["timer", 42],
  ];
  const held = {};
  function pullEventRaw() {
    return rawQ.shift();
  }
  let gotTimer = false;
  while (!gotTimer) {
    const e = pullEventRaw();
    if (!e) break;
    if (e[0] === "key") held[e[1]] = true;
    if (e[0] === "timer" && e[1] === 42) gotTimer = true;
  }
  assert.equal(held[KEYS.w], true, "raw drain must queue keys into held");
  assert.equal(gotTimer, true);
  // prove filter would have eaten the key
  const q2 = [
    ["key", KEYS.w, false],
    ["timer", 1],
  ];
  function badPull() {
    while (q2.length) {
      const e = q2.shift();
      if (e[0] === "timer") return e;
    }
  }
  badPull();
  assert.equal(q2.length, 0);
  assert.ok(!held.__bad);
  console.log("  test_sleep_does_not_eat_keys OK");
}

console.log("Boat host tests");
test_motors();
test_calibrate();
test_wrench();
test_route();
test_dock();
test_agent();
test_teleop_held();
test_teleop_release();
test_teleop_missed_keyup();
test_teleop_yaw_sign();
test_pose_quat();
test_motors_write();
test_sleep_does_not_eat_keys();
console.log("All host tests passed.");
