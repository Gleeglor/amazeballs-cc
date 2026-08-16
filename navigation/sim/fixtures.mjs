/**
 * Mock boat_control.json thruster tables for sim + unit tests.
 *
 * Primary layout: Amazeballs 5-thruster cardinal boat (1 forward + 4 maneuver).
 * Thrusters face craft-cardinal directions: forward | back | left | right.
 */

import {
  enrichControl,
  syncWrenchFromFacing,
  classifyFacingFromWrench,
  facingToDir,
} from "./allocation.mjs";

export {
  FACING_DIRS,
  facingToDir,
  classifyFacingFromWrench,
} from "./allocation.mjs";

function withMag(t) {
  return {
    ...t,
    mag: Math.sqrt((t.fx || 0) ** 2 + (t.fy || 0) ** 2 + (t.tz || 0) ** 2),
  };
}

/**
 * Geometry assumptions for the default 5-thruster boat (editable in sim JSON/UI):
 *
 * Body frame: +x forward (surge), +y starboard (strafe), CoM at origin.
 *
 *   main_fwd     facing forward  at stern centerline  (-0.95,  0.00)
 *                — primary surge thruster
 *   bow_port     facing left     at bow port          ( 0.55, -0.75)
 *   bow_stbd     facing right    at bow starboard     ( 0.55,  0.75)
 *                — strafe + yaw couple (τz = lx·Fy)
 *   stern_port   facing back     at stern port        (-0.65, -0.60)
 *   stern_stbd   facing back     at stern starboard   (-0.65,  0.60)
 *                — reverse (+duty) and yaw (τz = −ly·Fx with back force)
 *
 * Strengths are relative max_force at duty=1 (main slightly stronger).
 * Positions are free to edit; wrenches recompute from facing×strength×r×F.
 */
export function fixtureCardinal5Boat() {
  const thrusters = [
    {
      name: "main_fwd",
      kind: "motor",
      max_rpm: 24,
      facing: "forward",
      role: "forward",
      max_force: 1.0,
      lx: -0.95,
      ly: 0,
      lz: -0.05,
    },
    {
      name: "bow_port",
      kind: "motor",
      max_rpm: 24,
      facing: "left",
      role: "left",
      max_force: 0.75,
      lx: 0.55,
      ly: -0.75,
      lz: -0.05,
    },
    {
      name: "bow_stbd",
      kind: "motor",
      max_rpm: 24,
      facing: "right",
      role: "right",
      max_force: 0.75,
      lx: 0.55,
      ly: 0.75,
      lz: -0.05,
    },
    {
      name: "stern_port",
      kind: "motor",
      max_rpm: 24,
      facing: "back",
      role: "back",
      max_force: 0.7,
      lx: -0.65,
      ly: -0.6,
      lz: -0.05,
    },
    {
      name: "stern_stbd",
      kind: "motor",
      max_rpm: 24,
      facing: "back",
      role: "back",
      max_force: 0.7,
      lx: -0.65,
      ly: 0.6,
      lz: -0.05,
    },
  ].map((t) => withMag(syncWrenchFromFacing(t)));

  return {
    version: 6,
    mode: "wrench",
    alloc_mode: "reassembly",
    default_motor_rpm: 24,
    gains: { norm: 1 },
    yaw_sign: 1,
    com_compensate: true,
    com_x: 0,
    com_y: 0,
    com_z: -0.05,
    thrusters,
    description:
      "Default Amazeballs layout: 1 forward + 4 cardinal maneuver (L/R/back). Editable positions.",
  };
}

/**
 * Cardinal 5 with offset CoM — reproduces surge/strafe yaw couple until cancel.
 * @param {{comX?:number,comY?:number,comZ?:number}} [opts]
 */
export function fixtureCardinal5OffsetCom(opts = {}) {
  const base = fixtureCardinal5Boat();
  base.com_x = opts.comX ?? 0;
  base.com_y = opts.comY ?? 0.35;
  base.com_z = opts.comZ ?? -0.05;
  base.comX = base.com_x;
  base.comY = base.com_y;
  base.comZ = base.com_z;
  base.com_compensate = true;
  base.description = `Cardinal 5 with CoM offset (${base.com_x}, ${base.com_y}, ${base.com_z}).`;
  for (const t of base.thrusters) syncWrenchFromFacing(t, base);
  return base;
}

