/**
 * Watercraft physics: buoyancy, offset CoM, hull drag, thruster τ = (r − r_com) × F.
 * Body frame: +x forward (surge), +y starboard (strafe), +z up.
 * World: +X east, +Y north, +Z up; yaw 0 faces +Y (north) for top-down viz.
 *
 * Planar yaw is right-hand about +Z = CCW from above = craft-left (matches +tz / A).
 * Do not use a CW heading embedding — that makes A look inverted while +Tz tests still pass.
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
    omega: wz,
  };
}

export function defaultPhysicsParams(overrides = {}) {
  return {
    mass: 8,
    Ix: 3,
    Iy: 4,
    Iz: 4,
    inertia: 4,
    /** Body-frame CoM offset from geometric origin (hull reference). */
    comX: 0,
    comY: 0,
    comZ: -0.05,
    gravity: 9.81,
    /** Water density (kg/m³). */
    waterDensity: 1000,
    /**
     * Hull displaced volume at full submersion (m³). Equilibrium when
     * ρ·V_sub·g ≈ mass·g → V_sub ≈ mass/ρ. Draft fraction scales volume.
     */
    hullVolume: 0.012,
    /** Vertical extent of hull for waterline / draft (m). */
    hullHeight: 0.35,
    /** Half-length / half-beam for pontoon sample layout (m). */
    hullLength: 1.1,
    hullBeam: 0.7,
    /** Number of buoyancy sample points along length×beam grid. */
    pontoonSamples: 6,
    linearDrag: 1.2,
    quadraticDrag: 0.35,
    angularDrag: 2.0,
    yawDamping: 0.8,
    verticalDrag: 6,
    /** Soft clamp only as a safety net (buoyancy is primary). */
    waterPlaneClamp: 1.2,
    wrenchForceScale: 40,
    wrenchTorqueScale: 25,
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

export function thrusterStrength(t) {
  const s = Number(t.max_force ?? t.strength);
  return Number.isFinite(s) && s > 0 ? s : 1;
}

/**
 * Geometric: each thruster pushes along local direction at (lx, ly, lz).
 * Torque about CoM: τ = (r − r_com) × F.
 */
