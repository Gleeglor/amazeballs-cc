/**
 * Pure port of soft-arrive / gentle cruise math from navigation/lib/drive.lua
 * (drive.stepToward + drive.followPath waypoint advance). No peripherals.
 *
 * Keep in sync with Lua when changing RPM caps, pulse band, or surge bias.
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
  /** Max wrench fraction (0.78 ≈ 19 RPM on a 24-RPM boat; old 0.55 stalled). */
  authCeil: 0.78,
  /** Pulse only in last N blocks beyond tol (was tol+18 → stall). */
  pulseBand: 4,
  shoreA: { x: 341, z: 163 },
  shoreB: { x: 383, z: 285 },
};

/**
 * Authority fraction from soft RPM caps (mirrors drive.stepToward).
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
  if (dist <= tol + SOFT_NAV.pulseBand) {
    auth = Math.min(auth, rpmAuth(SOFT_NAV.pulseRpmCap));
    pulsing = true;
    const phase = ((Number(clock) % 1) + 1) % 1;
    if (phase > 0.55) motorsOffPulse = true;
  }

  const yawAuth = Math.min(auth * 0.55, 0.2);
  return { auth, yawAuth, pulsing, arrived: false, motorsOffPulse };
}

/**
 * Cruise surge bias: keep forward progress while yawing (anti yaw-only spin).
 * errForward/errRight are craft-frame target errors.
 */
export function cruiseSurgeBias({
  errForward = 0,
  errRight = 0,
  dist = 0,
  auth = 0.4,
  pulsing = false,
} = {}) {
  const bearing = Math.atan2(errRight, Math.max(0.01, errForward));
  const distScale = clamp(dist / 90, 0.4, 1.0);
  // Keep ≥55% surge while turning.
  const turnKeep = clamp(1.0 - Math.abs(bearing) / 2.2, 0.55, 1.0);
  let fwdCmd = Math.max(0.55 * distScale, distScale * 0.35) * turnKeep;
  fwdCmd = clamp(fwdCmd * auth, -auth, auth);

  // Floor forward when heading roughly toward target.
  if (!pulsing && errForward > 2) {
    const floor = auth * 0.5;
    if (fwdCmd < floor) fwdCmd = floor;
  }

  return { bearing, distScale, turnKeep, fwdCmd };
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
 * Look-ahead when current WP is within softArrive+8.
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
  if (i < n - 1 && horizDist(target, craft) <= soft + 8) {
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