/** Lua-shaped v6 boat_control: facing + max_force + measured tz, little/no lx/ly. */
export function fixtureLuaLikeCardinal5(opts = {}) {
  const tzScale = opts.tzScale ?? 1;
  const thrusters = [
    {
      name: "fwd",
      kind: "motor",
      facing: "forward",
      role: "forward",
      max_force: 0.5,
      fx: 0.5,
      fy: 0,
      tz: 0.01 * tzScale,
      max_rpm: 24,
      side_score: 0,
    },
    {
      name: "port",
      kind: "motor",
      facing: "left",
      role: "left",
      max_force: 0.4,
      fx: 0,
      fy: -0.4,
      tz: 0.08 * tzScale,
      max_rpm: 24,
      side_score: -1,
      lever_est: -0.5,
    },
    {
      name: "stbd",
      kind: "motor",
      facing: "right",
      role: "right",
      max_force: 0.4,
      fx: 0,
      fy: 0.4,
      tz: -0.08 * tzScale,
      max_rpm: 24,
      side_score: 1,
      lever_est: 0.5,
    },
    {
      name: "aftL",
      kind: "motor",
      facing: "back",
      role: "back",
      max_force: 0.35,
      fx: -0.35,
      fy: 0,
      tz: 0.04 * tzScale,
      max_rpm: 24,
      side_score: -1,
      ly: -0.5,
    },
    {
      name: "aftR",
      kind: "motor",
      facing: "back",
      role: "back",
      max_force: 0.35,
      fx: -0.35,
      fy: 0,
      tz: -0.04 * tzScale,
      max_rpm: 24,
      side_score: 1,
      ly: 0.5,
    },
  ];
  return {
    version: 6,
    mode: "wrench",
    alloc_mode: "reassembly",
    default_motor_rpm: 24,
    gains: { norm: 0.5 },
    yaw_sign: opts.yawSign ?? 1,
    com_compensate: true,
    thrusters: thrusters.map(withMag),
    description: "In-game-equivalent boat_control.json v6 (facing + calib tz).",
  };
}

/** Same geometry with unequal max_force / max_rpm — size scalability. */
export function fixtureCardinal5Sized() {
  const base = fixtureCardinal5Boat();
  const scales = [1.2, 0.5, 0.9, 0.65, 1.0];
  const rpms = [24, 16, 20, 18, 24];
  base.thrusters.forEach((t, i) => {
    t.max_force = scales[i];
    t.max_rpm = rpms[i];
    syncWrenchFromFacing(t);
  });
  base.description =
    "Cardinal 5-layout with varied max_force / max_rpm (size smoke).";
  return base;
}

/** 6+ thrusters: cardinal 5 + bow forward helper. */
export function fixtureCardinal6Plus() {
  const base = fixtureCardinal5Boat();
  base.thrusters.push(
    withMag(
      syncWrenchFromFacing({
        name: "bow_helper",
        kind: "motor",
        max_rpm: 18,
        facing: "forward",
        role: "forward",
        max_force: 0.45,
        lx: 0.4,
        ly: 0,
        lz: -0.05,
      }),
    ),
  );
  base.description = "6 thrusters (cardinal 5 + bow forward helper).";
  return base;
}

