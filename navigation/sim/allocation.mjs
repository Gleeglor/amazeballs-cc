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

/**
 * Sign convention (body frame, top-down):
 *   +fx = surge forward (W)
 *   +fy = strafe starboard (C)
 *   +tz = yaw CCW = craft-left turn (A / port)
 *   −tz = yaw CW = craft-right turn (D / starboard)
 *
 * boat_control.yaw_sign (default +1) multiplies the commanded tz once in
 * applyCommand / compensate so a single flip fixes inverted A/D in-game.
 */

export const FACING_DIRS = {
  forward: { x: 1, y: 0, z: 0 },
  back: { x: -1, y: 0, z: 0 },
  left: { x: 0, y: -1, z: 0 },
  right: { x: 0, y: 1, z: 0 },
};

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v));
}

/** CoM from boat_control.json / sim params (body frame, hull origin). */
export function getCom(control, opts = {}) {
  const c = control || {};
  return {
    x: Number(opts.comX ?? c.comX ?? c.com_x) || 0,
    y: Number(opts.comY ?? c.comY ?? c.com_y) || 0,
    z: Number(opts.comZ ?? c.comZ ?? c.com_z) || 0,
  };
}

export function getYawSign(control) {
  const s = Number(control && control.yaw_sign);
  return Number.isFinite(s) && s !== 0 ? Math.sign(s) : 1;
}

/** Net body wrench from duties × thruster fx/fy/tz (allocation units). */
export function netWrench(thrusters, duties) {
  let Fx = 0;
  let Fy = 0;
  let Tz = 0;
  for (let i = 0; i < thrusters.length; i++) {
    const d = duties[i] || 0;
    if (Math.abs(d) < 1e-12) continue;
    const t = thrusters[i];
    Fx += d * (t.fx || 0);
    Fy += d * (t.fy || 0);
    Tz += d * (t.tz || 0);
  }
  return { Fx, Fy, Tz };
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
 * Geometric wrench at duty=1: F = strength × facing, τ = (r − r_com) × F.
 * Mutates thruster; sets fx/fy/fz/tx/ty/tz used by applyReassembly.
 * If no lever arm is set (lx=ly=lz≈0), keep any measured tz (Lua calib path).
 * @param {object} t thruster
 * @param {{x?:number,y?:number,z?:number}|object} [comOrControl] CoM or full control
 */
export function syncWrenchFromFacing(t, comOrControl = null) {
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

  const prevTz = Number(t.tz) || 0;
  t.fx = strength * dir.x;
  t.fy = strength * dir.y;
  t.fz = strength * dir.z;
  const lx = Number(t.lx) || 0;
  const ly = Number(t.ly) || 0;
  const lz = Number(t.lz) || 0;
  const hasLever = Math.hypot(lx, ly, lz) >= 1e-4;
  const com =
    comOrControl &&
    (Array.isArray(comOrControl.thrusters) ||
      comOrControl.com_x != null ||
      comOrControl.comX != null ||
      comOrControl.com_y != null ||
      comOrControl.comY != null ||
      comOrControl.com_z != null ||
      comOrControl.comZ != null)
      ? getCom(comOrControl)
      : {
          x: Number(comOrControl?.x ?? comOrControl?.comX) || 0,
          y: Number(comOrControl?.y ?? comOrControl?.comY) || 0,
          z: Number(comOrControl?.z ?? comOrControl?.comZ) || 0,
        };
  const rx = lx - com.x;
  const ry = ly - com.y;
  const rz = lz - com.z;
  t.tx = ry * t.fz - rz * t.fy;
  t.ty = rz * t.fx - rx * t.fz;
  // Preserve calib tz when positions were never measured (in-game JSON).
  t.tz = hasLever ? rx * t.fy - ry * t.fx : prevTz;
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
    return syncWrenchFromFacing(t, opts.com || opts.control || null);
  }

  // Recompute τ about CoM when levers exist and CoM is offset (keep calib tz at origin).
  const lx = Number(t.lx) || 0;
  const ly = Number(t.ly) || 0;
  const lz = Number(t.lz) || 0;
  if (Math.hypot(lx, ly, lz) >= 1e-4 && (opts.com || opts.control)) {
    const com = opts.com || getCom(opts.control);
    if (Math.hypot(com.x, com.y, com.z) >= 1e-4) {
      const rx = lx - com.x;
      const ry = ly - com.y;
      const rz = lz - com.z;
      const fx = Number(t.fx) || 0;
      const fy = Number(t.fy) || 0;
      const fz = Number(t.fz) || 0;
      t.tx = ry * fz - rz * fy;
      t.ty = rz * fx - rx * fz;
      t.tz = rx * fy - ry * fx;
    }
  }

  t.mag =
    t.mag ||
    Math.sqrt((t.fx || 0) ** 2 + (t.fy || 0) ** 2 + (t.tz || 0) ** 2);
  return t;
}

export function enrichControl(control, opts = {}) {
  if (!control || !Array.isArray(control.thrusters)) return control;
  const com = opts.com || getCom(control, opts);
  for (const t of control.thrusters) {
    enrichThruster(t, { ...opts, com, control });
  }
  return control;
}

