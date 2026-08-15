import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  applyTeleop,
  applyReassembly,
  commandFromKeys,
  thrusterSide,
  syncWrenchFromFacing,
  classifyFacingFromWrench,
} from "./allocation.mjs";
import { loadFixture, DEFAULT_FIXTURE } from "./fixtures.mjs";
import { wrenchFromDuties, geometricFromDuties } from "./physics.mjs";

const SCALE1 = { wrenchForceScale: 1, wrenchTorqueScale: 1 };
const GEOM1 = { geometricForceScale: 1 };

describe("default fixture", () => {
  it("is the cardinal 5-thruster boat", () => {
    assert.equal(DEFAULT_FIXTURE, "cardinal_5_boat");
    const control = loadFixture(DEFAULT_FIXTURE);
    assert.equal(control.thrusters.length, 5);
    const facings = control.thrusters.map((t) => t.facing);
    assert.ok(facings.includes("forward"));
    assert.ok(facings.includes("left"));
    assert.ok(facings.includes("right"));
    assert.ok(facings.includes("back"));
  });
});

describe("applyTeleop idle", () => {
  it("zeros all duties when command is ~0", () => {
    const control = loadFixture("near_com_strafe");
    const r = applyTeleop(control, 0, 0, 0);
    assert.equal(r.ok, true);
    assert.equal(r.branch, "idle");
    assert.deepEqual(r.duties, [0, 0, 0, 0]);
  });
});

describe("applyTeleop pure surge (W)", () => {
  it("uses equal push on strafe-labeled near-CoM set (weak fx)", () => {
    const control = loadFixture("near_com_strafe");
    const r = applyTeleop(control, 1, 0, 0);
    assert.equal(r.ok, true);
    assert.equal(r.branch, "pure_surge");
    assert.equal(r.useEqual, true);
    const d0 = r.duties[0];
    assert.ok(Math.abs(d0) > 0.08, "surge duty should be on");
    for (const d of r.duties) assert.equal(d, d0);
  });

  it("does not invent net yaw torque under equal surge duties (symmetric calib)", () => {
    const control = loadFixture("near_com_strafe");
    const r = applyTeleop(control, 1, 0, 0);
    const { Tz } = wrenchFromDuties(control.thrusters, r.duties, SCALE1);
    assert.ok(Math.abs(Tz) < 1e-9, `net Tz should be ~0, got ${Tz}`);
  });

  it("S reverse mirrors W duties", () => {
    const control = loadFixture("near_com_strafe");
    const fwd = applyTeleop(control, 1, 0, 0);
    const rev = applyTeleop(control, -1, 0, 0);
    assert.equal(fwd.duties.length, rev.duties.length);
    for (let i = 0; i < fwd.duties.length; i++) {
      assert.equal(rev.duties[i], -fwd.duties[i]);
    }
  });

  it("projects onto fx when surge wrenches are strong", () => {
    const control = loadFixture("symmetric_surge");
    const r = applyTeleop(control, 1, 0, 0);
    assert.equal(r.branch, "pure_surge");
    assert.equal(r.useEqual, false);
    assert.ok(r.duties.every((d) => d > 0));
  });
});

