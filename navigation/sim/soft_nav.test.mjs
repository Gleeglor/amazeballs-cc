/**
 * Offline unit tests for soft-arrive / dumb cruise / water-hold routing.
 * Mirrors navigation/lib/drive.lua + ports.lua invariants (no live boat).
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  SOFT_NAV,
  clampSoftArrive,
  clampTolPos,
  softAuthority,
  cruiseCommand,
  advanceWaypointIndex,
  followPathTarget,
  waterHold,
  portHolds,
  corridorWaypoints,
  horizDist,
} from "./soft_nav.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

describe("soft arrive clamps", () => {
  it("defaults and floors tiny arrives to 20", () => {
    assert.equal(clampSoftArrive(undefined), 20);
    assert.equal(clampSoftArrive(5), 20);
    assert.equal(clampSoftArrive(14.9), 20);
    assert.equal(clampTolPos(10), 20);
  });

  it("caps oversized arrive at 25", () => {
    assert.equal(clampSoftArrive(40), 25);
    assert.equal(clampSoftArrive(20), 20);
    assert.equal(clampSoftArrive(15), 15);
  });
});

describe("gentle authority / no cruise pulse", () => {
  it("arrived within tol → zero auth", () => {
    const a = softAuthority({ dist: 19, tolPos: 20, maxRpm: 24 });
    assert.equal(a.arrived, true);
    assert.equal(a.auth, 0);
  });

  it("cruise far out uses usable but capped auth", () => {
    const a = softAuthority({ dist: 120, mode: "cruise", maxRpm: 24 });
    assert.equal(a.arrived, false);
    assert.ok(a.auth >= 0.7, `auth=${a.auth}`);
    assert.ok(a.auth <= SOFT_NAV.authCeil + 1e-9, `auth=${a.auth}`);
    assert.equal(a.pulsing, false);
  });

  it("cruise near tol never pulses (no 0.2s blips)", () => {
    const a = softAuthority({
      dist: 23,
      mode: "cruise",
      tolPos: 20,
      maxRpm: 24,
      clock: 0.7,
    });
    assert.equal(a.pulsing, false);
    assert.equal(a.motorsOffPulse, false);
  });

  it("dock/creep may pulse only in last ~4 beyond tol", () => {
    const at26 = softAuthority({ dist: 26, mode: "creep", tolPos: 20, clock: 0.1 });
    assert.equal(at26.pulsing, false);
    const at23 = softAuthority({ dist: 23, mode: "creep", tolPos: 20, clock: 0.1 });
    assert.equal(at23.pulsing, true);
    const off = softAuthority({ dist: 23, mode: "dock", tolPos: 20, clock: 0.7 });
    assert.equal(off.motorsOffPulse, true);
  });
});

describe("dumb cruise rules (lock hunting fix)", () => {
  const auth = 0.78;

  it("aligned (|bearing|≤22°) → surge dominates, zero yaw, no reverse", () => {
    const r = cruiseCommand({ errForward: 50, errRight: 2, auth });
    assert.ok(r.aligned);
    // authCeil 0.78 caps fx below the 0.90 wish
    assert.ok(r.fwdCmd >= Math.min(0.9, auth) - 1e-9, `fwdCmd=${r.fwdCmd}`);
    assert.equal(r.yawCmd, 0);
    assert.ok(r.fwdCmd >= 0);
    assert.equal(r.yawOnly, false);
  });

  it("large bearing (>55°) → yaw-biased tiny surge, no reverse", () => {
    const r = cruiseCommand({ errForward: 5, errRight: 60, auth });
    assert.equal(r.yawOnly, true);
    assert.ok(r.fwdCmd > 0 && r.fwdCmd <= 0.18, `fwdCmd=${r.fwdCmd}`);
    assert.ok(r.yawCmd > 0, `yawCmd=${r.yawCmd}`);
    assert.ok(r.fwdCmd >= 0);
  });

  it("past waypoint (negative forward) never reverses — yaw-biased", () => {
    const r = cruiseCommand({ errForward: -40, errRight: 5, auth });
    assert.ok(r.fwdCmd >= 0, `fwdCmd=${r.fwdCmd}`);
    assert.ok(r.fwdCmd <= 0.18);
    assert.equal(r.yawOnly, true);
  });

  it("mid bearing (22–55°) → soft surge 0.70 + small yaw", () => {
    // atan2(30, 50) ≈ 31°
    const r = cruiseCommand({ errForward: 50, errRight: 30, auth });
    assert.equal(r.yawOnly, false);
    assert.ok(Math.abs(r.fwdCmd - 0.7) < 1e-9, `fwdCmd=${r.fwdCmd}`);
    assert.ok(r.yawCmd > 0 && r.yawCmd < 0.15, `yawCmd=${r.yawCmd}`);
  });
});

describe("followPath waypoint soft advance", () => {
  const wps = [
    { x: 0, z: 0 },
    { x: 10, z: 0 },
    { x: 30, z: 0 },
    { x: 80, z: 0 },
  ];

  it("skips waypoints already inside soft arrive (≤20)", () => {
    const i = advanceWaypointIndex(wps, { x: 5, z: 0 }, 0, 20);
    assert.equal(i, 2, `expected skip past 0 and 10, got ${i}`);
  });

  it("looks ahead and soft-arrives at final hold", () => {
    const mid = followPathTarget(wps, { x: 25, z: 0 }, 1, 20, 22);
    assert.equal(mid.arrivedSoft, false);
    assert.ok(mid.target.x >= 30);

    const nearEnd = followPathTarget(wps, { x: 75, z: 0 }, 2, 20, 22);
    assert.equal(nearEnd.arrivedSoft, true);
    assert.equal(nearEnd.target.x, 80);
  });
});

describe("water holds never seek shore", () => {
  it("holds sit ~standoff offshore toward partner", () => {
    const { portA, portB } = portHolds();
    assert.ok(horizDist(portA, SOFT_NAV.shoreA) > 20);
    assert.ok(horizDist(portB, SOFT_NAV.shoreB) > 20);
    assert.ok(
      Math.abs(horizDist(portA, SOFT_NAV.shoreA) - SOFT_NAV.waterStandoff) < 0.5,
    );
    assert.ok(horizDist(portA, SOFT_NAV.shoreA) > SOFT_NAV.softArrive);
    assert.ok(horizDist(portB, SOFT_NAV.shoreB) > SOFT_NAV.softArrive);
  });

  it("corridor waypoints stay on water holds, not shore coords", () => {
    const { portA, portB } = portHolds();
    const wps = corridorWaypoints(portA, portB, 16);
    for (const wp of wps) {
      assert.ok(horizDist(wp, SOFT_NAV.shoreA) > 15, JSON.stringify(wp));
      assert.ok(horizDist(wp, SOFT_NAV.shoreB) > 15, JSON.stringify(wp));
    }
    assert.ok(horizDist(wps[0], portA) < 0.01);
    assert.ok(horizDist(wps[wps.length - 1], portB) < 0.01);
  });

  it("shipped path JSON ends on water holds (not 341,163 / 383,285)", () => {
    const { portA, portB } = portHolds();
    for (const name of ["a_to_b", "b_to_a", "to_port_a", "to_port_b"]) {
      const data = JSON.parse(readFileSync(join(ROOT, "paths", `${name}.json`), "utf8"));
      const last = data.waypoints[data.waypoints.length - 1];
      const first = data.waypoints[0];
      assert.ok(horizDist(last, SOFT_NAV.shoreA) > 15, `${name} last near A shore`);
      assert.ok(horizDist(last, SOFT_NAV.shoreB) > 15, `${name} last near B shore`);
      assert.ok(
        horizDist(last, portA) < 1 || horizDist(last, portB) < 1,
        `${name} last should be a water hold`,
      );
      assert.ok(
        horizDist(first, portA) < 1 || horizDist(first, portB) < 1,
        `${name} first should be a water hold`,
      );
    }
  });
});

describe("waterHold helper matches ports.lua geometry", () => {
  it("A hold toward B / B hold toward A", () => {
    const a = waterHold(SOFT_NAV.shoreA, SOFT_NAV.shoreB, 28);
    const b = waterHold(SOFT_NAV.shoreB, SOFT_NAV.shoreA, 28);
    const mid = {
      x: (SOFT_NAV.shoreA.x + SOFT_NAV.shoreB.x) / 2,
      z: (SOFT_NAV.shoreA.z + SOFT_NAV.shoreB.z) / 2,
    };
    assert.ok(horizDist(a, mid) < horizDist(SOFT_NAV.shoreA, mid));
    assert.ok(horizDist(b, mid) < horizDist(SOFT_NAV.shoreB, mid));
  });
});
