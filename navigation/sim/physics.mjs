/**
 * 3D rigid-body boat semi-sim for thruster duty visualization.
 * Body frame: +x forward (surge), +y starboard (strafe), +z up.
 * Angular: roll (wx), pitch (wy), yaw (wz) — CCW positive about each axis.
 * World: +X east, +Y north, +Z up; yaw 0 faces +Y (north) for top-down viz.
 */

export function createBody(opts = {}) {
  const wz = opts.wz ?? opts.omega ?? 0;
  return {
    x: opts.x ?? 0,
    y: opts.y ?? 0,
    z: opts.z ?? 0,
    yaw: opts.yaw ?? 0,
    pitch: opts.pitch ?? 0,
    roll: opts.roll ?? 0,
    vx: opts.vx ?? 0,
    vy: opts.vy ?? 0,
    vz: opts.vz ?? 0,
    wx: opts.wx ?? 0,
    wy: opts.wy ?? 0,
    wz,
    /** Alias of wz for callers that still use 2D naming. */
    omega: wz,
  };
}

export function defaultPhysicsParams(overrides = {}) {
  return {
    mass: 8,
    /** Diagonal inertia (body axes). `inertia` alone sets Iz for yaw. */
    Ix: 3,
    Iy: 4,
    Iz: 4,
    inertia: 4,
    linearDrag: 1.2,
    angularDrag: 2.0,
    /** Extra damping on world vertical velocity (water). */
    verticalDrag: 8,
    /** Soft spring holding boat near water plane z=0. */
    waterSpring: 25,
    /** Cap |z| soft clamp after integrate (optional fly-prevention). */
    waterPlaneClamp: 0.35,
    /** Scale calib wrench → Newtons / N·m at duty=1 */
    wrenchForceScale: 40,
    wrenchTorqueScale: 25,
    /** Geometric mode: Newtons at duty=1 along thruster direction */
    geometricForceScale: 50,
    forceMode: "wrench", // "wrench" | "geometric"
    ...overrides,
  };
}

function resolveInertia(p) {
  const Iz = p.Iz ?? p.inertia ?? 4;
  return {
    Ix: p.Ix ?? Iz * 0.75,
    Iy: p.Iy ?? Iz,
    Iz,
  };
}

/**
 * Body-frame 6DOF wrench from duties × calibrated wrenches.
 * Uses thruster.fx/fy/fz and tx/ty/tz (tz preferred; legacy only tz).
 */
export function wrenchFromDuties(thrusters, duties, params) {
  const p = { ...defaultPhysicsParams(), ...params };
  let Fx = 0;
  let Fy = 0;
  let Fz = 0;
  let Tx = 0;
  let Ty = 0;
  let Tz = 0;
  for (let i = 0; i < thrusters.length; i++) {
    const d = duties[i] || 0;
    if (Math.abs(d) < 1e-9) continue;
    const t = thrusters[i];
    Fx += d * (t.fx || 0) * p.wrenchForceScale;
    Fy += d * (t.fy || 0) * p.wrenchForceScale;
    Fz += d * (t.fz || 0) * p.wrenchForceScale;
    Tx += d * (t.tx || 0) * p.wrenchTorqueScale;
    Ty += d * (t.ty || 0) * p.wrenchTorqueScale;
    Tz += d * (t.tz || 0) * p.wrenchTorqueScale;
  }
  return { Fx, Fy, Fz, Tx, Ty, Tz };
}

const FACING_DIRS = {
  forward: { x: 1, y: 0, z: 0 },
  back: { x: -1, y: 0, z: 0 },
  left: { x: 0, y: -1, z: 0 },
  right: { x: 0, y: 1, z: 0 },
};

