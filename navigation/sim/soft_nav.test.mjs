/**
 * Offline unit tests for soft-arrive / gentle cruise / water-hold routing.
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
  cruiseSurgeBias,
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

describe("gentle authority / pulse band", () => {
  it("arrived within tol → zero auth", () => {
    const a = softAuthority({ dist: 19, tolPos: 20, maxRpm: 24 });
    assert.equal(a.arrived, true);
    assert.equal(a.auth, 0);
  });

  it("cruise far out uses usable but capped auth (beats old ~13–14 RPM stall)", () => {
    const a = softAuthority({ dist: 120, mode: "cruise", maxRpm: 24 });
    assert.equal(a.arrived, false);
    // On 24-RPM boats need ≥~0.7 so surge ≈17–19 RPM can beat Create drag.
    assert.ok(a.auth >= 0.7, `auth=${a.auth}`);
    assert.ok(a.auth <= SOFT_NAV.authCeil + 1e-9, `auth=${a.auth}`);
    assert.ok(a.yawAuth < a.auth, "yaw authority below surge");
    assert.ok(a.yawAuth <= 0.2);
    assert.equal(a.pulsing, false);
  });

  it("high-max motors still soft-cap near ~36 RPM equivalent", () => {
    const a = softAuthority({ dist: 120, mode: "cruise", maxRpm: 96 });
    assert.ok(Math.abs(a.auth - 36 / 96) < 1e-9, `auth=${a.auth}`);
  });

  it("mid/creep bands taper authority", () => {
    const far = softAuthority({ dist: 100, maxRpm: 96 });
    const mid = softAuthority({ dist: 50, maxRpm: 96 });
    const near = softAuthority({ dist: 25, maxRpm: 96 });
    assert.ok(far.auth > mid.auth, `far ${far.auth} vs mid ${mid.auth}`);
    assert.ok(mid.auth >= near.auth, `mid ${mid.auth} vs near ${near.auth}`);
  });

  it("pulse band only last ~4 beyond tol (not tol+18 stall zone)", () => {
    const at26 = softAuthority({ dist: 26, tolPos: 20, clock: 0.1 });
    assert.equal(at26.pulsing, false, "26 blocks should still be continuous creep");
    const at23 = softAuthority({ dist: 23, tolPos: 20, clock: 0.1 });
    assert.equal(at23.pulsing, true);
    const off = softAuthority({ dist: 23, tolPos: 20, clock: 0.7 });
    assert.equal(off.motorsOffPulse, true);
    const on = softAuthority({ dist: 23, tolPos: 20, clock: 0.2 });
    assert.equal(on.motorsOffPulse, false);
  });
});

describe("cruise surge bias (anti yaw-only spin)", () => {
  it("keeps ≥55% turnKeep and floors forward when pointed at target", () => {
    const auth = 0.5;
    const r = cruiseSurgeBias({
      errForward: 40,
      errRight: 10,
      dist: 80,
      auth,
      pulsing: false,
    });
    assert.ok(r.turnKeep >= 0.55);
    assert.ok(r.fwdCmd >= auth * 0.5, `fwdCmd=${r.fwdCmd} floor=${auth * 0.5}`);
  });

  it("still thrusts when bearing is large (no zero-fx spin)", () => {
    const r = cruiseSurgeBias({
      errForward: 5,
      errRight: 60,
      dist: 70,
      auth: 0.45,
      pulsing: false,
    });
    assert.ok(r.fwdCmd > 0.1, `fwdCmd=${r.fwdCmd}`);
    assert.ok(r.turnKeep >= 0.55);
  });
});

describe("followPath waypoint soft advance", () => {
  const wps = [
    { x: 0, z: 0 },
    { x: 10, z: 0 },
    { x: 30, z: 0 },
    { x: 80, z: 0 },
  ];

  it("skips waypoints already inside soft arrive", () => {
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
    // Soft arrive of hold must not reach shore landmark.
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
    // Mid-corridor between shores is closer to both holds than shores are to each other.
    const mid = {
      x: (SOFT_NAV.shoreA.x + SOFT_NAV.shoreB.x) / 2,
      z: (SOFT_NAV.shoreA.z + SOFT_NAV.shoreB.z) / 2,
    };
    assert.ok(horizDist(a, mid) < horizDist(SOFT_NAV.shoreA, mid));
    assert.ok(horizDist(b, mid) < horizDist(SOFT_NAV.shoreB, mid));
  });
});