/** Symmetric port/starboard pair — surge should not invent yaw under teleop equal-push. */
export function fixtureSymmetricStrafeNearCom() {
  const thrusters = [
    withMag({
      name: "motor_a",
      kind: "motor",
      max_rpm: 24,
      fx: 0.02,
      fy: 0.55,
      tz: 0.008,
      side_score: -1,
      lx: -0.15,
      ly: -0.4,
      lz: -0.05,
      angleRad: Math.PI / 2,
      facing: "right",
    }),
    withMag({
      name: "motor_b",
      kind: "motor",
      max_rpm: 24,
      fx: 0.02,
      fy: -0.55,
      tz: -0.008,
      side_score: 1,
      lx: -0.15,
      ly: 0.4,
      lz: -0.05,
      angleRad: -Math.PI / 2,
      facing: "left",
    }),
    withMag({
      name: "motor_c",
      kind: "motor",
      max_rpm: 24,
      fx: 0.02,
      fy: 0.5,
      tz: 0.006,
      side_score: -1,
      lx: 0.15,
      ly: -0.35,
      lz: -0.05,
      angleRad: Math.PI / 2,
      facing: "right",
    }),
    withMag({
      name: "motor_d",
      kind: "motor",
      max_rpm: 24,
      fx: 0.02,
      fy: -0.5,
      tz: -0.006,
      side_score: 1,
      lx: 0.15,
      ly: 0.35,
      lz: -0.05,
      angleRad: -Math.PI / 2,
      facing: "left",
    }),
  ];
  return {
    version: 2,
    mode: "wrench",
    default_motor_rpm: 24,
    gains: { norm: 1 },
    thrusters,
    description:
      "Near-CoM strafe-labeled rotors (weak fx, strong ±fy, tiny symmetric tz).",
  };
}

/**
 * Balanced corner thrusters — real fx/fy/tz so Reassembly LS can hit surge,
 * strafe, and yaw without saturating into a near-null cancel pattern.
 */
export function fixtureSymmetricSurge() {
  const thrusters = [
    withMag({
      name: "port_fwd",
      kind: "motor",
      max_rpm: 24,
      fx: 0.55,
      fy: 0.28,
      tz: 0.32,
      side_score: -1,
      lx: 0.5,
      ly: -0.8,
      lz: -0.08,
      angleRad: 0,
      facing: "forward",
    }),
    withMag({
      name: "stbd_fwd",
      kind: "motor",
      max_rpm: 24,
      fx: 0.55,
      fy: -0.28,
      tz: -0.32,
      side_score: 1,
      lx: 0.5,
      ly: 0.8,
      lz: -0.08,
      angleRad: 0,
      facing: "forward",
    }),
    withMag({
      name: "port_aft",
      kind: "motor",
      max_rpm: 24,
      fx: 0.5,
      fy: 0.22,
      tz: 0.28,
      side_score: -1,
      lx: -0.5,
      ly: -0.8,
      lz: -0.08,
      angleRad: 0,
      facing: "forward",
    }),
    withMag({
      name: "stbd_aft",
      kind: "motor",
      max_rpm: 24,
      fx: 0.5,
      fy: -0.22,
      tz: -0.28,
      side_score: 1,
      lx: -0.5,
      ly: 0.8,
      lz: -0.08,
      angleRad: 0,
      facing: "forward",
    }),
  ];
  return {
    version: 2,
    mode: "wrench",
    default_motor_rpm: 24,
    // Geometric left+ tz in this fixture — must not use v8 default yaw_sign=-1.
    yaw_sign: 1,
    gains: { norm: 1 },
    thrusters,
    description:
      "Symmetric corner thrusters with real fx/fy/tz for Reassembly + teleop.",
  };
}

/** Asymmetric calib — useful to show why Reassembly W can yaw. */
export function fixtureAsymmetricNearCom() {
  const thrusters = [
    withMag({
      name: "motor_a",
      kind: "motor",
      max_rpm: 24,
      fx: 0.05,
      fy: 0.7,
      tz: 0.04,
      side_score: -1,
      lx: 0,
      ly: -0.3,
      lz: -0.05,
      angleRad: Math.PI / 2,
    }),
    withMag({
      name: "motor_b",
      kind: "motor",
      max_rpm: 24,
      fx: -0.02,
      fy: -0.4,
      tz: -0.01,
      side_score: 1,
      lx: 0.1,
      ly: 0.45,
      lz: -0.05,
      angleRad: -Math.PI / 2,
    }),
    withMag({
      name: "motor_c",
      kind: "motor",
      max_rpm: 24,
      fx: 0.08,
      fy: 0.35,
      tz: 0.02,
      side_score: -1,
      lx: -0.05,
      ly: -0.5,
      lz: -0.05,
      angleRad: Math.PI / 2,
    }),
    withMag({
      name: "motor_d",
      kind: "motor",
      max_rpm: 24,
      fx: 0.01,
      fy: -0.65,
      tz: -0.03,
      side_score: 1,
      lx: 0,
      ly: 0.25,
      lz: -0.05,
      angleRad: -Math.PI / 2,
    }),
  ];
  return {
    version: 2,
    mode: "wrench",
    default_motor_rpm: 24,
    gains: { norm: 1 },
    thrusters,
    description: "Asymmetric near-CoM set — LS nulling may spin 'stabilizers' on W.",
  };
}