/** Unit thrust direction in body frame from thruster fields. */
export function thrusterDirection(t) {
  const facing = t.facing || t.role;
  if (facing && FACING_DIRS[String(facing).toLowerCase()]) {
    return { ...FACING_DIRS[String(facing).toLowerCase()] };
  }
  if (t.dirX != null || t.dirY != null || t.dirZ != null) {
    const x = Number(t.dirX) || 0;
    const y = Number(t.dirY) || 0;
    const z = Number(t.dirZ) || 0;
    const len = Math.hypot(x, y, z) || 1;
    return { x: x / len, y: y / len, z: z / len };
  }
  const ang = t.angleRad != null ? t.angleRad : 0;
  const elev = t.elevRad != null ? t.elevRad : 0;
  const ce = Math.cos(elev);
  return {
    x: Math.cos(ang) * ce,
    y: Math.sin(ang) * ce,
    z: Math.sin(elev),
  };
}

/** Per-thruster strength multiplier (max_force / strength, default 1). */
export function thrusterStrength(t) {
  const s = Number(t.max_force ?? t.strength);
  return Number.isFinite(s) && s > 0 ? s : 1;
}

/**
 * Geometric: each thruster pushes along local direction at (lx, ly, lz).
 * Torque τ = r × F.
 */
export function geometricFromDuties(thrusters, duties, params) {
  const p = { ...defaultPhysicsParams(), ...params };
  let Fx = 0;
  let Fy = 0;
  let Fz = 0;
  let Tx = 0;
  let Ty = 0;
  let Tz = 0;
  for (let i = 0; i < thrusters.length; i++) {
    const d = duties[i] || 0;
    if (Math.abs(d) < 1e-9) continue;
    const t = thrusters[i];
    const dir = thrusterDirection(t);
    const mag = d * thrusterStrength(t) * p.geometricForceScale;
    const fx = dir.x * mag;
    const fy = dir.y * mag;
    const fz = dir.z * mag;
    const lx = t.lx || 0;
    const ly = t.ly || 0;
    const lz = t.lz || 0;
    Fx += fx;
    Fy += fy;
    Fz += fz;
    // τ = r × F
    Tx += ly * fz - lz * fy;
    Ty += lz * fx - lx * fz;
    Tz += lx * fy - ly * fx;
  }
  return { Fx, Fy, Fz, Tx, Ty, Tz };
}

export function forcesFromDuties(thrusters, duties, params) {
  const p = { ...defaultPhysicsParams(), ...params };
  if (p.forceMode === "geometric") {
    return geometricFromDuties(thrusters, duties, p);
  }
  return wrenchFromDuties(thrusters, duties, p);
}

function isFiniteNumber(n) {
  return typeof n === "number" && Number.isFinite(n);
}

/** Body → world rotation of a vector (yaw/pitch/roll, ZYX extrinsic ≈ body yaw then pitch then roll). */
export function bodyToWorld(body, bx, by, bz) {
  const cy = Math.cos(body.yaw);
  const sy = Math.sin(body.yaw);
  const cp = Math.cos(body.pitch);
  const sp = Math.sin(body.pitch);
  const cr = Math.cos(body.roll);
  const sr = Math.sin(body.roll);
  // R = Rz(yaw) * Ry(pitch) * Rx(roll), with yaw0 facing +Y:
  // forward(+x_body) → (sin yaw, cos yaw, 0) when pitch=roll=0
  const x1 = bx;
  const y1 = by * cr - bz * sr;
  const z1 = by * sr + bz * cr;
  const x2 = x1 * cp + z1 * sp;
  const y2 = y1;
  const z2 = -x1 * sp + z1 * cp;
  const wx = x2 * sy + y2 * cy;
  const wy = x2 * cy - y2 * sy;
  const wz = z2;
  return { x: wx, y: wy, z: wz };
}

/** World → body (inverse of bodyToWorld). */
export function worldToBody(body, wx, wy, wz) {
  const cy = Math.cos(body.yaw);
  const sy = Math.sin(body.yaw);
  const cp = Math.cos(body.pitch);
  const sp = Math.sin(body.pitch);
  const cr = Math.cos(body.roll);
  const sr = Math.sin(body.roll);
  // Inverse: Rx(-roll) Ry(-pitch) then un-yaw mapping
  const x2 = wx * sy + wy * cy;
  const y2 = wx * cy - wy * sy;
  const z2 = wz;
  const x1 = x2 * cp - z2 * sp;
  const y1 = y2;
  const z1 = x2 * sp + z2 * cp;
  const bx = x1;
  const by = y1 * cr + z1 * sr;
  const bz = -y1 * sr + z1 * cr;
  return { x: bx, y: by, z: bz };
}