describe("applyTeleop pure yaw (A/D)", () => {
  it("A produces differential duties by side", () => {
    const control = loadFixture("near_com_strafe");
    const r = applyTeleop(control, 0, 0, 1);
    assert.equal(r.ok, true);
    assert.equal(r.branch, "pure_yaw");
    const sides = control.thrusters.map(thrusterSide);
    const portDuties = r.duties.filter((_, i) => sides[i] < 0);
    const stbdDuties = r.duties.filter((_, i) => sides[i] > 0);
    assert.ok(portDuties.length >= 1 && stbdDuties.length >= 1);
    const portSign = Math.sign(portDuties[0]);
    const stbdSign = Math.sign(stbdDuties[0]);
    assert.ok(portSign !== 0 && stbdSign !== 0);
    assert.equal(portSign, -stbdSign);
  });

  it("D is opposite of A", () => {
    const control = loadFixture("near_com_strafe");
    const left = applyTeleop(control, 0, 0, 1);
    const right = applyTeleop(control, 0, 0, -1);
    for (let i = 0; i < left.duties.length; i++) {
      assert.equal(right.duties[i], -left.duties[i]);
    }
  });

  it("yaw differential produces nonzero net Tz", () => {
    const control = loadFixture("near_com_strafe");
    const r = applyTeleop(control, 0, 0, 1);
    assert.ok(r.duties.some((d) => Math.abs(d) > 0.08));
    const surge = loadFixture("symmetric_surge");
    const r2 = applyTeleop(surge, 0, 0, 1);
    const w2 = wrenchFromDuties(surge.thrusters, r2.duties, SCALE1);
    assert.ok(Math.abs(w2.Tz) > 0.01, `expected yaw torque, got ${w2.Tz}`);
  });
});

describe("applyTeleop strafe and chords", () => {
  it("pure C strafe uses fy projection", () => {
    const control = loadFixture("near_com_strafe");
    const r = applyTeleop(control, 0, 1, 0);
    assert.equal(r.branch, "pure_strafe");
    assert.equal(r.useEqual, false);
    assert.ok(r.duties.some((d) => d > 0));
    assert.ok(r.duties.some((d) => d < 0));
  });

  it("W+A chord is not pure_surge", () => {
    const control = loadFixture("near_com_strafe");
    const r = applyTeleop(control, 1, 0, 1);
    assert.equal(r.branch, "chord");
    assert.ok(r.duties.some((d) => Math.abs(d) > 0.08));
  });
});

describe("commandFromKeys", () => {
  it("maps W/S A/D Z/C like manualLoop", () => {
    assert.deepEqual(commandFromKeys({ w: true }), { fx: 1, fy: 0, tz: 0 });
    assert.deepEqual(commandFromKeys({ s: true }), { fx: -1, fy: 0, tz: 0 });
    assert.deepEqual(commandFromKeys({ a: true }), { fx: 0, fy: 0, tz: 1 });
    assert.deepEqual(commandFromKeys({ d: true }), { fx: 0, fy: 0, tz: -1 });
    assert.deepEqual(commandFromKeys({ c: true }), { fx: 0, fy: 1, tz: 0 });
    assert.deepEqual(commandFromKeys({ z: true }), { fx: 0, fy: -1, tz: 0 });
  });
});

describe("applyReassembly vs teleop on asymmetric set", () => {
  it("both return finite duties for pure W", () => {
    const control = loadFixture("asymmetric_near_com");
    const tele = applyTeleop(control, 1, 0, 0);
    const reass = applyReassembly(control, 1, 0, 0);
    assert.equal(tele.ok, true);
    assert.equal(reass.ok, true);
    assert.equal(tele.branch, "pure_surge");
    assert.equal(reass.branch, "reassembly");
    assert.ok(tele.duties.every((d) => Number.isFinite(d)));
    assert.ok(reass.duties.every((d) => Number.isFinite(d)));
  });
});

/**
 * Primary path — cardinal_5_boat encodes the user's real layout.
 * Geometric wrench (facing×strength, τ=r×F) feeds Reassembly LS.
 */
