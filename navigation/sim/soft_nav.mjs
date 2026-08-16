/**
 * Pure port of soft-arrive / dumb cruise math from navigation/lib/drive.lua
 * (drive.stepToward + drive.followPath waypoint advance). No peripherals.
 *
 * Keep in sync with Lua when changing RPM caps or cruise yaw/surge rules.
 */

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v));
}

/** Soft arrive distance: Lua clamps to 15–25, default 20. */
export function clampSoftArrive(raw, fallback = 20) {
  let soft = Number(raw);
  if (!Number.isFinite(soft)) soft = fallback;
  if (soft < 15) soft = 20;
  if (soft > 25) soft = 25;
  return soft;
}

/** Soft tol / dock floor in stepToward (Lua floors <16 → 20). */
export function clampTolPos(raw, fallback = 20) {
  let tol = Number(raw);
  if (!Number.isFinite(tol)) tol = fallback;
  if (tol < 16) tol = 20;
  return tol;
}

export const SOFT_NAV = {
  softArrive: 20,
  waterStandoff: 28,
  cruiseRpmCap: 36,
  midRpmCap: 28,
  creepRpmCap: 18,
  pulseRpmCap: 10,
  /** Max wrench fraction (0.78 ≈ 19 RPM on a 24-RPM boat). */
  authCeil: 0.78,
  /** Pulse only in dock/creep last N blocks beyond tol — never on cruise. */
  pulseBand: 4,
  /** Look-ahead when current WP within softArrive + this. */
  lookAheadExtra: 16,
  yawOnlyDeg: 35,
  yawDeadbandDeg: 12,
  shoreA: { x: 341, z: 163 },
  shoreB: { x: 383, z: 285 },
};

const YAW_ONLY_RAD = (SOFT_NAV.yawOnlyDeg * Math.PI) / 180;
const YAW_DEAD_RAD = (SOFT_NAV.yawDeadbandDeg * Math.PI) / 180;

/**
 * Authority fraction from soft RPM caps (mirrors drive.stepToward).
 * Cruise never enters the soft-arrive pulse band.
 * @returns {{ auth: number, yawAuth: number, pulsing: boolean, arrived: boolean, motorsOffPulse: boolean }}
 */
export function softAuthority({
  dist,
  mode = "cruise",
  tolPos = 20,
  maxRpm = 24,
  clock = 0,
} = {}) {
  const tol = clampTolPos(tolPos);
  if (dist <= tol) {
    return {
      auth: 0,
      yawAuth: 0,
      pulsing: false,
      arrived: true,
      motorsOffPulse: false,
    };
  }

  const rpmAuth = (rpmCap) => rpmCap / Math.max(1, maxRpm);
  let auth = Math.min(SOFT_NAV.authCeil, rpmAuth(SOFT_NAV.cruiseRpmCap));
  if (mode === "creep" || mode === "dock") {
    auth = Math.min(auth, rpmAuth(SOFT_NAV.creepRpmCap));
  }
  if (dist <= 28) {
    auth = Math.min(auth, rpmAuth(SOFT_NAV.creepRpmCap));
  } else if (dist <= 55) {
    auth = Math.min(auth, rpmAuth(SOFT_NAV.midRpmCap));
  } else if (dist <= 90) {
    auth = Math.min(auth, rpmAuth(SOFT_NAV.cruiseRpmCap));
  }

  let pulsing = false;
  let motorsOffPulse = false;
  // Pulse only for dock/creep near hold — cruise stays continuous.
  if ((mode === "dock" || mode === "creep") && dist <= tol + SOFT_NAV.pulseBand) {
    auth = Math.min(auth, rpmAuth(SOFT_NAV.pulseRpmCap));
    pulsing = true;
    const phase = ((Number(clock) % 1) + 1) % 1;
    if (phase > 0.55) motorsOffPulse = true;
  }

  const yawAuth =
    mode === "cruise"
      ? Math.min(auth * 0.4, 0.16)
      : Math.min(auth * 0.55, 0.2);
  return { auth, yawAuth, pulsing, arrived: false, motorsOffPulse };
}

/**
 * Dumb cruise: |bearing| > 35° → yaw only; 12–35° → fx=0.55 + small yaw;
 * else fx=0.75, tz=0. Never reverse. fy unused.
 */