/**
 * Asymmetric cardinal: strong port / weak starboard, forward off centerline,
 * CoM offset starboard — classic “W doesn’t go forward / drifts off center”.
 */
export function fixtureAsymmetricCardinal(opts = {}) {
  const comY = opts.comY ?? 0.4;
  const comX = opts.comX ?? 0;
  const thrusters = [
    {
      name: "fwd_portish",
      kind: "motor",
      max_rpm: 24,
      facing: "forward",
      role: "forward",
      max_force: 1.2,
      lx: -0.9,
      ly: -0.5,
      lz: -0.05,
    },
    {
      name: "bow_port",
      kind: "motor",
      max_rpm: 24,
      facing: "left",
      role: "left",
      max_force: 0.9,
      lx: 0.5,
      ly: -0.9,
      lz: -0.05,
    },
    {
      name: "bow_stbd",
      kind: "motor",
      max_rpm: 24,
      facing: "right",
      role: "right",
      max_force: 0.25,
      lx: 0.5,
      ly: 0.7,
      lz: -0.05,
    },
    {
      name: "stern_port",
      kind: "motor",
      max_rpm: 24,
      facing: "back",
      role: "back",
      max_force: 0.8,
      lx: -0.7,
      ly: -0.7,
      lz: -0.05,
    },
    {
      name: "stern_stbd",
      kind: "motor",
      max_rpm: 24,
      facing: "back",
      role: "back",
      max_force: 0.25,
      lx: -0.5,
      ly: 0.5,
      lz: -0.05,
    },
  ].map((t) => withMag(syncWrenchFromFacing(t)));

  const control = {
    version: 6,
    mode: "wrench",
    alloc_mode: "reassembly",
    default_motor_rpm: 24,
    gains: { norm: 1 },
    yaw_sign: 1,
    com_compensate: true,
    com_x: comX,
    com_y: comY,
    com_z: -0.05,
    comX: comX,
    comY: comY,
    comZ: -0.05,
    thrusters,
    description:
      "Asymmetric cardinal: strong port, weak stbd, fwd off-centerline, CoM offset.",
  };
  for (const t of control.thrusters) syncWrenchFromFacing(t, control);
  return control;
}

/**
 * Weird non-rectangle mounts: diagonal bow, far port lever, close starboard,
 * skewed aft — different lever arms, not a neat box.
 */
export function fixtureWeirdPositions(opts = {}) {
  const comY = opts.comY ?? 0.2;
  const comX = opts.comX ?? 0.1;
  const thrusters = [
    {
      name: "diag_bow",
      kind: "motor",
      max_rpm: 24,
      facing: "forward",
      role: "forward",
      max_force: 0.85,
      lx: 0.95,
      ly: -0.55,
      lz: -0.05,
    },
    {
      name: "far_port",
      kind: "motor",
      max_rpm: 24,
      facing: "left",
      role: "left",
      max_force: 0.7,
      lx: -0.2,
      ly: -1.2,
      lz: -0.05,
    },
    {
      name: "close_stbd",
      kind: "motor",
      max_rpm: 24,
      facing: "right",
      role: "right",
      max_force: 0.55,
      lx: 0.15,
      ly: 0.25,
      lz: -0.05,
    },
    {
      name: "aft_skew",
      kind: "motor",
      max_rpm: 24,
      facing: "back",
      role: "back",
      max_force: 0.65,
      lx: -1.1,
      ly: 0.15,
      lz: -0.05,
    },
  ].map((t) => withMag(syncWrenchFromFacing(t)));

  const control = {
    version: 6,
    mode: "wrench",
    alloc_mode: "reassembly",
    default_motor_rpm: 24,
    gains: { norm: 1 },
    yaw_sign: 1,
    com_compensate: true,
    com_x: comX,
    com_y: comY,
    com_z: -0.05,
    comX: comX,
    comY: comY,
    comZ: -0.05,
    thrusters,
    description: "Weird thruster positions (diagonal / unequal levers).",
  };
  for (const t of control.thrusters) syncWrenchFromFacing(t, control);
  return control;
}