describe("cardinal_5 Reassembly forward / back / strafe / rotate", () => {
  it("W (+fx): primary forward + helpers → +Fx, Tz≈0", () => {
    const control = loadFixture("cardinal_5_boat");
    const r = applyReassembly(control, 1, 0, 0);
    assert.equal(r.ok, true);
    assert.equal(r.branch, "reassembly");
    assert.ok(r.duties.every((d) => Number.isFinite(d)));
    const w = wrenchFromDuties(control.thrusters, r.duties, SCALE1);
    assert.ok(w.Fx > 0.05, `expected +Fx, got ${w.Fx}`);
    assert.ok(
      Math.abs(w.Tz) < Math.abs(w.Fx) * 0.25 + 0.05,
      `yaw should be small vs surge: Fx=${w.Fx} Tz=${w.Tz}`,
    );
    // Main forward thruster should be contributing positively
    const mainIdx = control.thrusters.findIndex((t) => t.facing === "forward");
    assert.ok(mainIdx >= 0);
    assert.ok(
      r.duties[mainIdx] > 0.05,
      `main forward duty should be on, got ${r.duties[mainIdx]}`,
    );
  });

  it("S (-fx): back-facing thrusters → −Fx", () => {
    const control = loadFixture("cardinal_5_boat");
    const fwd = applyReassembly(control, 1, 0, 0);
    const rev = applyReassembly(control, -1, 0, 0);
    const wf = wrenchFromDuties(control.thrusters, fwd.duties, SCALE1);
    const wr = wrenchFromDuties(control.thrusters, rev.duties, SCALE1);
    assert.ok(wf.Fx > 0.05);
    assert.ok(wr.Fx < -0.05);
    assert.ok(Math.sign(wr.Fx) === -Math.sign(wf.Fx));
    const backDuties = rev.duties.filter(
      (_, i) => control.thrusters[i].facing === "back",
    );
    assert.ok(
      backDuties.some((d) => d > 0.05),
      "S should drive back-facing thrusters with +duty",
    );
  });

  it("strafe (+fy / C): left/right-facing → +Fy, yaw bounded", () => {
    const control = loadFixture("cardinal_5_boat");
    const r = applyReassembly(control, 0, 1, 0);
    assert.equal(r.ok, true);
    const w = wrenchFromDuties(control.thrusters, r.duties, SCALE1);
    assert.ok(w.Fy > 0.01, `expected +Fy, got ${w.Fy}`);
    assert.ok(
      Math.abs(w.Tz) < Math.abs(w.Fy) * 2.5 + 0.2,
      `yaw bounded vs strafe: Fy=${w.Fy} Tz=${w.Tz}`,
    );
  });

  it("strafe (-fy / Z): opposite lateral force", () => {
    const control = loadFixture("cardinal_5_boat");
    const pos = applyReassembly(control, 0, 1, 0);
    const neg = applyReassembly(control, 0, -1, 0);
    const wp = wrenchFromDuties(control.thrusters, pos.duties, SCALE1);
    const wn = wrenchFromDuties(control.thrusters, neg.duties, SCALE1);
    assert.ok(wp.Fy > 0.01);
    assert.ok(wn.Fy < -0.01);
  });

  it("rotate A (+tz): differential angle thrusters → +Tz", () => {
    const control = loadFixture("cardinal_5_boat");
    const r = applyReassembly(control, 0, 0, 1);
    assert.equal(r.ok, true);
    const w = wrenchFromDuties(control.thrusters, r.duties, SCALE1);
    assert.ok(w.Tz > 0.02, `expected +Tz, got ${w.Tz}`);
    const angleOn = r.duties.filter((d, i) => {
      const f = control.thrusters[i].facing;
      return f !== "forward" && Math.abs(d) > 0.08;
    });
    assert.ok(
      angleOn.length >= 2,
      "yaw should use multiple maneuver thrusters",
    );
  });

  it("rotate D (-tz): opposite yaw of A", () => {
    const control = loadFixture("cardinal_5_boat");
    const left = applyReassembly(control, 0, 0, 1);
    const right = applyReassembly(control, 0, 0, -1);
    const wl = wrenchFromDuties(control.thrusters, left.duties, SCALE1);
    const wr = wrenchFromDuties(control.thrusters, right.duties, SCALE1);
    assert.ok(wl.Tz > 0.02);
    assert.ok(wr.Tz < -0.02);
  });

  it("idle zeros all 5 duties", () => {
    const control = loadFixture("cardinal_5_boat");
    const r = applyReassembly(control, 0, 0, 0);
    assert.equal(r.ok, true);
    assert.equal(r.branch, "idle");
    assert.equal(r.duties.length, 5);
    assert.ok(r.duties.every((d) => d === 0));
  });

  it("geometric duties match wrench sync (facing×strength)", () => {
    const control = loadFixture("cardinal_5_boat");
    const duties = [1, 0, 0, 0, 0];
    const w = wrenchFromDuties(control.thrusters, duties, SCALE1);
    const g = geometricFromDuties(control.thrusters, duties, GEOM1);
    assert.ok(Math.abs(w.Fx - g.Fx) < 1e-9);
    assert.ok(Math.abs(w.Fy - g.Fy) < 1e-9);
    assert.ok(Math.abs(w.Tz - g.Tz) < 1e-9);
  });
});