export function geometricFromDuties(thrusters, duties, params) {
  const p = { ...defaultPhysicsParams(), ...params };
  const cx = p.comX || 0;
  const cy = p.comY || 0;
  const cz = p.comZ || 0;
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
    const rx = (t.lx || 0) - cx;
    const ry = (t.ly || 0) - cy;
    const rz = (t.lz || 0) - cz;
    Fx += fx;
    Fy += fy;
    Fz += fz;
    Tx += ry * fz - rz * fy;
    Ty += rz * fx - rx * fz;
    Tz += rx * fy - ry * fx;
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

export function bodyToWorld(body, bx, by, bz) {
  const cy = Math.cos(body.yaw);
  const sy = Math.sin(body.yaw);
  const cp = Math.cos(body.pitch);
  const sp = Math.sin(body.pitch);
  const cr = Math.cos(body.roll);
  const sr = Math.sin(body.roll);
  const x1 = bx;
  const y1 = by * cr - bz * sr;
  const z1 = by * sr + bz * cr;
  const x2 = x1 * cp + z1 * sp;
  const y2 = y1;
  const z2 = -x1 * sp + z1 * cp;
  // Yaw CCW from +Y (north): +yaw → nose toward −X (west / screen-left).
  const wx = -x2 * sy + y2 * cy;
  const wy = x2 * cy + y2 * sy;
  const wz = z2;
  return { x: wx, y: wy, z: wz };
}

export function worldToBody(body, wx, wy, wz) {
  const cy = Math.cos(body.yaw);
  const sy = Math.sin(body.yaw);
  const cp = Math.cos(body.pitch);
  const sp = Math.sin(body.pitch);
  const cr = Math.cos(body.roll);
  const sr = Math.sin(body.roll);
  // Inverse of bodyToWorld yaw (CCW from +Y).
  const x2 = -wx * sy + wy * cy;
  const y2 = wx * cy + wy * sy;
  const z2 = wz;
  const x1 = x2 * cp - z2 * sp;
  const y1 = y2;
  const z1 = x2 * sp + z2 * cp;
  const bx = x1;
  const by = y1 * cr + z1 * sr;
  const bz = -y1 * sr + z1 * cr;
  return { x: bx, y: by, z: bz };
}

/** Local sample points on hull bottom for multi-point buoyancy. */
export function pontoonPoints(params) {
  const p = { ...defaultPhysicsParams(), ...params };
  const n = Math.max(2, Math.floor(p.pontoonSamples || 6));
  const halfL = (p.hullLength || 1.1) * 0.5;
  const halfB = (p.hullBeam || 0.7) * 0.5;
  const keel = -(p.hullHeight || 0.35) * 0.5;
  const pts = [];
  const along = Math.ceil(Math.sqrt(n));
  const across = Math.max(2, Math.ceil(n / along));
  for (let i = 0; i < along; i++) {
    const u = along === 1 ? 0 : i / (along - 1);
    const lx = -halfL + 2 * halfL * u;
    for (let j = 0; j < across; j++) {
      const v = across === 1 ? 0 : j / (across - 1);
      const ly = -halfB + 2 * halfB * v;
      pts.push({ lx, ly, lz: keel });
    }
  }
  return pts;
}

/**
 * Submerged fraction of a pontoon sample from world height of the point.
 * waterline at world z=0: fully submerged when point.z << 0.
 */
function sampleSubmerge(worldZ, hullHeight) {
  const h = Math.max(0.05, hullHeight || 0.35);
  // Point represents a vertical column of height h centered on lz.
  const top = worldZ + h * 0.5;
  const bot = worldZ - h * 0.5;
  if (top <= 0) return 1;
  if (bot >= 0) return 0;
  return Math.max(0, Math.min(1, -bot / h));
}

/**
 * Buoyancy + gravity wrench in body frame, plus diagnostics.
 * Restores pitch/roll when heeled (asymmetric submersion).
 */
export function buoyancyWrench(body, params) {
  const p = { ...defaultPhysicsParams(), ...params };
  const pts = pontoonPoints(p);
  const perVol = (p.hullVolume || 0.012) / Math.max(1, pts.length);
  const rho = p.waterDensity || 1000;
  const g = p.gravity || 9.81;
  const cx = p.comX || 0;
  const cy = p.comY || 0;
  const cz = p.comZ || 0;

  let Fx = 0;
  let Fy = 0;
  let Fz = 0;
  let Tx = 0;
  let Ty = 0;
  let Tz = 0;
  let submergedVol = 0;
  let weight = p.mass * g;

  // Gravity at CoM (world −Z) → body
  const gB = worldToBody(body, 0, 0, -weight);
  Fx += gB.x;
  Fy += gB.y;
  Fz += gB.z;
  // Gravity acts at CoM → no torque about CoM

  for (const pt of pts) {
    const w = bodyToWorld(body, pt.lx, pt.ly, pt.lz);
    const worldZ = body.z + w.z;
    const sub = sampleSubmerge(worldZ, p.hullHeight);
    if (sub < 1e-6) continue;
    const dV = perVol * sub;
    submergedVol += dV;
    const buoy = rho * dV * g; // world +Z
    const fB = worldToBody(body, 0, 0, buoy);
    Fx += fB.x;
    Fy += fB.y;
    Fz += fB.z;
    const rx = pt.lx - cx;
    const ry = pt.ly - cy;
    const rz = pt.lz - cz;
    Tx += ry * fB.z - rz * fB.y;
    Ty += rz * fB.x - rx * fB.z;
    Tz += rx * fB.y - ry * fB.x;
  }

  const buoyancy = rho * submergedVol * g;
  // Draft / waterline marker: + when floating high (origin above water)
  const waterline = body.z;
  const equilibriumDraft =
    (p.mass / Math.max(1e-9, rho * (p.hullVolume || 0.012))) *
    (p.hullHeight || 0.35) *
    0.5;

  return {
    Fx,
    Fy,
    Fz,
    Tx,
    Ty,
    Tz,
    buoyancy,
    weight,
    submergedVol,
    waterline,
    equilibriumDraft,
    floats: buoyancy + 1e-6 >= weight * 0.98,
  };
}

/**
 * Semi-implicit Euler step with buoyancy, drag, thrusters about CoM.
 */
export function step(body, thrusters, duties, params, dt) {
  const p = { ...defaultPhysicsParams(), ...params };
  const I = resolveInertia(p);
  const thrust = forcesFromDuties(thrusters, duties, p);
  const hydro = buoyancyWrench(body, p);

  const Fx = thrust.Fx + hydro.Fx;
  const Fy = thrust.Fy + hydro.Fy;
  const Fz = thrust.Fz + hydro.Fz;
  const Tx = thrust.Tx + hydro.Tx;
  const Ty = thrust.Ty + hydro.Ty;
  const Tz = thrust.Tz + hydro.Tz;

  const vB = worldToBody(body, body.vx, body.vy, body.vz);
  const speed = Math.hypot(vB.x, vB.y, vB.z);
  const lin = p.linearDrag || 0;
  const quad = p.quadraticDrag || 0;
  const vert = p.verticalDrag || 0;

  const dragX = -lin * vB.x - quad * vB.x * Math.abs(vB.x);
  const dragY = -lin * vB.y - quad * vB.y * Math.abs(vB.y);
  // Extra heave damping when near the waterline (kills bounce from buoyancy).
  const heaveBoost = 2 + 10 / (1 + Math.abs(body.z) * 6);
  const dragZ =
    -lin * vB.z - quad * vB.z * Math.abs(vB.z) - vert * heaveBoost * vB.z;

  const axB = (Fx + dragX) / p.mass;
  const ayB = (Fy + dragY) / p.mass;
  const azB = (Fz + dragZ) / p.mass;

  const yawDamp = (p.yawDamping || 0) * body.wz;
  const alphaX = Tx / I.Ix - p.angularDrag * body.wx;
  const alphaY = Ty / I.Iy - p.angularDrag * body.wy;
  const alphaZ = Tz / I.Iz - p.angularDrag * body.wz - yawDamp;

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
    thrust,
    hydro,
    localVel: { forward: vB.x, right: vB.y, up: vB.z },
    speed,
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
