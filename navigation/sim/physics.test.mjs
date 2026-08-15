import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  createBody,
  defaultPhysicsParams,
  forcesFromDuties,
  geometricFromDuties,
  step,
  wrenchFromDuties,
} from "./physics.mjs";
import { applyReassembly, applyTeleop } from "./allocation.mjs";
import { loadFixture } from "./fixtures.mjs";

describe("physics forces", () => {
  it("scales calibrated wrench by duty", () => {
    const thrusters = [
      { fx: 1, fy: 0, tz: 0.5 },
      { fx: 0, fy: 1, tz: -0.5 },
    ];
    const { Fx, Fy, Tz } = wrenchFromDuties(thrusters, [1, -0.5], {
      wrenchForceScale: 10,
      wrenchTorqueScale: 4,
    });
    assert.equal(Fx, 10);
    assert.equal(Fy, -5);
    assert.equal(Tz, 4 * (0.5 + 0.25));
  });

  it("geometric mode uses lever arms (2D planar)", () => {
    const thrusters = [
      { lx: 0, ly: 1, angleRad: 0 }, // force +fwd at starboard → -tz
    ];
    const { Fx, Fy, Tz } = forcesFromDuties(thrusters, [1], {
      forceMode: "geometric",
      geometricForceScale: 10,
    });
    assert.ok(Math.abs(Fx - 10) < 1e-9);
    assert.ok(Math.abs(Fy) < 1e-9);
    assert.ok(Math.abs(Tz - -10) < 1e-9); // lx*fy - ly*fx = -1*10
  });

  it("geometric 3D torque is r × F", () => {
    // Force +Z at (1,0,0) → Ty = lz*fx - lx*fz = -1*10 = -10
    const thrusters = [{ lx: 1, ly: 0, lz: 0, dirX: 0, dirY: 0, dirZ: 1 }];
    const w = geometricFromDuties(thrusters, [1], {
      geometricForceScale: 10,
    });
    assert.ok(Math.abs(w.Fz - 10) < 1e-9);
    assert.ok(Math.abs(w.Ty - -10) < 1e-9);
    assert.ok(Math.abs(w.Tx) < 1e-9);
    assert.ok(Math.abs(w.Tz) < 1e-9);
  });
});

