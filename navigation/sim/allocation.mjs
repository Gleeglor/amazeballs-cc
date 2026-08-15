/**
 * Pure port of Amazeballs CC teleop / Reassembly allocation from drive.lua.
 * Returns duties only — no peripherals, motors, or I/O.
 *
 * Source of truth: navigation/lib/drive.lua (applyTeleop, applyReassembly,
 * thrusterSide, healYawThrusters).
 *
 * Sim default / primary path for “like Reassembly” is applyReassembly
 * (weighted LS wrench solve over facing×strength geometric wrenches when
 * thrusters declare facing / max_force). applyTeleop is the fallback mixer.
 */

const DUTY_DEADBAND = 0.08;

export const FACING_DIRS = {
  forward: { x: 1, y: 0, z: 0 },
  back: { x: -1, y: 0, z: 0 },
  left: { x: 0, y: -1, z: 0 },
  right: { x: 0, y: 1, z: 0 },
};

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v));
}

/** Map facing / role string → unit thrust direction in body frame. */
export function facingToDir(facing) {
  if (facing == null) return null;
  const key = String(facing).toLowerCase();
  if (FACING_DIRS[key]) return { ...FACING_DIRS[key] };
  if (key === "port") return { ...FACING_DIRS.left };
  if (key === "starboard" || key === "stbd") return { ...FACING_DIRS.right };
  if (key === "aft" || key === "reverse") return { ...FACING_DIRS.back };
  if (key === "surge" || key === "main") return { ...FACING_DIRS.forward };
  return null;
}

/** Dominant cardinal from fx/fy (for calib JSON without facing). */
export function classifyFacingFromWrench(t) {
  const fx = Number(t.fx) || 0;
  const fy = Number(t.fy) || 0;
  const af = Math.abs(fx);
  const ar = Math.abs(fy);
  const m = Math.max(af, ar);
  if (m < 1e-6) return "mixed";
  if (af >= ar && af >= m * 0.55) return fx >= 0 ? "forward" : "back";
  if (ar >= af && ar >= m * 0.55) return fy >= 0 ? "right" : "left";
  return "mixed";
}

/**
 * Geometric wrench at duty=1: F = strength × facing, τ = r × F.
 * Mutates thruster; sets fx/fy/fz/tx/ty/tz used by applyReassembly.
 */
export function syncWrenchFromFacing(t) {
  if (!t || typeof t !== "object") return t;
  let facing = t.facing || t.role;
  if (!facing || facing === "mixed") {
    facing = classifyFacingFromWrench(t);
    if (facing !== "mixed") t.facing = facing;
  }
  const dir = facingToDir(facing);
  if (!dir) return t;

  const strength =
    Number(t.max_force) ||
    Number(t.strength) ||
    Math.max(Math.abs(t.fx || 0), Math.abs(t.fy || 0), 0.5);
  t.max_force = strength;
  t.facing = facing;
  if (!t.role || t.role === "mixed") t.role = facing;
  t.dirX = dir.x;
  t.dirY = dir.y;
  t.dirZ = dir.z;
  t.angleRad = Math.atan2(dir.y, dir.x);

  t.fx = strength * dir.x;
  t.fy = strength * dir.y;
  t.fz = strength * dir.z;
  const lx = Number(t.lx) || 0;
  const ly = Number(t.ly) || 0;
  const lz = Number(t.lz) || 0;
  t.tx = ly * t.fz - lz * t.fy;
  t.ty = lz * t.fx - lx * t.fz;
  t.tz = lx * t.fy - ly * t.fx;
  t.mag = Math.hypot(t.fx, t.fy, t.tz);

  if (facing === "left") t.side_score = -1;
  else if (facing === "right") t.side_score = 1;
  else if (t.side_score == null) t.side_score = Math.sign(ly) || 0;

  return t;
}

