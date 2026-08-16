/**
 * Asymmetric / weird thruster layouts: W must produce real forward surge
 * with bounded yaw + lateral residuals (no off-center drift).
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  applyCommand,
  netWrench,
  nullResidualYaw,
} from "./allocation.mjs";
import {
  loadFixture,
  fixtureAsymmetricCardinal,
  fixtureWeirdPositions,
  fixtureMissingMirroredFaces,
  fixtureOffCenterMassAsym,
  fixtureSeededWeird,
} from "./fixtures.mjs";
import {
  geometricFromDuties,
  createBody,
  defaultPhysicsParams,
  step,
} from "./physics.mjs";

const FX_MIN = 0.35;
const TZ_RATIO = 0.35;
const FY_RATIO = 0.35;

function comParams(control) {
  return {
    geometricForceScale: 1,
    comX: Number(control.com_x ?? control.comX) || 0,
    comY: Number(control.com_y ?? control.comY) || 0,
    comZ: Number(control.com_z ?? control.comZ) || 0,
  };
}

function assertFiniteDuties(duties, label) {
  assert.ok(Array.isArray(duties) && duties.length > 0, `${label}: no duties`);
  assert.ok(
    duties.every((d) => Number.isFinite(d)),
    `${label}: NaN/Inf duties ${duties}`,
  );
}

function assertPureW(control, label, opts = {}) {
  const fxMin = opts.fxMin ?? FX_MIN;
  const tzRatio = opts.tzRatio ?? TZ_RATIO;
  const fyRatio = opts.fyRatio ?? FY_RATIO;
  const r = applyCommand(JSON.parse(JSON.stringify(control)), 1, 0, 0);
  assert.equal(r.ok, true, `${label} W ok`);
  assertFiniteDuties(r.duties, `${label} W`);
  assert.ok(
    r.duties.some((d) => Math.abs(d) > 0.08),
    `${label} W deadband-zero duties path=${r.path}`,
  );
  const w = netWrench(control.thrusters, r.duties);
  const g = geometricFromDuties(control.thrusters, r.duties, comParams(control));
  assert.ok(w.Fx > fxMin, `${label} W net Fx=${w.Fx} (want >${fxMin}) path=${r.path}`);
  assert.ok(g.Fx > fxMin * 0.9, `${label} W geom Fx=${g.Fx}`);
  assert.ok(
    Math.abs(w.Tz) < Math.abs(w.Fx) * tzRatio + 0.08,
    `${label} W |Tz|=${w.Tz} vs Fx=${w.Fx}`,
  );
  assert.ok(
    Math.abs(w.Fy) < Math.abs(w.Fx) * fyRatio + 0.08,
    `${label} W |Fy|=${w.Fy} vs Fx=${w.Fx} (off-center drift)`,
  );
  return { r, w, g };
}

function assertAxisSuite(control, label) {
  assertPureW(control, label);

  const s = applyCommand(JSON.parse(JSON.stringify(control)), -1, 0, 0);
  assert.equal(s.ok, true, `${label} S`);
  assertFiniteDuties(s.duties, `${label} S`);
  const ws = netWrench(control.thrusters, s.duties);
  assert.ok(ws.Fx < -FX_MIN * 0.7, `${label} S Fx=${ws.Fx}`);

  for (const [fy, tag] of [
    [1, "C"],
    [-1, "Z"],
  ]) {
    const r = applyCommand(JSON.parse(JSON.stringify(control)), 0, fy, 0);
    assert.equal(r.ok, true, `${label} ${tag}`);
    assertFiniteDuties(r.duties, `${label} ${tag}`);
    const w = netWrench(control.thrusters, r.duties);
    assert.ok(
      Math.sign(w.Fy) === Math.sign(fy) || Math.abs(w.Fy) > 0.08,
      `${label} ${tag} Fy=${w.Fy}`,
    );
    assert.ok(Math.abs(w.Fy) > 0.08, `${label} ${tag} dead Fy`);
  }

  for (const [tz, tag] of [
    [1, "A"],
    [-1, "D"],
  ]) {
    const r = applyCommand(JSON.parse(JSON.stringify(control)), 0, 0, tz);
    assert.equal(r.ok, true, `${label} ${tag}`);
    assertFiniteDuties(r.duties, `${label} ${tag}`);
    const w = netWrench(control.thrusters, r.duties);
    assert.ok(
      Math.sign(w.Tz) === Math.sign(tz) && Math.abs(w.Tz) > 0.02,
      `${label} ${tag} Tz=${w.Tz}`,
    );
  }
}

describe("asymmetric_cardinal forward + center", () => {
  it("pure W: Fx above threshold, |Tz| and |Fy| bounded", () => {
    assertPureW(loadFixture("asymmetric_cardinal"), "asymmetric_cardinal");
  });

  it("S / strafe / A/D still correct", () => {
    assertAxisSuite(loadFixture("asymmetric_cardinal"), "asymmetric_cardinal");
  });

  it("physics: W advances with bounded yaw rate", () => {
    const control = fixtureAsymmetricCardinal();
    const { duties } = applyCommand(control, 1, 0, 0);
    let body = createBody({ z: -0.05 });
    const params = defaultPhysicsParams({
      forceMode: "geometric",
      comX: control.com_x,
      comY: control.com_y,
      geometricForceScale: 40,
      linearDrag: 0.5,
      angularDrag: 1.2,
    });
    for (let i = 0; i < 120; i++) {
      body = step(body, control.thrusters, duties, params, 1 / 60).body;
    }
    assert.ok(body.y > 0.12, `forward y=${body.y}`);
    assert.ok(Math.abs(body.wz) < 1.2, `yaw rate wz=${body.wz}`);
  });
});

describe("weird_positions", () => {
  it("pure W moves forward, residuals bounded", () => {
    assertPureW(loadFixture("weird_positions"), "weird_positions", {
      fxMin: 0.25,
    });
  });

  it("full axis suite", () => {
    assertAxisSuite(fixtureWeirdPositions(), "weird_positions");
  });
});

describe("missing_mirrored_faces", () => {
  it("1 fwd + uneven L/R/back: W still surges", () => {
    assertPureW(loadFixture("missing_mirrored_faces"), "missing_mirrored", {
      fxMin: 0.3,
    });
  });

  it("full axis suite", () => {
    assertAxisSuite(fixtureMissingMirroredFaces(), "missing_mirrored");
  });
});

describe("offcenter_mass_asym", () => {
  it("off-center CoM + asymmetric thrust: W forward, no big drift", () => {
    assertPureW(loadFixture("offcenter_mass_asym"), "offcenter_mass_asym");
  });

  it("full axis suite", () => {
    assertAxisSuite(fixtureOffCenterMassAsym(), "offcenter_mass_asym");
  });
});

describe("nullResidualYaw protects surge", () => {
  it("never drives net Fx below a fraction of baseline on asymmetric cardinal", () => {
    const control = fixtureAsymmetricCardinal();
    // Strong forward-only start (large yaw couple from off-center fwd).
    const baseline = [1, 0, 0, 0, 0];
    const before = netWrench(control.thrusters, baseline);
    assert.ok(before.Fx > 0.5);
    const afterDuties = nullResidualYaw(control.thrusters, baseline, {
      minPrimaryFraction: 0.55,
      cmdFx: 1,
      cmdFy: 0,
    });
    const after = netWrench(control.thrusters, afterDuties);
    assert.ok(
      after.Fx >= before.Fx * 0.55 - 1e-6,
      `null killed surge: before Fx=${before.Fx} after=${after.Fx}`,
    );
    assert.ok(Math.abs(after.Tz) <= Math.abs(before.Tz) + 0.05);
  });
});

describe("adversarial seeded weird layouts", () => {
  it("seeded layouts get non-zero forward on W and no NaN", () => {
    for (const seed of [42, 99, 7, 1234, 2026]) {
      const control = fixtureSeededWeird(seed);
      const r = applyCommand(JSON.parse(JSON.stringify(control)), 1, 0, 0);
      assert.equal(r.ok, true, `seed ${seed} ok`);
      assertFiniteDuties(r.duties, `seed ${seed}`);
      const w = netWrench(control.thrusters, r.duties);
      assert.ok(
        Number.isFinite(w.Fx) && Number.isFinite(w.Fy) && Number.isFinite(w.Tz),
        `seed ${seed} NaN wrench`,
      );
      assert.ok(
        w.Fx > 0.08,
        `seed ${seed} W Fx=${w.Fx} duties=${r.duties} path=${r.path}`,
      );
    }
  });

  it("named seeded fixtures load", () => {
    assertPureW(loadFixture("seeded_weird_42"), "seeded_42", { fxMin: 0.08 });
    assertPureW(loadFixture("seeded_weird_99"), "seeded_99", { fxMin: 0.08 });
  });
});