describe("physics integrator", () => {
  it("produces finite state under teleop surge", () => {
    const control = loadFixture("near_com_strafe");
    const { duties } = applyTeleop(control, 1, 0, 0);
    let body = createBody();
    const params = defaultPhysicsParams({ forceMode: "wrench" });
    for (let i = 0; i < 120; i++) {
      const r = step(body, control.thrusters, duties, params, 1 / 60);
      assert.equal(r.ok, true);
      body = r.body;
    }
    assert.ok(Number.isFinite(body.x));
    assert.ok(Number.isFinite(body.z));
    assert.ok(Number.isFinite(body.omega));
  });

  it("drag damps free motion to near-rest", () => {
    let body = createBody({ vx: 5, vy: -3, vz: 1, omega: 2, wx: 0.5, wy: -0.4 });
    const params = defaultPhysicsParams({
      linearDrag: 3,
      angularDrag: 4,
      verticalDrag: 6,
      waterSpring: 20,
    });
    const thrusters = loadFixture("near_com_strafe").thrusters;
    const duties = [0, 0, 0, 0];
    for (let i = 0; i < 300; i++) {
      const r = step(body, thrusters, duties, params, 1 / 60);
      assert.equal(r.ok, true);
      body = r.body;
    }
    assert.ok(
      Math.hypot(body.vx, body.vy, body.vz) < 0.08,
      `speed ${Math.hypot(body.vx, body.vy, body.vz)}`,
    );
    assert.ok(Math.abs(body.omega) < 0.05, `omega ${body.omega}`);
    assert.ok(Math.abs(body.z) < 0.2, `z ${body.z}`);
  });

  it("no NaNs with chord duties", () => {
    const control = loadFixture("asymmetric_near_com");
    const { duties } = applyTeleop(control, 1, 1, 1);
    let body = createBody();
    for (let i = 0; i < 60; i++) {
      const r = step(body, control.thrusters, duties, defaultPhysicsParams(), 0.02);
      assert.equal(r.ok, true);
      assert.ok(!Number.isNaN(r.forces.Fx));
      assert.ok(!Number.isNaN(r.forces.Fz));
      body = r.body;
    }
  });

  it("Reassembly W over time increases forward displacement", () => {
    const control = loadFixture("symmetric_surge");
    const { duties } = applyReassembly(control, 1, 0, 0);
    let body = createBody();
    const params = defaultPhysicsParams({ forceMode: "wrench", linearDrag: 0.4 });
    const y0 = body.y;
    for (let i = 0; i < 180; i++) {
      const r = step(body, control.thrusters, duties, params, 1 / 60);
      assert.equal(r.ok, true);
      body = r.body;
    }
    // yaw0 faces +Y: forward thrust → +y world
    assert.ok(body.y > y0 + 0.3, `expected +y displacement, y=${body.y}`);
  });

  it("Reassembly A over time increases yaw", () => {
    const control = loadFixture("symmetric_surge");
    const { duties } = applyReassembly(control, 0, 0, 1);
    let body = createBody();
    const params = defaultPhysicsParams({ forceMode: "wrench", angularDrag: 0.5 });
    const yaw0 = body.yaw;
    for (let i = 0; i < 180; i++) {
      const r = step(body, control.thrusters, duties, params, 1 / 60);
      assert.equal(r.ok, true);
      body = r.body;
    }
    assert.ok(body.yaw > yaw0 + 0.15, `expected +yaw, yaw=${body.yaw}`);
  });

  it("idle + drag damps after Reassembly burst", () => {
    const control = loadFixture("symmetric_surge");
    const { duties } = applyReassembly(control, 1, 0, 0);
    let body = createBody();
    const params = defaultPhysicsParams({
      forceMode: "wrench",
      linearDrag: 2.5,
      angularDrag: 3,
    });
    for (let i = 0; i < 60; i++) {
      body = step(body, control.thrusters, duties, params, 1 / 60).body;
    }
    const zero = [0, 0, 0, 0];
    for (let i = 0; i < 240; i++) {
      body = step(body, control.thrusters, zero, params, 1 / 60).body;
    }
    assert.ok(Math.hypot(body.vx, body.vy, body.vz) < 0.1);
    assert.ok(Math.abs(body.wz) < 0.1);
  });

  it("cardinal_5 Reassembly W increases forward displacement (geometric)", () => {
    const control = loadFixture("cardinal_5_boat");
    const { duties } = applyReassembly(control, 1, 0, 0);
    let body = createBody();
    const params = defaultPhysicsParams({
      forceMode: "geometric",
      linearDrag: 0.4,
      geometricForceScale: 40,
    });
    const y0 = body.y;
    for (let i = 0; i < 180; i++) {
      const r = step(body, control.thrusters, duties, params, 1 / 60);
      assert.equal(r.ok, true);
      body = r.body;
    }
    assert.ok(body.y > y0 + 0.3, `expected +y displacement, y=${body.y}`);
  });

  it("cardinal_5 Reassembly A increases yaw (geometric)", () => {
    const control = loadFixture("cardinal_5_boat");
    const { duties } = applyReassembly(control, 0, 0, 1);
    let body = createBody();
    const params = defaultPhysicsParams({
      forceMode: "geometric",
      angularDrag: 0.5,
      geometricForceScale: 40,
    });
    let yawUnwrapped = 0;
    let prevYaw = body.yaw;
    for (let i = 0; i < 90; i++) {
      const r = step(body, control.thrusters, duties, params, 1 / 60);
      assert.equal(r.ok, true);
      body = r.body;
      let dy = body.yaw - prevYaw;
      if (dy > Math.PI) dy -= 2 * Math.PI;
      if (dy < -Math.PI) dy += 2 * Math.PI;
      yawUnwrapped += dy;
      prevYaw = body.yaw;
    }
    assert.ok(yawUnwrapped > 0.15, `expected +yaw unwrapped, got ${yawUnwrapped}`);
    assert.ok(body.wz > 0, `expected +wz, got ${body.wz}`);
  });

  it("water plane keeps |z| small without vertical thrust", () => {
    let body = createBody({ z: 0.2, vz: 0.5 });
    const thrusters = loadFixture("symmetric_surge").thrusters;
    const params = defaultPhysicsParams({ waterSpring: 40, verticalDrag: 10 });
    for (let i = 0; i < 200; i++) {
      body = step(body, thrusters, [0, 0, 0, 0], params, 1 / 60).body;
    }
    assert.ok(Math.abs(body.z) < 0.15, `z=${body.z}`);
    assert.ok(Math.abs(body.vz) < 0.15, `vz=${body.vz}`);
  });
});