/**
 * Prefer geometric wrenches when max_force/strength is present (explicit size model).
 * Facing/role alone is a label — do not overwrite calibrated fx/fy/tz.
 */
export function enrichThruster(t, opts = {}) {
  if (!t || typeof t !== "object") return t;
  if (!t.facing && t.role) t.facing = t.role;
  if (
    !t.facing &&
    (Math.abs(t.fx || 0) > 1e-6 || Math.abs(t.fy || 0) > 1e-6)
  ) {
    t.facing = classifyFacingFromWrench(t);
  }
  if (!t.role && t.facing) t.role = t.facing;

  const wantGeom =
    opts.forceGeometric ||
    t.max_force != null ||
    t.strength != null ||
    t.sync_geometry === true;
  if (wantGeom && facingToDir(t.facing || t.role)) {
    return syncWrenchFromFacing(t);
  }

  t.mag =
    t.mag ||
    Math.sqrt((t.fx || 0) ** 2 + (t.fy || 0) ** 2 + (t.tz || 0) ** 2);
  return t;
}

export function enrichControl(control, opts = {}) {
  if (!control || !Array.isArray(control.thrusters)) return control;
  for (const t of control.thrusters) enrichThruster(t, opts);
  return control;
}

export function isWrenchMode(control) {
  return Boolean(
    control &&
      (control.mode === "wrench" || (control.version || 0) >= 2) &&
      Array.isArray(control.thrusters) &&
      control.thrusters.length > 0,
  );
}

/** Physical side score: +starboard / -port (from calib, not name order). */
export function thrusterSide(t) {
  if (!t || typeof t !== "object") return 0;
  if (t.side_score != null) return Number(t.side_score) || 0;
  const fy = Number(t.fy) || 0;
  if (Math.abs(fy) >= 0.02) return fy;
  const lever = t.lever_est != null ? Number(t.lever_est) : null;
  if (lever != null && Math.abs(lever) >= 0.05) return lever;
  const fx = Number(t.fx) || 0;
  const tz = Number(t.tz) || 0;
  if (Math.abs(fx) >= 0.02 && Math.abs(tz) >= 0.004) return -tz / fx;
  if (Math.abs(tz) >= 0.008) return tz;
  return 0;
}

/**
 * Side-aware yaw levers when calib tz is too weak.
 * Mutates thrusters in place (same as Lua). Returns whether any were healed.
 */
export function healYawThrusters(control) {
  if (!control || !Array.isArray(control.thrusters)) return false;
  let maxTz = 0;
  let maxFx = 0;
  let maxFy = 0;
  for (const t of control.thrusters) {
    maxTz = Math.max(maxTz, Math.abs(t.tz || 0));
    maxFx = Math.max(maxFx, Math.abs(t.fx || 0));
    maxFy = Math.max(maxFy, Math.abs(t.fy || 0));
  }
  if (maxTz >= 0.02 && maxTz >= Math.max(maxFx, maxFy) * 0.12) return false;

  const ranked = control.thrusters.map((t, i) => ({
    i,
    s: thrusterSide(t),
    t,
  }));
  ranked.sort((a, b) => (a.s === b.s ? a.i - b.i : a.s - b.s));
  const n = ranked.length;
  if (n < 2) return false;

  const base = Math.max(0.25, maxFx, maxFy * 0.5, maxTz);
  let healed = 0;
  ranked.forEach((row, idx) => {
    const t = row.t;
    if (
      t.kind === "motor" ||
      Math.abs(t.fx || 0) > 0.01 ||
      Math.abs(t.fy || 0) > 0.01
    ) {
      let sign = idx <= n / 2 ? -1 : 1;
      if (row.s !== 0) sign = row.s < 0 ? -1 : 1;
      t.tz = sign * base * 0.5;
      t.side_score = sign;
      t.mag = Math.sqrt(
        (t.fx || 0) ** 2 + (t.fy || 0) ** 2 + (t.tz || 0) ** 2,
      );
      healed += 1;
    }
  });
  return healed > 0;
}