export function cruiseCommand({
  errForward = 0,
  errRight = 0,
  auth = 0.78,
} = {}) {
  const bearing = Math.atan2(errRight, errForward !== 0 ? errForward : 0.01);
  const absB = Math.abs(bearing);
  const gentleYaw = Math.min(auth * 0.35, 0.14);
  const smallYaw = Math.min(auth * 0.22, 0.08);
  const sgn = bearing >= 0 ? 1 : -1;
  let fwdCmd = 0;
  let yawCmd = 0;
  let yawOnly = false;

  if (absB > YAW_ONLY_RAD) {
    yawOnly = true;
    fwdCmd = 0;
    yawCmd = sgn * gentleYaw;
  } else if (absB > YAW_DEAD_RAD) {
    fwdCmd = Math.min(0.55, auth);
    yawCmd = sgn * smallYaw;
  } else {
    fwdCmd = Math.min(0.75, auth);
    yawCmd = 0;
  }
  fwdCmd = Math.max(0, fwdCmd);
  return {
    bearing,
    fwdCmd,
    yawCmd,
    yawOnly,
    yawAuth: gentleYaw,
    aligned: absB <= YAW_DEAD_RAD,
  };
}

/** @deprecated Use cruiseCommand — kept as thin alias for older imports. */
export function cruiseSurgeBias(opts = {}) {
  const r = cruiseCommand(opts);
  return {
    bearing: r.bearing,
    distScale: 1,
    turnKeep: r.yawOnly ? 0 : 1,
    fwdCmd: r.fwdCmd,
  };
}

/** Horiz distance in XZ. */
export function horizDist(a, b) {
  const dx = (a.x ?? 0) - (b.x ?? 0);
  const dz = (a.z ?? 0) - (b.z ?? 0);
  return Math.sqrt(dx * dx + dz * dz);
}

/**
 * Skip waypoints already inside soft arrive (don't orbit one WP).
 * Mirrors followPath advance loops.
 */
export function advanceWaypointIndex(waypoints, craft, startIndex = 0, arriveDist = 20) {
  const soft = clampSoftArrive(arriveDist);
  let i = Math.max(0, startIndex | 0);
  const n = waypoints?.length || 0;
  if (n === 0) return 0;
  while (i < n - 1 && horizDist(waypoints[i], craft) <= soft) {
    i += 1;
  }
  return i;
}

/**
 * Look-ahead when current WP is within softArrive+16.
 */
export function followPathTarget(waypoints, craft, index, arriveDist = 20, engage = 22) {
  const soft = clampSoftArrive(arriveDist);
  const n = waypoints.length;
  if (n === 0) return null;
  let i = advanceWaypointIndex(waypoints, craft, index, soft);
  const last = waypoints[n - 1];
  const distLast = horizDist(last, craft);
  if (distLast <= soft) {
    return { index: i, target: last, mode: "cruise", arrivedSoft: true, distLast };
  }
  let target = waypoints[Math.min(i, n - 1)];
  if (i < n - 1 && horizDist(target, craft) <= soft + SOFT_NAV.lookAheadExtra) {
    target = waypoints[Math.min(i + 1, n - 1)];
  }
  if (distLast <= engage || i >= n - 1) {
    target = last;
  }
  return { index: i, target, mode: "cruise", arrivedSoft: false, distLast };
}

/** Water hold: from shore toward partner by standoff (ports.holdOf). */
export function waterHold(shore, partner, standoff = SOFT_NAV.waterStandoff) {
  const dx = partner.x - shore.x;
  const dz = partner.z - shore.z;
  const yaw = Math.atan2(dx, dz);
  return {
    x: shore.x + Math.sin(yaw) * standoff,
    z: shore.z + Math.cos(yaw) * standoff,
    yaw,
    shore_x: shore.x,
    shore_z: shore.z,
  };
}

export function portHolds() {
  const a = waterHold(SOFT_NAV.shoreA, SOFT_NAV.shoreB);
  const b = waterHold(SOFT_NAV.shoreB, SOFT_NAV.shoreA);
  return { portA: a, portB: b };
}

/** Corridor waypoints between water holds (not shore landmarks). */
export function corridorWaypoints(fromHold, toHold, spacing = 16) {
  const dist = horizDist(fromHold, toHold);
  const n = Math.max(2, Math.floor(dist / spacing) + 1);
  const yaw = Math.atan2(toHold.x - fromHold.x, toHold.z - fromHold.z);
  const wps = [];
  for (let i = 0; i <= n; i++) {
    const t = i / n;
    wps.push({
      x: fromHold.x + (toHold.x - fromHold.x) * t,
      z: fromHold.z + (toHold.z - fromHold.z) * t,
      yaw,
      t: i,
    });
  }
  wps[wps.length - 1].x = toHold.x;
  wps[wps.length - 1].z = toHold.z;
  wps[wps.length - 1].yaw = toHold.yaw ?? yaw;
  return wps;
}