/**
 * Missing/mirrored faces: 1 forward + uneven L/R strengths + single back.
 * CoM offset port or starboard.
 */
export function fixtureMissingMirroredFaces(opts = {}) {
  const comY = opts.comY ?? 0.3;
  const comX = opts.comX ?? -0.1;
  const thrusters = [
    {
      name: "only_fwd",
      kind: "motor",
      max_rpm: 24,
      facing: "forward",
      role: "forward",
      max_force: 1.0,
      lx: -0.8,
      ly: 0.1,
      lz: -0.05,
    },
    {
      name: "port_strong",
      kind: "motor",
      max_rpm: 24,
      facing: "left",
      role: "left",
      max_force: 0.95,
      lx: 0.4,
      ly: -0.8,
      lz: -0.05,
    },
    {
      name: "stbd_weak",
      kind: "motor",
      max_rpm: 24,
      facing: "right",
      role: "right",
      max_force: 0.3,
      lx: 0.5,
      ly: 0.6,
      lz: -0.05,
    },
    {
      name: "one_back",
      kind: "motor",
      max_rpm: 24,
      facing: "back",
      role: "back",
      max_force: 0.5,
      lx: -0.6,
      ly: -0.3,
      lz: -0.05,
    },
  ].map((t) => withMag(syncWrenchFromFacing(t)));

  const control = {
    version: 6,
    mode: "wrench",
    alloc_mode: "reassembly",
    default_motor_rpm: 24,
    gains: { norm: 1 },
    yaw_sign: 1,
    com_compensate: true,
    com_x: comX,
    com_y: comY,
    com_z: -0.05,
    comX: comX,
    comY: comY,
    comZ: -0.05,
    thrusters,
    description: "Missing/mirrored faces: 1 fwd + uneven L/R + one back.",
  };
  for (const t of control.thrusters) syncWrenchFromFacing(t, control);
  return control;
}

/**
 * Off-center mass combined with asymmetric thrust strengths / positions.
 */
export function fixtureOffCenterMassAsym(opts = {}) {
  return fixtureAsymmetricCardinal({
    comX: opts.comX ?? -0.2,
    comY: opts.comY ?? -0.35,
  });
}

/**
 * Seeded pseudo-random weird layout (deterministic). Always has ≥1 forward.
 * @param {number} [seed]
 */
export function fixtureSeededWeird(seed = 42) {
  let s = (seed >>> 0) || 1;
  const rnd = () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 0x100000000;
  };
  const faces = ["forward", "left", "right", "back", "forward"];
  const thrusters = faces.map((facing, i) => {
    const max_force = 0.35 + rnd() * 0.9;
    const lx = (rnd() - 0.5) * 2.2;
    const ly = (rnd() - 0.5) * 2.0;
    return withMag(
      syncWrenchFromFacing({
        name: `rand_${i}_${facing}`,
        kind: "motor",
        max_rpm: 24,
        facing,
        role: facing,
        max_force,
        lx,
        ly,
        lz: -0.05,
      }),
    );
  });
  const comX = (rnd() - 0.5) * 0.5;
  const comY = (rnd() - 0.5) * 0.6;
  const control = {
    version: 6,
    mode: "wrench",
    alloc_mode: "reassembly",
    default_motor_rpm: 24,
    gains: { norm: 1 },
    yaw_sign: 1,
    com_compensate: true,
    com_x: comX,
    com_y: comY,
    com_z: -0.05,
    comX,
    comY,
    comZ: -0.05,
    thrusters,
    description: `Seeded weird layout (seed=${seed}).`,
  };
  for (const t of control.thrusters) syncWrenchFromFacing(t, control);
  return control;
}

