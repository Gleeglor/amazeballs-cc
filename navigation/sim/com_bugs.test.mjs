/**
 * User-reported boat bugs + adversarial CoM / yaw / fallback cases.
 * Sign convention: +tz = CCW from above = A / craft-left turn.
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  applyCommand,
  applyCardinalRoles,
  applyReassembly,
  applyTeleop,
  commandFromKeys,
  netWrench,
  getYawSign,
  healYawThrusters,
  syncWrenchFromFacing,
} from "./allocation.mjs";
import {
  loadFixture,
  fixtureCardinal5OffsetCom,
  fixtureLuaLikeCardinal5,
} from "./fixtures.mjs";
import { geometricFromDuties, createBody, defaultPhysicsParams, step } from "./physics.mjs";

const GEOM = (comY = 0, comX = 0) => ({
  geometricForceScale: 1,
  comX,
  comY,
  comZ: 0,
});

function ratioTz(w) {
  const primary = Math.max(Math.abs(w.Fx), Math.abs(w.Fy), 1e-6);
  return Math.abs(w.Tz) / primary;
}

describe("sign convention: A = left (+tz = +Tz)", () => {
  it("commandFromKeys: A → +tz, D → −tz", () => {
    assert.deepEqual(commandFromKeys({ a: true }), { fx: 0, fy: 0, tz: 1 });
    assert.deepEqual(commandFromKeys({ d: true }), { fx: 0, fy: 0, tz: -1 });
  });

  it("cardinal_5 applyCommand A → +Tz, D mirrors", () => {
    const control = loadFixture("cardinal_5_boat");
    const a = applyCommand(control, 0, 0, 1);
    const d = applyCommand(JSON.parse(JSON.stringify(control)), 0, 0, -1);
    const wa = netWrench(control.thrusters, a.duties);
    const wd = netWrench(control.thrusters, d.duties);
    assert.ok(wa.Tz > 0.05, `A should yaw left (+Tz), got ${wa.Tz}`);
    assert.ok(wd.Tz < -0.05, `D should yaw right (−Tz), got ${wd.Tz}`);
    assert.ok(Math.abs(wa.Tz + wd.Tz) < 0.05, "A/D should be mirrors");
  });

  it("yaw_sign: −1 flips A/D", () => {
    const control = loadFixture("cardinal_5_boat");
    control.yaw_sign = -1;
    assert.equal(getYawSign(control), -1);
    const a = applyCommand(control, 0, 0, 1);
    const w = netWrench(control.thrusters, a.duties);
    assert.ok(w.Tz < -0.05, `yaw_sign=-1: A key should produce −Tz, got ${w.Tz}`);
  });

  it("healYawThrusters forward levers match τ=−ly·fx (A→+Tz)", () => {
    const control = {
      version: 6,
      mode: "wrench",
      thrusters: [
        {
          name: "pf",
          kind: "motor",
          facing: "forward",
          fx: 0.5,
          fy: 0,
          tz: 0,
          ly: -0.8,
          side_score: -1,
        },
        {
          name: "sf",
          kind: "motor",
          facing: "forward",
          fx: 0.5,
          fy: 0,
          tz: 0,
          ly: 0.8,
          side_score: 1,
        },
      ],
    };
    assert.equal(healYawThrusters(control), true);
    // port forward geometric tz > 0; heal must assign +tz on port
    assert.ok(control.thrusters[0].tz > 0, `port fwd tz ${control.thrusters[0].tz}`);
    assert.ok(control.thrusters[1].tz < 0, `stbd fwd tz ${control.thrusters[1].tz}`);
    const a = applyTeleop(control, 0, 0, 1, { skipCancel: true });
    const w = netWrench(control.thrusters, a.duties);
    assert.ok(w.Tz > 0.05, `healed A → +Tz, got ${w.Tz}`);
  });
});

describe("offset CoM user bugs (geometric physics)", () => {
  it("strafe C/Z: |Tz| small vs Fy (no unwanted yaw)", () => {
    for (const comY of [0.35, -0.35]) {
      const control = fixtureCardinal5OffsetCom({ comY });
      for (const fy of [1, -1]) {
        const r = applyCommand(control, 0, fy, 0);
        assert.equal(r.ok, true);
        const g = geometricFromDuties(control.thrusters, r.duties, GEOM(comY));
        assert.ok(Math.abs(g.Fy) > 0.2, `Fy ${g.Fy}`);
        assert.ok(
          ratioTz(g) < 0.2,
          `strafe yaw couple comY=${comY} fy=${fy}: Tz=${g.Tz} Fy=${g.Fy} path=${r.path}`,
        );
      }
    }
  });

  it("forward W: lateral/yaw bounded with starboard CoM", () => {
    const control = fixtureCardinal5OffsetCom({ comY: 0.35 });
    const r = applyCommand(control, 1, 0, 0);
    const g = geometricFromDuties(control.thrusters, r.duties, GEOM(0.35));
    assert.ok(g.Fx > 0.3, `expected surge, Fx=${g.Fx}`);
    assert.ok(
      ratioTz(g) < 0.2,
      `forward left-drift couple: Tz=${g.Tz} Fx=${g.Fx} compensated=${r.compensated}`,
    );
  });

  it("reverse S: opposite cancel (does not worsen CoM bias)", () => {
    const control = fixtureCardinal5OffsetCom({ comY: 0.35 });
    const fwd = applyCommand(JSON.parse(JSON.stringify(control)), 1, 0, 0);
    const rev = applyCommand(JSON.parse(JSON.stringify(control)), -1, 0, 0);
    const gf = geometricFromDuties(control.thrusters, fwd.duties, GEOM(0.35));
    // re-sync control for rev duties on fresh clone
    const c2 = fixtureCardinal5OffsetCom({ comY: 0.35 });
    const gr = geometricFromDuties(c2.thrusters, rev.duties, GEOM(0.35));
    assert.ok(gf.Fx > 0.2);
    assert.ok(gr.Fx < -0.2);
    assert.ok(ratioTz(gf) < 0.2, `fwd Tz ratio ${ratioTz(gf)}`);
    assert.ok(ratioTz(gr) < 0.2, `rev Tz ratio ${ratioTz(gr)}`);
    // Cancel signs should oppose the uncompensated couple direction
    if (fwd.compensated && rev.compensated) {
      assert.ok(
        Math.sign(fwd.cmd.tz) === -Math.sign(rev.cmd.tz) ||
          Math.abs(fwd.cmd.tz) + Math.abs(rev.cmd.tz) < 0.05,
        `cancel signs fwd=${fwd.cmd.tz} rev=${rev.cmd.tz}`,
      );
    }
  });

  it("aft CoM cardinal strafe stays yaw-quiet", () => {
    const control = fixtureCardinal5OffsetCom({ comX: -0.3, comY: 0.2 });
    control.alloc_mode = "cardinal";
    const r = applyCommand(control, 0, 1, 0);
    const g = geometricFromDuties(control.thrusters, r.duties, GEOM(0.2, -0.3));
    assert.ok(Math.abs(g.Fy) > 0.15, `Fy ${g.Fy}`);
    assert.ok(ratioTz(g) < 0.25, `aft cardinal strafe Tz=${g.Tz} Fy=${g.Fy}`);
  });

  it("cardinal fallback also cancels strafe yaw on offset CoM", () => {
    const control = fixtureCardinal5OffsetCom({ comY: 0.35 });
    control.alloc_mode = "cardinal";
    const r = applyCommand(control, 0, 1, 0);
    const g = geometricFromDuties(control.thrusters, r.duties, GEOM(0.35));
    assert.ok(Math.abs(g.Fy) > 0.2);
    assert.ok(ratioTz(g) < 0.25, `cardinal strafe Tz=${g.Tz} Fy=${g.Fy}`);
  });

  it("aft+starboard CoM: W and C stay yaw-quiet", () => {
    const control = loadFixture("cardinal_5_com_aft");
    const comX = control.com_x;
    const comY = control.com_y;
    for (const [fx, fy] of [
      [1, 0],
      [-1, 0],
      [0, 1],
      [0, -1],
    ]) {
      const r = applyCommand(JSON.parse(JSON.stringify(control)), fx, fy, 0);
      const g = geometricFromDuties(control.thrusters, r.duties, GEOM(comY, comX));
      const primary = Math.max(Math.abs(g.Fx), Math.abs(g.Fy));
      assert.ok(primary > 0.15, `no thrust fx=${fx} fy=${fy}`);
      assert.ok(
        ratioTz(g) < 0.25,
        `aft CoM fx=${fx} fy=${fy} Tz=${g.Tz} primary=${primary}`,
      );
    }
  });
});

describe("adversarial allocation", () => {
  it("asymmetric max_force still A→+Tz and W→+Fx", () => {
    const control = loadFixture("cardinal_5_sized");
    const w = applyCommand(control, 1, 0, 0);
    const a = applyCommand(JSON.parse(JSON.stringify(control)), 0, 0, 1);
    assert.ok(netWrench(control.thrusters, w.duties).Fx > 0.05);
    assert.ok(netWrench(control.thrusters, a.duties).Tz > 0.02);
  });

  it("W+D chord allocates without NaN and nonzero duties", () => {
    const control = loadFixture("cardinal_5_boat");
    const r = applyCommand(control, 1, 0, -1);
    assert.equal(r.ok, true);
    assert.ok(r.duties.every((d) => Number.isFinite(d)));
    assert.ok(r.duties.some((d) => Math.abs(d) > 0.08));
  });

  it("idle zeros duties", () => {
    const control = loadFixture("cardinal_5_com_stbd");
    const r = applyCommand(control, 0, 0, 0);
    assert.equal(r.ok, true);
    assert.ok(r.duties.every((d) => d === 0));
  });

  it("pure yaw with only L/R thrusters still turns left on A", () => {
    const control = {
      version: 6,
      mode: "wrench",
      alloc_mode: "cardinal",
      yaw_sign: 1,
      thrusters: [
        {
          name: "port",
          kind: "motor",
          facing: "left",
          max_force: 0.6,
          lx: 0.4,
          ly: -0.7,
          lz: 0,
        },
        {
          name: "stbd",
          kind: "motor",
          facing: "right",
          max_force: 0.6,
          lx: 0.4,
          ly: 0.7,
          lz: 0,
        },
      ],
    };
    for (const t of control.thrusters) syncWrenchFromFacing(t, control);
    const a = applyCommand(control, 0, 0, 1);
    const w = netWrench(control.thrusters, a.duties);
    assert.ok(w.Tz > 0.05, `L/R-only A Tz=${w.Tz} duties=${a.duties}`);
  });

  it("Reassembly deadband tz=0 still yaws via applyCommand fallback", () => {
    const control = fixtureLuaLikeCardinal5({ tzScale: 0 });
    for (const t of control.thrusters) {
      delete t.lx;
      delete t.ly;
      delete t.lz;
    }
    const dead = applyReassembly(JSON.parse(JSON.stringify(control)), 0, 0, 1, {
      skipCancel: true,
      compensate: false,
    });
    assert.equal(dead.ok, false);
    const cmd = applyCommand(JSON.parse(JSON.stringify(control)), 0, 0, 1);
    assert.equal(cmd.ok, true);
    assert.ok(cmd.duties.some((d) => Math.abs(d) > 0.08));
  });
});

describe("in-game-equivalent boat_control.json v6", () => {
  it("lua-like fixture: W/S/A/D/Z/C all produce live duties", () => {
    const control = loadFixture("lua_like_cardinal5");
    const cases = [
      [1, 0, 0, "W"],
      [-1, 0, 0, "S"],
      [0, 1, 0, "C"],
      [0, -1, 0, "Z"],
      [0, 0, 1, "A"],
      [0, 0, -1, "D"],
    ];
    for (const [fx, fy, tz, label] of cases) {
      const r = applyCommand(JSON.parse(JSON.stringify(control)), fx, fy, tz);
      assert.equal(r.ok, true, label);
      assert.ok(
        r.duties.some((d) => Math.abs(d) > 0.08),
        `${label} dead path=${r.path}`,
      );
    }
  });

  it("lua-like A produces +Tz under wrench projection", () => {
    const control = loadFixture("lua_like_cardinal5");
    const a = applyCommand(control, 0, 0, 1);
    const w = netWrench(control.thrusters, a.duties);
    assert.ok(w.Tz > 0.01, `in-game A Tz=${w.Tz} path=${a.path}`);
  });
});

describe("physics smoke with offset CoM + applyCommand", () => {
  it("W on starboard-CoM boat advances with small yaw rate", () => {
    const control = fixtureCardinal5OffsetCom({ comY: 0.35 });
    const { duties } = applyCommand(control, 1, 0, 0);
    let body = createBody({ z: -0.05 });
    const params = defaultPhysicsParams({
      forceMode: "geometric",
      comY: 0.35,
      geometricForceScale: 40,
      linearDrag: 0.5,
      angularDrag: 1.2,
    });
    for (let i = 0; i < 120; i++) {
      body = step(body, control.thrusters, duties, params, 1 / 60).body;
    }
    assert.ok(body.y > 0.15, `forward y=${body.y}`);
    assert.ok(Math.abs(body.wz) < 0.8, `yaw rate wz=${body.wz}`);
  });
});