function isPureSurge(fx, fy, tz) {
  return Math.abs(fx) >= 0.5 && Math.abs(fy) + Math.abs(tz) < 0.25;
}
function isPureStrafe(fx, fy, tz) {
  return Math.abs(fy) >= 0.5 && Math.abs(fx) + Math.abs(tz) < 0.25;
}
function isPureYaw(fx, fy, tz) {
  return Math.abs(tz) >= 0.5 && Math.abs(fx) + Math.abs(fy) < 0.25;
}

/**
 * Iterative yaw cancel for pure surge/strafe: allocate, measure residual Tz,
 * nudge tz command opposite the couple. Reverse flips naturally with duties.
 */
export function allocateWithComCancel(allocFn, control, fx, fy, tz, opts = {}) {
  enrichControl(control, opts);
  const enabled =
    opts.compensate !== false && control && control.com_compensate !== false;
  const yawSign = opts.yawSign != null ? opts.yawSign : getYawSign(control);
  const pilotTz = tz * yawSign;

  const pure =
    isPureSurge(fx, fy, pilotTz) || isPureStrafe(fx, fy, pilotTz);
  if (!enabled || !pure) {
    const r = allocFn(control, fx, fy, pilotTz);
    return {
      ...r,
      cmd: { fx, fy, tz: pilotTz },
      yawSign,
      compensated: false,
      residualTz: 0,
    };
  }

  const maxIter = Math.max(1, Number(opts.cancelIters ?? control.com_cancel_iters) || 6);
  const gain = Number(opts.cancelGain ?? control.com_cancel_gain) || 0.65;
  const ratioLim = Number(opts.cancelRatioLimit) || 0.04;
  const absLim = Number(opts.cancelAbsLimit) || 0.02;

  let tzCmd = pilotTz;
  let r = allocFn(control, fx, fy, tzCmd);
  const initialBranch = r.branch;
  let residualTz = 0;
  let compensated = false;
  const intentBranch = isPureSurge(fx, fy, pilotTz)
    ? "pure_surge"
    : isPureStrafe(fx, fy, pilotTz)
      ? "pure_strafe"
      : null;

  for (let i = 0; i < maxIter; i++) {
    if (!r.ok || !dutiesAlive(r.duties, 0.04)) break;
    const w = netWrench(control.thrusters, r.duties);
    residualTz = w.Tz;
    const primary = Math.max(Math.abs(w.Fx), Math.abs(w.Fy), 1e-3);
    const ratio = residualTz / primary;
    if (Math.abs(ratio) < ratioLim && Math.abs(residualTz) < absLim) break;
    tzCmd = clamp(tzCmd - ratio * gain, -0.75, 0.75);
    compensated = true;
    r = allocFn(control, fx, fy, tzCmd);
  }

  if (r.ok && dutiesAlive(r.duties, 0.04) && intentBranch) {
    const before = netWrench(control.thrusters, r.duties).Tz;
    const polished = nullResidualYaw(control.thrusters, r.duties, {
      cmdFx: fx,
      cmdFy: fy,
      minPrimaryFraction: 0.55,
      targetRatio: 0.035,
      targetAbs: 0.012,
      steps: 20,
    });
    r = { ...r, duties: polished };
    residualTz = netWrench(control.thrusters, r.duties).Tz;
    if (Math.abs(residualTz) + 1e-9 < Math.abs(before)) compensated = true;
  } else if (r.ok && dutiesAlive(r.duties, 0.04)) {
    residualTz = netWrench(control.thrusters, r.duties).Tz;
  }

  // Keep the first-pass allocator label (pure_surge / reassembly / …) even when
  // command-space cancel injected a small tz that would look like a "chord".
  const branch =
    intentBranch &&
    (initialBranch === "pure_surge" ||
      initialBranch === "pure_strafe" ||
      initialBranch === "reassembly" ||
      initialBranch === "cardinal_roles")
      ? initialBranch
      : r.branch;

  return {
    ...r,
    branch,
    cmd: { fx, fy, tz: tzCmd },
    yawSign,
    compensated,
    residualTz,
  };
}

/** @deprecated open-loop shim — prefer allocateWithComCancel */
export function compensateComCommand(control, fx = 0, fy = 0, tz = 0, opts = {}) {
  const r = allocateWithComCancel(
    (c, x, y, z) => applyReassembly(c, x, y, z),
    control,
    fx,
    fy,
    tz,
    opts,
  );
  return {
    fx,
    fy,
    tz: r.cmd.tz,
    compensated: r.compensated,
    biasTz: r.residualTz,
  };
}

export function prepareCommand(control, fx = 0, fy = 0, tz = 0, opts = {}) {
  const yawSign = opts.yawSign != null ? opts.yawSign : getYawSign(control);
  return {
    fx,
    fy,
    tz: tz * yawSign,
    yawSign,
    compensated: false,
    biasTz: 0,
  };
}