export const FIXTURES = {
  cardinal_5_boat: fixtureCardinal5Boat,
  cardinal_5_sized: fixtureCardinal5Sized,
  cardinal_6_plus: fixtureCardinal6Plus,
  cardinal_5_com_stbd: () => fixtureCardinal5OffsetCom({ comY: 0.35 }),
  cardinal_5_com_port: () => fixtureCardinal5OffsetCom({ comY: -0.35 }),
  cardinal_5_com_aft: () => fixtureCardinal5OffsetCom({ comX: -0.25, comY: 0.2 }),
  lua_like_cardinal5: () => fixtureLuaLikeCardinal5(),
  symmetric_surge: fixtureSymmetricSurge,
  near_com_strafe: fixtureSymmetricStrafeNearCom,
  asymmetric_near_com: fixtureAsymmetricNearCom,
  asymmetric_cardinal: () => fixtureAsymmetricCardinal(),
  weird_positions: () => fixtureWeirdPositions(),
  missing_mirrored_faces: () => fixtureMissingMirroredFaces(),
  offcenter_mass_asym: () => fixtureOffCenterMassAsym(),
  seeded_weird_42: () => fixtureSeededWeird(42),
  seeded_weird_99: () => fixtureSeededWeird(99),
};

export const DEFAULT_FIXTURE = "cardinal_5_boat";

export function loadFixture(name) {
  const fn = FIXTURES[name];
  if (!fn) throw new Error(`Unknown fixture: ${name}`);
  // Deep-ish clone so heal/mutate in tests doesn't poison other cases
  const data = JSON.parse(JSON.stringify(fn()));
  return enrichControl(data);
}

/** Parse a boat_control-like JSON string (or object). */
export function controlFromJson(json) {
  const data = typeof json === "string" ? JSON.parse(json) : json;
  if (!data.thrusters || !Array.isArray(data.thrusters)) {
    throw new Error("boat_control requires thrusters[]");
  }
  for (const t of data.thrusters) {
    t.fx = Number(t.fx) || 0;
    t.fy = Number(t.fy) || 0;
    t.tz = Number(t.tz) || 0;
    t.kind = t.kind || "motor";
    t.max_rpm = t.max_rpm || data.default_motor_rpm || 24;
    if (t.lx == null) t.lx = 0;
    if (t.ly == null) t.ly = (thrusterSideHint(t) || 0) * 0.4;
    if (t.lz == null) t.lz = 0;
    t.fz = Number(t.fz) || 0;
    t.tx = Number(t.tx) || 0;
    t.ty = Number(t.ty) || 0;
    if (t.max_force == null && t.strength != null) t.max_force = Number(t.strength);
    if (t.facing == null && t.role != null) t.facing = t.role;
    if (t.facing == null && (Math.abs(t.fx) > 1e-6 || Math.abs(t.fy) > 1e-6)) {
      t.facing = classifyFacingFromWrench(t);
    }
    if (t.angleRad == null) {
      const dir = facingToDir(t.facing);
      if (dir) {
        t.angleRad = Math.atan2(dir.y, dir.x);
      } else if (Math.abs(t.fy) >= Math.abs(t.fx)) {
        t.angleRad = t.fy >= 0 ? Math.PI / 2 : -Math.PI / 2;
      } else {
        t.angleRad = t.fx >= 0 ? 0 : Math.PI;
      }
    }
    t.mag =
      t.mag ||
      Math.sqrt(t.fx * t.fx + t.fy * t.fy + t.tz * t.tz);
  }
  data.version = data.version || 2;
  data.mode = data.mode || "wrench";
  return enrichControl(data);
}

function thrusterSideHint(t) {
  if (t.side_score != null) return Number(t.side_score);
  if (Math.abs(t.fy || 0) >= 0.02) return t.fy;
  return 0;
}

export function sampleBoatControlJson() {
  return JSON.stringify(fixtureCardinal5Boat(), null, 2);
}