function zeroDuties(n) {
  return Array.from({ length: n }, () => 0);
}

function buildSides(thrusters) {
  const n = thrusters.length;
  const sides = thrusters.map((t) => thrusterSide(t));
  let anySide = false;
  for (let i = 0; i < n; i++) {
    if (Math.abs(sides[i]) > 1e-6) {
      anySide = true;
      break;
    }
  }
  if (!anySide) {
    const ranked = Array.from({ length: n }, (_, i) => i);
    ranked.sort((a, b) =>
      String(thrusters[a].name).localeCompare(String(thrusters[b].name)),
    );
    ranked.forEach((i, idx) => {
      sides[i] = idx <= n / 2 ? -1 : 1;
    });
  }
  return sides;
}

/**
 * Teleop mixer — same command vector and scoring as drive.applyTeleop.
 * @returns {{ ok: boolean, duties: number[], branch: string, useEqual?: boolean, useCalibTz?: boolean }}
 */
export function applyTeleop(control, fx = 0, fy = 0, tz = 0) {
  if (!isWrenchMode(control)) {
    return { ok: false, duties: [], branch: "not_wrench" };
  }
  enrichControl(control);
  const thrusters = control.thrusters;
  const n = thrusters.length;
  const cmdMag = Math.sqrt(fx * fx + fy * fy + tz * tz);
  if (cmdMag < 1e-4) {
    return { ok: true, duties: zeroDuties(n), branch: "idle" };
  }

  const sides = buildSides(thrusters);
  let maxFx = 0;
  let maxFy = 0;
  let maxTz = 0;
  for (const t of thrusters) {
    maxFx = Math.max(maxFx, Math.abs(t.fx || 0));
    maxFy = Math.max(maxFy, Math.abs(t.fy || 0));
    maxTz = Math.max(maxTz, Math.abs(t.tz || 0));
  }

  const scores = new Array(n).fill(0);
  const pureSurge = Math.abs(fx) >= 0.5 && Math.abs(fy) + Math.abs(tz) < 0.25;
  const pureYaw = Math.abs(tz) >= 0.5 && Math.abs(fx) + Math.abs(fy) < 0.25;
  const pureStrafe = Math.abs(fy) >= 0.5 && Math.abs(fx) + Math.abs(tz) < 0.25;

  let branch = "chord";
  let useEqual;
  let useCalibTz;

  if (pureSurge) {
    branch = "pure_surge";
    useEqual = maxFx < Math.max(0.04, maxFy * 0.35, maxTz * 0.35);
    for (let i = 0; i < n; i++) {
      scores[i] = useEqual ? fx : fx * (thrusters[i].fx || 0);
    }
  } else if (pureYaw) {
    branch = "pure_yaw";
    useCalibTz = maxTz >= 0.02 && maxTz >= Math.max(maxFx, maxFy) * 0.1;
    for (let i = 0; i < n; i++) {
      if (useCalibTz) {
        scores[i] = tz * (thrusters[i].tz || 0);
      } else {
        let s = sides[i];
        if (Math.abs(s) < 1e-6) s = 1;
        scores[i] = tz * (s >= 0 ? 1 : -1);
      }
    }
  } else if (pureStrafe) {
    branch = "pure_strafe";
    useEqual = maxFy < 0.04;
    for (let i = 0; i < n; i++) {
      if (useEqual) {
        scores[i] = fy * (sides[i] >= 0 ? 1 : -1);
      } else {
        scores[i] = fy * (thrusters[i].fy || 0);
      }
    }
  } else {
    branch = "chord";
    for (let i = 0; i < n; i++) {
      const t = thrusters[i];
      let yawLever = t.tz || 0;
      if (Math.abs(yawLever) < 0.02) {
        const s = sides[i];
        yawLever =
          (s >= 0 ? 1 : -1) *
          Math.max(0.25, Math.abs(t.fx || 0), Math.abs(t.fy || 0));
      }
      scores[i] = fx * (t.fx || 0) + fy * (t.fy || 0) + tz * yawLever;
    }
  }

  let maxAbs = 0;
  for (let i = 0; i < n; i++) maxAbs = Math.max(maxAbs, Math.abs(scores[i] || 0));

  if (maxAbs < 1e-8) {
    if (Math.abs(fx) >= Math.abs(fy) && Math.abs(fx) >= Math.abs(tz)) {
      for (let i = 0; i < n; i++) scores[i] = fx;
      branch = "fallback_equal_surge";
    } else {
      for (let i = 0; i < n; i++) {
        scores[i] = (tz !== 0 ? tz : fy) * (sides[i] >= 0 ? 1 : -1);
      }
      branch = "fallback_side_diff";
    }
    maxAbs = 0;
    for (let i = 0; i < n; i++) maxAbs = Math.max(maxAbs, Math.abs(scores[i] || 0));
  }

  if (maxAbs < 1e-8) {
    return { ok: false, duties: zeroDuties(n), branch: "zero_scores" };
  }

  const scale = Math.min(1, cmdMag);
  const duties = new Array(n);
  for (let i = 0; i < n; i++) {
    let duty = ((scores[i] || 0) / maxAbs) * scale;
    if (Math.abs(duty) < DUTY_DEADBAND) duty = 0;
    const reversible = thrusters[i].kind === "motor";
    duties[i] = reversible ? clamp(duty, -1, 1) : clamp(duty, 0, 1);
  }

  return { ok: true, duties, branch, useEqual, useCalibTz, sides, scores };
}