/** Yaw authority for mixers: prefer geometric/calib tz sign (fixes A-invert on fwd thrusters). */
export function yawAuthority(t, sideFallback = 0) {
  const tz = Number(t && t.tz) || 0;
  if (Math.abs(tz) >= 0.015) return Math.sign(tz);
  const side = sideFallback || thrusterSide(t);
  if (Math.abs(side) < 1e-6) return 0;
  const facing = String((t && (t.facing || t.role)) || "").toLowerCase();
  // τz = −ly·fx: forward thruster on +starboard → negative tz → authority −side
  if (facing === "forward" || facing === "surge" || facing === "main") {
    return -Math.sign(side);
  }
  // back: fx negative at +duty → tz shares side sign
  if (facing === "back" || facing === "aft" || facing === "reverse") {
    return Math.sign(side);
  }
  // left/right facing: bow port (fy<0, lx>0) → tz < 0 → matches side (−)
  return Math.sign(side);
}

export function isWrenchMode(control) {
  return Boolean(
    control &&
      (control.mode === "wrench" || (control.version || 0) >= 2) &&
      Array.isArray(control.thrusters) &&
      control.thrusters.length > 0,
  );
}

/** Physical side score: +starboard / -port (facing first, like drive.lua). */
export function thrusterSide(t) {
  if (!t || typeof t !== "object") return 0;
  const facing = String(t.facing || t.role || "").toLowerCase();
  if (facing === "left" || facing === "port") return -1;
  if (facing === "right" || facing === "starboard" || facing === "stbd") return 1;
  if (t.side_score != null) return Number(t.side_score) || 0;
  const ly = Number(t.ly) || 0;
  if (Math.abs(ly) >= 0.05) return Math.sign(ly);
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

function dutiesAlive(duties, eps = DUTY_DEADBAND) {
  return Array.isArray(duties) && duties.some((d) => Math.abs(d || 0) >= eps);
}

/**
 * Nudge duties to kill residual Tz without a full LS solve.
 * Never drives the commanded primary (Fx for surge / Fy for strafe) below
 * minPrimaryFraction of the pre-null baseline — yaw cancel must not kill surge.
 *
 * Targets are tight: prior 0.12 / 0.06 stopped cancel while planar physics still
 * yawed ~10–15° over 2s on asymmetric / weird fixtures.
 */
export function nullResidualYaw(thrusters, duties, opts = {}) {
  const out = duties.map((d) => d || 0);
  const maxSteps = Math.max(1, Number(opts.steps) || 20);
  const targetRatio = Number(opts.targetRatio) || 0.035;
  const targetAbs = Number(opts.targetAbs) || 0.012;
  const minFrac = Number(opts.minPrimaryFraction) || 0.55;
  const cmdFx = Number(opts.cmdFx);
  const cmdFy = Number(opts.cmdFy);
  const baseline = netWrench(thrusters, out);
  const surgeIntent =
    (Number.isFinite(cmdFx) && Math.abs(cmdFx) >= 0.5 && Math.abs(cmdFy || 0) < 0.25) ||
    (Math.abs(baseline.Fx) >= Math.abs(baseline.Fy) && Math.abs(baseline.Fx) >= 0.05);
  const primaryOf = (w) => (surgeIntent ? w.Fx : w.Fy);
  const basePrimary = primaryOf(baseline);
  const minPrimary =
    Math.abs(basePrimary) < 1e-6
      ? 0
      : Math.sign(basePrimary) * Math.abs(basePrimary) * minFrac;
  // Allow modest lateral for cancel — pure W with offset CoM needs L/R nudge,
  // but keep it below the Fy ratio tests (~0.22·Fx).
  const lateralCap =
    Math.max(Math.abs(basePrimary) * 0.2, 0.1) +
    Math.abs(surgeIntent ? baseline.Fy : baseline.Fx) * 0.5;

  const facingOf = (t) => String(t.facing || t.role || "").toLowerCase();
  const isYawHelper = (t) => {
    const f = facingOf(t);
    return (
      f === "left" ||
      f === "right" ||
      f === "port" ||
      f === "starboard" ||
      f === "stbd"
    );
  };

  for (let step = 0; step < maxSteps; step++) {
    const w = netWrench(thrusters, out);
    const primary = Math.max(Math.abs(primaryOf(w)), 1e-3);
    if (Math.abs(w.Tz) < targetAbs && Math.abs(w.Tz) / primary < targetRatio) {
      break;
    }
    // Score all thrusters; bias yaw-helpers but never skip surge thrusters that
    // cancel Tz with little/no lateral (common on asymmetric stern pairs).
    let bestI = -1;
    let bestScore = -1e9;
    let bestDelta = 0;
    for (let i = 0; i < thrusters.length; i++) {
      const t = thrusters[i];
      const tz = Number(t.tz) || 0;
      if (Math.abs(tz) < 0.008) continue;
      const reversible = t.kind === "motor";
      let delta = (-w.Tz / tz) * 0.85;
      let next = clamp(out[i] + delta, reversible ? -1 : 0, 1);
      delta = next - out[i];
      if (Math.abs(delta) < 1e-4) continue;

      const trial = out.slice();
      trial[i] = next;
      let tw = netWrench(thrusters, trial);
      const trialPrimary = primaryOf(tw);
      if (Math.abs(basePrimary) >= 1e-4) {
        if (Math.sign(trialPrimary) !== Math.sign(basePrimary) && Math.abs(trialPrimary) > 1e-4) {
          continue;
        }
        if (Math.abs(trialPrimary) + 1e-9 < Math.abs(minPrimary)) {
          const p0 = primaryOf(w);
          const dP = trialPrimary - p0;
          if (Math.abs(dP) < 1e-9) continue;
          const need = minPrimary - p0;
          const scale = clamp(need / dP, 0, 1);
          if (scale < 0.05) continue;
          delta *= scale;
          next = clamp(out[i] + delta, reversible ? -1 : 0, 1);
          trial[i] = next;
          tw = netWrench(thrusters, trial);
          if (Math.abs(primaryOf(tw)) + 1e-9 < Math.abs(minPrimary)) continue;
        }
      }
      const lat = surgeIntent ? Math.abs(tw.Fy) : Math.abs(tw.Fx);
      // Tight lateral budget — cancel must not turn W into a strafe.
      if (lat > lateralCap + 0.04) continue;

      const latPerTz =
        Math.abs(surgeIntent ? t.fy || 0 : t.fx || 0) / Math.max(Math.abs(tz), 1e-3);
      const couple =
        Math.abs(tz) /
        (0.08 + Math.abs(t.fx || 0) * 0.25 + Math.abs(t.fy || 0) * 0.5);
      const tzDrop = Math.abs(w.Tz) - Math.abs(tw.Tz);
      if (tzDrop <= 1e-6) continue;
      const latBleed = surgeIntent ? Math.abs(tw.Fy) : Math.abs(tw.Fx);
      const latIncrease = Math.max(0, latBleed - Math.abs(surgeIntent ? w.Fy : w.Fx));
      const primaryKeep =
        Math.abs(primaryOf(tw)) / Math.max(Math.abs(basePrimary), 1e-3);
      const helperBias = isYawHelper(t) ? 0.35 : 0;
      // Prefer high Tz authority with low lateral; reward pure surge/aft cancels.
      const score =
        couple * 0.45 +
        Math.max(0, tzDrop) * 6 +
        helperBias -
        latBleed * 3.2 -
        latIncrease * 4 -
        latPerTz * 0.8 +
        primaryKeep * 0.4;
      if (score > bestScore) {
        bestScore = score;
        bestI = i;
        bestDelta = trial[i] - out[i];
      }
    }
    if (bestI < 0) break;
    const prev = out[bestI];
    out[bestI] = clamp(
      out[bestI] + bestDelta,
      thrusters[bestI].kind === "motor" ? -1 : 0,
      1,
    );
    if (Math.abs(out[bestI] - prev) < 1e-4) break;
  }

  // Deadband scrub: zero tiny duties only when it does not worsen |Tz| or
  // kill primary. Never boost sub-deadband cancel nudges back up to 0.08
  // (that previously re-introduced residual yaw).
  const beforeScrub = netWrench(thrusters, out);
  const scrubbed = out.slice();
  for (let i = 0; i < scrubbed.length; i++) {
    if (Math.abs(scrubbed[i]) < DUTY_DEADBAND) scrubbed[i] = 0;
  }
  const afterScrub = netWrench(thrusters, scrubbed);
  const primaryOk =
    Math.abs(basePrimary) < 0.1 ||
    Math.abs(primaryOf(afterScrub)) + 1e-9 >= Math.abs(minPrimary) ||
    Math.abs(primaryOf(beforeScrub)) < Math.abs(minPrimary) * 0.9;
  const tzOk = Math.abs(afterScrub.Tz) <= Math.abs(beforeScrub.Tz) + 0.003;
  if (primaryOk && tzOk) {
    for (let i = 0; i < out.length; i++) out[i] = scrubbed[i];
  }
  return out;
}

/**
 * Role/facing mixer for cardinal thrusters (no LS, no calib tz needed).
 * W: forward +duty, back −duty; A/D: physical yaw authority; Z/C: L/R facing.
 * Pass opts.skipCancel to allocate raw roles (used inside cancel loop).
 */
export function applyCardinalRoles(control, fx = 0, fy = 0, tz = 0, opts = {}) {
  if (!isWrenchMode(control)) {
    return { ok: false, duties: [], branch: "not_wrench" };
  }
  if (opts.skipCancel !== true && opts.compensate !== false) {
    const wrapped = allocateWithComCancel(
      (c, x, y, z) => applyCardinalRoles(c, x, y, z, { skipCancel: true }),
      control,
      fx,
      fy,
      tz,
      opts,
    );
    // Command-space cancel can oscillate on aft CoM; duty-space null finishes the job.
    if (
      wrapped.ok &&
      dutiesAlive(wrapped.duties) &&
      (isPureSurge(fx, fy, 0) || isPureStrafe(fx, fy, 0))
    ) {
      const duties = nullResidualYaw(control.thrusters, wrapped.duties, {
        cmdFx: fx,
        cmdFy: fy,
        minPrimaryFraction: 0.55,
        targetRatio: 0.035,
        targetAbs: 0.012,
        steps: 20,
      });
      const residualTz = netWrench(control.thrusters, duties).Tz;
      return {
        ...wrapped,
        duties,
        residualTz,
        branch: wrapped.branch || "cardinal_roles",
        compensated: true,
      };
    }
    return { ...wrapped, branch: wrapped.branch || "cardinal_roles" };
  }

  enrichControl(control, opts);
  const thrusters = control.thrusters;
  const n = thrusters.length;
  const cmdMag = Math.sqrt(fx * fx + fy * fy + tz * tz);
  if (cmdMag < 1e-4) {
    return { ok: true, duties: zeroDuties(n), branch: "idle" };
  }

  const scores = new Array(n).fill(0);
  let anyFacing = false;
  for (let i = 0; i < n; i++) {
    const t = thrusters[i];
    let facing = String(t.facing || t.role || "").toLowerCase();
    if (!facing || facing === "mixed") {
      facing = classifyFacingFromWrench(t);
    }
    if (facing && facing !== "mixed") anyFacing = true;
    const side = thrusterSide(t);
    const strength =
      Number(t.max_force) ||
      Number(t.strength) ||
      Math.max(Math.abs(t.fx || 0), Math.abs(t.fy || 0), 0.5);
    let surge = 0;
    let strafe = 0;
    if (facing === "forward" || facing === "surge" || facing === "main") surge = strength;
    else if (facing === "back" || facing === "aft" || facing === "reverse")
      surge = -strength;
    if (facing === "right" || facing === "starboard" || facing === "stbd")
      strafe = strength;
    else if (facing === "left" || facing === "port") strafe = -strength;
    // Prefer wrench tz sign so A (+tz) always drives +Tz (left / CCW).
    const yawAuth = yawAuthority(t, side);
    scores[i] = fx * surge + fy * strafe + tz * yawAuth * strength;
  }

  if (!anyFacing) {
    return { ok: false, duties: zeroDuties(n), branch: "no_facing" };
  }

  let maxAbs = 0;
  for (let i = 0; i < n; i++) maxAbs = Math.max(maxAbs, Math.abs(scores[i] || 0));
  if (maxAbs < 1e-8) {
    return { ok: false, duties: zeroDuties(n), branch: "zero_scores" };
  }

  const scale = Math.min(1, cmdMag);
  let duties = new Array(n);
  for (let i = 0; i < n; i++) {
    let duty = ((scores[i] || 0) / maxAbs) * scale;
    if (Math.abs(duty) < DUTY_DEADBAND) duty = 0;
    const reversible = thrusters[i].kind === "motor";
    duties[i] = reversible ? clamp(duty, -1, 1) : clamp(duty, 0, 1);
  }

  if (!dutiesAlive(duties)) {
    return { ok: false, duties, branch: "deadband" };
  }

  // Duty-space yaw null for pure surge/strafe (skipCancel path used by cancel loop).
  if (isPureSurge(fx, fy, tz) || isPureStrafe(fx, fy, tz)) {
    duties = nullResidualYaw(thrusters, duties, {
      cmdFx: fx,
      cmdFy: fy,
      minPrimaryFraction: 0.55,
      targetRatio: 0.035,
      targetAbs: 0.012,
      steps: 20,
    });
  }

  return { ok: true, duties, branch: "cardinal_roles", scores };
}

/**
 * Full applyCommand mirror: yaw_sign + CoM cancel, then
 * Reassembly → teleop → cardinal roles on dead duties.
 * Pure W/S: reject paths that deadband-zero or leave Fx≈0 when surge capacity exists.
 */
export function applyCommand(control, fx = 0, fy = 0, tz = 0, opts = {}) {
  const mode = (opts.allocMode || control.alloc_mode || control.teleop_mode || "")
    .toString()
    .toLowerCase();

  const run = (allocFn) =>
    allocateWithComCancel(allocFn, control, fx, fy, tz, {
      ...opts,
      // Inner allocators must not recurse cancel.
      skipCancel: undefined,
    });

  const preferReassembly =
    opts.preferReassembly !== false &&
    mode !== "teleop" &&
    mode !== "direct" &&
    mode !== "cardinal" &&
    mode !== "roles";

  const surgeOk = (r) => {
    if (!r || !r.ok) return false;
    if (r.branch === "idle") return true;
    if (!dutiesAlive(r.duties)) return false;
    if (!isPureSurge(fx, fy, tz)) return true;
    const w = netWrench(control.thrusters, r.duties);
    // Accept if Fx has the right sign and is meaningful, or no surge capacity.
    let cap = 0;
    for (const t of control.thrusters) cap += Math.abs(t.fx || 0);
    if (cap < 0.08) return Math.abs(w.Fx) > 1e-6 || dutiesAlive(r.duties);
    return Math.sign(w.Fx) === Math.sign(fx) && Math.abs(w.Fx) >= Math.min(0.2, cap * 0.25);
  };

  const polishSurge = (r) => {
    if (!r || !r.ok || !isPureSurge(fx, fy, tz)) return r;
    let duties = r.duties;
    const before = netWrench(control.thrusters, duties);
    if (Math.sign(before.Fx) !== Math.sign(fx) || Math.abs(before.Fx) < 0.35) {
      duties = ensureSurgeDuties(control.thrusters, duties, fx);
    }
    duties = nullResidualYaw(control.thrusters, duties, {
      cmdFx: fx,
      cmdFy: fy,
      minPrimaryFraction: 0.55,
      targetRatio: 0.035,
      targetAbs: 0.012,
      steps: 20,
    });
    let after = netWrench(control.thrusters, duties);
    if (Math.sign(after.Fx) !== Math.sign(fx) || Math.abs(after.Fx) < 0.35) {
      duties = ensureSurgeDuties(control.thrusters, duties, fx);
      duties = nullResidualYaw(control.thrusters, duties, {
        cmdFx: fx,
        cmdFy: fy,
        minPrimaryFraction: 0.6,
        targetRatio: 0.04,
        targetAbs: 0.015,
        steps: 16,
      });
      after = netWrench(control.thrusters, duties);
    }
    // Second pass: if yaw still material, allow slightly more primary trade.
    if (
      Math.abs(after.Tz) > Math.max(0.015, Math.abs(after.Fx) * 0.04) &&
      Math.abs(after.Fx) >= 0.4
    ) {
      duties = nullResidualYaw(control.thrusters, duties, {
        cmdFx: fx,
        cmdFy: fy,
        minPrimaryFraction: 0.5,
        targetRatio: 0.03,
        targetAbs: 0.01,
        steps: 24,
      });
    }
    return { ...r, duties };
  };

  if (mode === "cardinal" || mode === "roles") {
    let r = applyCardinalRoles(control, fx, fy, tz, opts);
    r = polishSurge(r);
    return { ...r, path: "cardinal" };
  }
  if (mode === "teleop" || mode === "direct") {
    let tele = run((c, x, y, z) => applyTeleop(c, x, y, z, { skipCancel: true }));
    tele = polishSurge(tele);
    if (surgeOk(tele)) return { ...tele, path: "teleop" };
    let roles = applyCardinalRoles(control, fx, fy, tz, opts);
    roles = polishSurge(roles);
    if (roles.ok) return { ...roles, path: "cardinal_fallback" };
    return { ...tele, path: "teleop" };
  }

  if (preferReassembly) {
    let reass = run((c, x, y, z) =>
      applyReassembly(c, x, y, z, { skipCancel: true }),
    );
    reass = polishSurge(reass);
    if (surgeOk(reass) || (reass.ok && reass.branch === "idle")) {
      return { ...reass, path: "reassembly" };
    }
    let tele = run((c, x, y, z) => applyTeleop(c, x, y, z, { skipCancel: true }));
    tele = polishSurge(tele);
    if (surgeOk(tele) || (tele.ok && tele.branch === "idle")) {
      return { ...tele, path: "teleop_fallback" };
    }
    let roles = applyCardinalRoles(control, fx, fy, tz, opts);
    roles = polishSurge(roles);
    if (roles.ok && (surgeOk(roles) || !isPureSurge(fx, fy, tz))) {
      return { ...roles, path: "cardinal_fallback" };
    }
    // Last resort: still return best surge-boosted reassembly duties if any.
    if (reass.ok && dutiesAlive(reass.duties)) {
      return { ...reass, path: "reassembly" };
    }
    return {
      ok: false,
      duties: reass.duties || zeroDuties(control.thrusters?.length || 0),
      branch: "failed",
      path: "failed",
    };
  }

  let tele = run((c, x, y, z) => applyTeleop(c, x, y, z, { skipCancel: true }));
  tele = polishSurge(tele);
  if (surgeOk(tele)) return { ...tele, path: "teleop" };
  let roles = applyCardinalRoles(control, fx, fy, tz, opts);
  roles = polishSurge(roles);
  if (roles.ok) return { ...roles, path: "cardinal_fallback" };
  return { ...tele, path: "teleop" };
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
  let hasStrafeFacing = false;
  for (const t of control.thrusters) {
    const f = t.facing || t.role;
    if (f === "left" || f === "right" || f === "port" || f === "starboard") {
      hasStrafeFacing = true;
      break;
    }
  }
  ranked.forEach((row, idx) => {
    const t = row.t;
    const facing = String(t.facing || t.role || "").toLowerCase();
    if (
      hasStrafeFacing &&
      (facing === "forward" || facing === "surge" || facing === "main") &&
      Math.abs(row.s) < 1e-6
    ) {
      return;
    }
    if (
      t.kind === "motor" ||
      Math.abs(t.fx || 0) > 0.01 ||
      Math.abs(t.fy || 0) > 0.01
    ) {
      let sideSign = idx <= n / 2 ? -1 : 1;
      if (row.s !== 0) sideSign = row.s < 0 ? -1 : 1;
      // Match τ = (r−com)×F so A (+tz) → +Tz (left / CCW).
      let sign = sideSign;
      if (facing === "forward" || facing === "surge" || facing === "main") {
        sign = -sideSign;
      } else if (facing === "back" || facing === "aft" || facing === "reverse") {
        sign = sideSign;
      }
      t.tz = sign * base * 0.5;
      t.side_score = sideSign;
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

/**
 * If pure-W duties left almost no surge, light surge-capable thrusters weighted
 * by max_force / |fx| so unequal motors still push forward.
 * Only adjusts forward/back (or fx-contributing) thrusters — never lights L/R.
 */
function ensureSurgeDuties(thrusters, duties, fxCmd, opts = {}) {
  const deadband = opts.deadband ?? DUTY_DEADBAND;
  const minFx = opts.minFx ?? 0.35;
  const out = duties.map((d) => d || 0);
  let w = netWrench(thrusters, out);
  if (Math.sign(w.Fx) === Math.sign(fxCmd) && Math.abs(w.Fx) >= minFx) {
    return out;
  }
  const sign = Math.sign(fxCmd) || 1;
  let maxScore = 0;
  const scores = thrusters.map((t) => {
    const facing = String(t.facing || t.role || "").toLowerCase();
    const strength =
      Number(t.max_force) ||
      Number(t.strength) ||
      Math.max(Math.abs(t.fx || 0), 0.25);
    let s = 0;
    if (facing === "forward" || facing === "surge" || facing === "main") {
      s = sign * strength;
    } else if (facing === "back" || facing === "aft" || facing === "reverse") {
      s = -sign * strength;
    } else if (
      Math.abs(t.fx || 0) >= 0.05 &&
      Math.abs(t.fx || 0) >= Math.abs(t.fy || 0) * 0.75
    ) {
      s = sign * (t.fx || 0);
    }
    maxScore = Math.max(maxScore, Math.abs(s));
    return s;
  });
  if (maxScore < 1e-8) return out;

  for (let i = 0; i < thrusters.length; i++) {
    if (Math.abs(scores[i]) < 1e-8) continue; // leave L/R / cancel thrusters alone
    const reversible = thrusters[i].kind === "motor";
    let duty = (scores[i] / maxScore) * Math.min(1, Math.abs(fxCmd));
    if (Math.abs(duty) < deadband) duty = 0;
    duty = reversible ? clamp(duty, -1, 1) : clamp(duty, 0, 1);
    // Take the stronger surge contribution; keep existing if already larger same-sign.
    if (Math.sign(duty) === Math.sign(out[i]) && Math.abs(out[i]) >= Math.abs(duty)) {
      continue;
    }
    out[i] = duty;
  }
  w = netWrench(thrusters, out);
  if (Math.sign(w.Fx) !== Math.sign(fxCmd) || Math.abs(w.Fx) < minFx * 0.5) {
    for (let i = 0; i < thrusters.length; i++) {
      const facing = String(thrusters[i].facing || thrusters[i].role || "").toLowerCase();
      if (facing === "forward" || facing === "surge" || facing === "main") {
        out[i] = thrusters[i].kind === "motor" ? sign : Math.max(0, sign);
      } else if (facing === "back" || facing === "aft" || facing === "reverse") {
        out[i] = thrusters[i].kind === "motor" ? -sign : 0;
      }
    }
  }
  return out;
}

function ensureStrafeDuties(thrusters, duties, fyCmd, opts = {}) {
  const deadband = opts.deadband ?? DUTY_DEADBAND;
  const minFy = opts.minFy ?? 0.2;
  const out = duties.map((d) => d || 0);
  let w = netWrench(thrusters, out);
  if (Math.sign(w.Fy) === Math.sign(fyCmd) && Math.abs(w.Fy) >= minFy) {
    return out;
  }
  const sign = Math.sign(fyCmd) || 1;
  let maxScore = 0;
  const scores = thrusters.map((t) => {
    const facing = String(t.facing || t.role || "").toLowerCase();
    const strength =
      Number(t.max_force) ||
      Number(t.strength) ||
      Math.max(Math.abs(t.fy || 0), 0.25);
    let s = 0;
    if (facing === "right" || facing === "starboard" || facing === "stbd") {
      s = sign * strength;
    } else if (facing === "left" || facing === "port") {
      s = -sign * strength;
    } else if (Math.abs(t.fy || 0) >= 0.02) {
      s = sign * (t.fy || 0);
    }
    maxScore = Math.max(maxScore, Math.abs(s));
    return s;
  });
  if (maxScore < 1e-8) return out;
  for (let i = 0; i < thrusters.length; i++) {
    const reversible = thrusters[i].kind === "motor";
    let duty = (scores[i] / maxScore) * Math.min(1, Math.abs(fyCmd));
    if (Math.abs(duty) < deadband) duty = 0;
    out[i] = reversible ? clamp(duty, -1, 1) : clamp(duty, 0, 1);
  }
  return out;
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
export function applyTeleop(control, fx = 0, fy = 0, tz = 0, opts = {}) {
  if (!isWrenchMode(control)) {
    return { ok: false, duties: [], branch: "not_wrench" };
  }
  if (opts.skipCancel !== true && opts.compensate !== false) {
    return allocateWithComCancel(
      (c, x, y, z) => applyTeleop(c, x, y, z, { skipCancel: true }),
      control,
      fx,
      fy,
      tz,
      opts,
    );
  }
  enrichControl(control, opts);
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
  const pureSurge = isPureSurge(fx, fy, tz);
  const pureYaw = isPureYaw(fx, fy, tz);
  const pureStrafe = isPureStrafe(fx, fy, tz);

  let branch = "chord";
  let useEqual;
  let useCalibTz;

  if (pureSurge) {
    branch = "pure_surge";
    useEqual = maxFx < Math.max(0.04, maxFy * 0.35, maxTz * 0.35);
    for (let i = 0; i < n; i++) {
      if (useEqual) {
        // Weight by max_force so unequal motors don't equal-duty cancel / strafe.
        const strength =
          Number(thrusters[i].max_force) ||
          Number(thrusters[i].strength) ||
          1;
        scores[i] = fx * strength;
      } else {
        scores[i] = fx * (thrusters[i].fx || 0);
      }
    }
  } else if (pureYaw) {
    branch = "pure_yaw";
    useCalibTz = maxTz >= 0.02 && maxTz >= Math.max(maxFx, maxFy) * 0.1;
    for (let i = 0; i < n; i++) {
      if (useCalibTz) {
        scores[i] = tz * (thrusters[i].tz || 0);
      } else {
        scores[i] = tz * yawAuthority(thrusters[i], sides[i]);
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
        const auth = yawAuthority(t, sides[i]);
        yawLever =
          auth *
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
        scores[i] =
          (tz !== 0 ? tz : fy) * yawAuthority(thrusters[i], sides[i] || 1);
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
export function applyReassembly(control, fx = 0, fy = 0, tz = 0, opts = {}) {
  if (!isWrenchMode(control)) {
    return { ok: false, duties: [], branch: "not_wrench" };
  }
  if (opts.skipCancel !== true && opts.compensate !== false) {
    return allocateWithComCancel(
      (c, x, y, z) => applyReassembly(c, x, y, z, { skipCancel: true }),
      control,
      fx,
      fy,
      tz,
      opts,
    );
  }
  enrichControl(control, opts);
  const thrusters = control.thrusters;
  const n = thrusters.length;
  const cmdMag = Math.sqrt(fx * fx + fy * fy + tz * tz);
  if (cmdMag < 1e-4) {
    return { ok: true, duties: zeroDuties(n), branch: "idle" };
  }

  let gain = (control.gains && control.gains.norm) || 1;
  if (gain < 1e-6) gain = 1;

  // Cost weights. Sqrt applied as sw below.
  // Pure / near-pure surge: prioritize Fx — yaw polished in duty-space with Fx floor.
  // (Command-space cancel may inject small tz; keep surge weights while |fx| dominates.)
  let axW = [1.0, 1.0, 1.0];
  let dutyDeadband = 0.08;
  const absFx = Math.abs(fx);
  const absFy = Math.abs(fy);
  const absTz = Math.abs(tz);
  const pureSurge = absFx >= 0.5 && absFy + absTz < 0.25;
  const pureStrafe = absFy >= 0.5 && absFx + absTz < 0.25;
  const surgePriority = absFx >= 0.5 && absFx >= absFy && absTz < 0.85;
  const strafePriority = absFy >= 0.5 && absFy >= absFx && absTz < 0.85;
  if (pureStrafe || (strafePriority && !surgePriority)) {
    axW = [2.2, 3.0, 2.5];
    dutyDeadband = 0.1;
  } else if (pureSurge || surgePriority) {
    // Keep Fx dominant but give Tz enough weight that LS leaves less residual yaw.
    axW = [3.8, 1.6, 1.6];
    dutyDeadband = 0.1;
  } else if (absTz >= 0.5 && absFx + absFy < 0.25) {
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

  // Prefer clamp over target-rescale for surge/strafe so saturation does not
  // shrink commanded Fx/Fy just to keep Tz exactly zero.
  let rawU = pack.u;
  if (pack.maxAbs > 1) {
    if (surgePriority || strafePriority) {
      rawU = pack.u.map((ui, i) => {
        const reversible = thrusters[i].kind === "motor";
        return clamp(ui, reversible ? -1 : 0, 1);
      });
    } else {
      const pack2 = dutiesFor(1.0 / pack.maxAbs);
      if (pack2) rawU = pack2.u;
    }
  }

  let duties = rawU.map((ui, i) => {
    const reversible = thrusters[i].kind === "motor";
    let duty = clamp(ui, reversible ? -1 : 0, 1);
    if (Math.abs(duty) < dutyDeadband) duty = 0;
    return duty;
  });

  // Deadband wiped every thruster → treat as failure so applyCommand can fall back.
  if (!dutiesAlive(duties, dutyDeadband)) {
    return { ok: false, duties, branch: "deadband", axW, dutyDeadband };
  }

  // If pure surge LS left almost no Fx, boost surge-facing thrusters (weighted by max_force).
  if (pureSurge || (surgePriority && absTz < 0.35)) {
    duties = ensureSurgeDuties(thrusters, duties, fx, { deadband: dutyDeadband });
  } else if (pureStrafe || (strafePriority && absTz < 0.35)) {
    duties = ensureStrafeDuties(thrusters, duties, fy, { deadband: dutyDeadband });
  }

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