/**
 * Semi-implicit Euler step. Mutates and returns body.
 * Water plane: vertical spring + strong vz damping; soft |z| clamp.
 */
export function step(body, thrusters, duties, params, dt) {
  const p = { ...defaultPhysicsParams(), ...params };
  const I = resolveInertia(p);
  const { Fx, Fy, Fz, Tx, Ty, Tz } = forcesFromDuties(thrusters, duties, p);

  const vB = worldToBody(body, body.vx, body.vy, body.vz);

  // Water: spring + vertical drag in world Z, applied in body via transform of residual
  const waterForceZ = -p.waterSpring * body.z - p.verticalDrag * body.vz;
  const waterB = worldToBody(body, 0, 0, waterForceZ);

  const axB = Fx / p.mass - p.linearDrag * vB.x + waterB.x / p.mass;
  const ayB = Fy / p.mass - p.linearDrag * vB.y + waterB.y / p.mass;
  const azB = Fz / p.mass - p.linearDrag * vB.z + waterB.z / p.mass;

  const alphaX = Tx / I.Ix - p.angularDrag * body.wx;
  const alphaY = Ty / I.Iy - p.angularDrag * body.wy;
  const alphaZ = Tz / I.Iz - p.angularDrag * body.wz;

  const aW = bodyToWorld(body, axB, ayB, azB);

  body.vx += aW.x * dt;
  body.vy += aW.y * dt;
  body.vz += aW.z * dt;
  body.wx += alphaX * dt;
  body.wy += alphaY * dt;
  body.wz += alphaZ * dt;
  body.omega = body.wz;

  body.x += body.vx * dt;
  body.y += body.vy * dt;
  body.z += body.vz * dt;

  // Approximate attitude integrate (small-angle / planar boats: yaw primary)
  body.roll += body.wx * dt;
  body.pitch += body.wy * dt;
  body.yaw += body.wz * dt;

  if (body.yaw > Math.PI) body.yaw -= 2 * Math.PI;
  if (body.yaw < -Math.PI) body.yaw += 2 * Math.PI;
  body.pitch = Math.max(-Math.PI / 2, Math.min(Math.PI / 2, body.pitch));
  if (body.roll > Math.PI) body.roll -= 2 * Math.PI;
  if (body.roll < -Math.PI) body.roll += 2 * Math.PI;

  if (p.waterPlaneClamp != null && Number.isFinite(p.waterPlaneClamp)) {
    const lim = p.waterPlaneClamp;
    if (body.z > lim) {
      body.z = lim;
      if (body.vz > 0) body.vz = 0;
    } else if (body.z < -lim) {
      body.z = -lim;
      if (body.vz < 0) body.vz = 0;
    }
  }

  return {
    body,
    forces: { Fx, Fy, Fz, Tx, Ty, Tz },
    localVel: { forward: vB.x, right: vB.y, up: vB.z },
    ok:
      isFiniteNumber(body.x) &&
      isFiniteNumber(body.y) &&
      isFiniteNumber(body.z) &&
      isFiniteNumber(body.yaw) &&
      isFiniteNumber(body.pitch) &&
      isFiniteNumber(body.roll) &&
      isFiniteNumber(body.vx) &&
      isFiniteNumber(body.vy) &&
      isFiniteNumber(body.vz) &&
      isFiniteNumber(body.wx) &&
      isFiniteNumber(body.wy) &&
      isFiniteNumber(body.wz),
  };
}

/** Net yaw torque contribution if all duties are equal (symmetry check helper). */
export function netTorqueForEqualDuties(thrusters, duty, params) {
  const duties = thrusters.map(() => duty);
  return wrenchFromDuties(thrusters, duties, params).Tz;
}