/** Invert 3×3 * vector (Gaussian elimination). */
function solve3x3(A, b) {
  const m = [
    [A[0][0], A[0][1], A[0][2], b[0]],
    [A[1][0], A[1][1], A[1][2], b[1]],
    [A[2][0], A[2][1], A[2][2], b[2]],
  ];
  for (let col = 0; col < 3; col++) {
    let pivot = col;
    for (let r = col + 1; r < 3; r++) {
      if (Math.abs(m[r][col]) > Math.abs(m[pivot][col])) pivot = r;
    }
    if (Math.abs(m[pivot][col]) < 1e-12) return null;
    if (pivot !== col) {
      const tmp = m[col];
      m[col] = m[pivot];
      m[pivot] = tmp;
    }
    const div = m[col][col];
    for (let c = col; c < 4; c++) m[col][c] /= div;
    for (let r = 0; r < 3; r++) {
      if (r === col) continue;
      const f = m[r][col];
      for (let c = col; c < 4; c++) m[r][c] -= f * m[col][c];
    }
  }
  return [m[0][3], m[1][3], m[2][3]];
}

/**
 * Reassembly-style least-squares allocation (drive.applyReassembly core).
 * Falls back is left to the caller / applyWrench — here we return null duties on singular.
 */
export function applyReassembly(control, fx = 0, fy = 0, tz = 0) {
  if (!isWrenchMode(control)) {
    return { ok: false, duties: [], branch: "not_wrench" };
  }
  enrichControl(control);
  const thrusters = control.thrusters;
  const n = thrusters.length;
  const cmdMag = Math.sqrt(fx * fx + fy * fy + tz * tz);
  if (cmdMag < 1e-4) {
    return { ok: true, duties: zeroDuties(n), branch: "idle" };
  }

  let gain = (control.gains && control.gains.norm) || 1;
  if (gain < 1e-6) gain = 1;

  // Cost weights match drive.applyReassembly (Lua). Sqrt applied as sw below.
  let axW = [1.0, 1.0, 1.0];
  let dutyDeadband = 0.08;
  if (Math.abs(fy) >= 0.5 && Math.abs(fx) + Math.abs(tz) < 0.25) {
    // Strafe: kill CoM yaw couple
    axW = [2.8, 1.0, 6.0];
    dutyDeadband = 0.1;
  } else if (Math.abs(fx) >= 0.5 && Math.abs(fy) + Math.abs(tz) < 0.25) {
    // Surge: null yaw hard so path-follow doesn't spin
    axW = [1.0, 2.2, 5.0];
    dutyDeadband = 0.1;
  } else if (Math.abs(tz) >= 0.5 && Math.abs(fx) + Math.abs(fy) < 0.25) {
    // Yaw: allow translation residual (near-CoM thrusters always couple)
    axW = [0.8, 0.8, 1.0];
    dutyDeadband = 0.06;
  }
  const sw = [Math.sqrt(axW[0]), Math.sqrt(axW[1]), Math.sqrt(axW[2])];

  function dutiesFor(scale) {
    const Fd = [
      (fx / cmdMag) * gain * scale * sw[0],
      (fy / cmdMag) * gain * scale * sw[1],
      (tz / cmdMag) * gain * scale * sw[2],
    ];
    const G = [
      [1e-8, 0, 0],
      [0, 1e-8, 0],
      [0, 0, 1e-8],
    ];
    for (const t of thrusters) {
      const w1 = (t.fx || 0) * sw[0];
      const w2 = (t.fy || 0) * sw[1];
      const w3 = (t.tz || 0) * sw[2];
      G[0][0] += w1 * w1;
      G[0][1] += w1 * w2;
      G[0][2] += w1 * w3;
      G[1][0] += w2 * w1;
      G[1][1] += w2 * w2;
      G[1][2] += w2 * w3;
      G[2][0] += w3 * w1;
      G[2][1] += w3 * w2;
      G[2][2] += w3 * w3;
    }
    const lambda = solve3x3(G, Fd);
    if (!lambda) return null;
    const u = [];
    let maxAbs = 0;
    for (let i = 0; i < n; i++) {
      const t = thrusters[i];
      const wi1 = (t.fx || 0) * sw[0];
      const wi2 = (t.fy || 0) * sw[1];
      const wi3 = (t.tz || 0) * sw[2];
      let ui = wi1 * lambda[0] + wi2 * lambda[1] + wi3 * lambda[2];
      if (t.kind !== "motor") ui = Math.max(0, ui);
      u[i] = ui;
      maxAbs = Math.max(maxAbs, Math.abs(ui));
    }
    return { u, maxAbs };
  }

  let pack = dutiesFor(1.0);
  if (!pack) {
    return { ok: false, duties: zeroDuties(n), branch: "singular" };
  }
  if (pack.maxAbs > 1) {
    const pack2 = dutiesFor(1.0 / pack.maxAbs);
    if (pack2) pack = pack2;
  }

  const duties = pack.u.map((ui, i) => {
    const reversible = thrusters[i].kind === "motor";
    let duty = clamp(ui, reversible ? -1 : 0, 1);
    if (Math.abs(duty) < dutyDeadband) duty = 0;
    return duty;
  });

  return { ok: true, duties, branch: "reassembly", axW, dutyDeadband };
}

/** Map held keys → same {fx,fy,tz} as drive.manualLoop commandFromKeys. */
export function commandFromKeys(held) {
  const fx = (held.w ? 1 : 0) + (held.s ? -1 : 0);
  const fy = (held.c ? 1 : 0) + (held.z ? -1 : 0);
  const tz = (held.a ? 1 : 0) - (held.d ? 1 : 0);
  return { fx, fy, tz };
}

export function dutyToRpm(duty, maxRpm = 24, rpmSign = 1) {
  let d = clamp(Number(duty) || 0, -1, 1);
  if (Math.abs(d) < DUTY_DEADBAND) d = 0;
  let rpm = d * maxRpm * rpmSign;
  if (Math.abs(rpm) < 2) rpm = 0;
  return Math.round(rpm);
}