describe("applyReassembly on legacy symmetric_surge", () => {
  it("W / S / strafe / yaw signs still hold", () => {
    const control = loadFixture("symmetric_surge");
    const w = applyReassembly(control, 1, 0, 0);
    const s = applyReassembly(control, -1, 0, 0);
    assert.ok(wrenchFromDuties(control.thrusters, w.duties, SCALE1).Fx > 0.05);
    assert.ok(wrenchFromDuties(control.thrusters, s.duties, SCALE1).Fx < -0.05);
  });
});

describe("scalability smoke", () => {
  it("6+ thrusters allocate without NaN and respond to W/yaw", () => {
    const control = loadFixture("cardinal_6_plus");
    assert.ok(control.thrusters.length >= 6);
    const surge = applyReassembly(control, 1, 0, 0);
    const yaw = applyReassembly(control, 0, 0, 1);
    assert.equal(surge.ok, true);
    assert.equal(yaw.ok, true);
    assert.ok(surge.duties.every((d) => Number.isFinite(d)));
    assert.ok(yaw.duties.every((d) => Number.isFinite(d)));
    const ws = wrenchFromDuties(control.thrusters, surge.duties, SCALE1);
    const wy = wrenchFromDuties(control.thrusters, yaw.duties, SCALE1);
    assert.ok(ws.Fx > 0.05);
    assert.ok(wy.Tz > 0.02);
  });

  it("varied sizes still allocate and respond to W/yaw", () => {
    const control = loadFixture("cardinal_5_sized");
    const forces = control.thrusters.map((t) => t.max_force);
    assert.ok(new Set(forces).size > 1, "fixture should vary max_force");
    const surge = applyReassembly(control, 1, 0, 0);
    const yaw = applyReassembly(control, 0, 0, 1);
    assert.ok(surge.duties.every((d) => Number.isFinite(d)));
    assert.ok(yaw.duties.every((d) => Number.isFinite(d)));
    assert.ok(wrenchFromDuties(control.thrusters, surge.duties, SCALE1).Fx > 0.05);
    assert.ok(wrenchFromDuties(control.thrusters, yaw.duties, SCALE1).Tz > 0.02);
  });
});

describe("facing helpers", () => {
  it("classifyFacingFromWrench picks dominant axis", () => {
    assert.equal(classifyFacingFromWrench({ fx: 0.8, fy: 0.1 }), "forward");
    assert.equal(classifyFacingFromWrench({ fx: -0.6, fy: 0.05 }), "back");
    assert.equal(classifyFacingFromWrench({ fx: 0.05, fy: 0.7 }), "right");
    assert.equal(classifyFacingFromWrench({ fx: 0.05, fy: -0.7 }), "left");
  });

  it("syncWrenchFromFacing sets τ = r × F", () => {
    const t = syncWrenchFromFacing({
      facing: "forward",
      max_force: 2,
      lx: 0,
      ly: 1,
      lz: 0,
    });
    assert.equal(t.fx, 2);
    assert.equal(t.fy, 0);
    assert.ok(Math.abs(t.tz - -2) < 1e-9); // −ly·fx
  });
});
