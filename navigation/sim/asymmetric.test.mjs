/**
 * Asymmetric / weird thruster layouts: W must produce real forward surge
 * with near-zero yaw (duty-space and planar physics). Weak |Tz|/Fx ratios
 * previously passed while boats still spun left on pure W.
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

/** Tight: prior 0.35 allowed ~15° planar yaw on asymmetric_cardinal. */
const FX_MIN = 0.35;
const TZ_RATIO = 0.045;
const TZ_ABS = 0.018;
const FY_RATIO = 0.22;
/** Planar (roll/pitch locked) Δyaw over ~2s must stay small while y grows. */
const PLANAR_YAW_DEG_MAX = 5.5;
const PLANAR_FWD_MIN = 0.8;

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
  const tzAbs = opts.tzAbs ?? TZ_ABS;
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
  const tzLim = Math.max(tzAbs, Math.abs(w.Fx) * tzRatio);
  assert.ok(
    Math.abs(w.Tz) <= tzLim + 1e-9,
    `${label} W |Tz|=${w.Tz} vs Fx=${w.Fx} lim=${tzLim} ratio=${Math.abs(w.Tz) / Math.max(Math.abs(w.Fx), 1e-9)}`,
  );
  assert.ok(
    Math.abs(g.Tz) <= Math.max(tzAbs, Math.abs(g.Fx) * tzRatio) + 1e-9,
    `${label} W geom |Tz|=${g.Tz} vs Fx=${g.Fx}`,
  );
  assert.ok(
    Math.abs(w.Fy) < Math.abs(w.Fx) * fyRatio + 0.06,
    `${label} W |Fy|=${w.Fy} vs Fx=${w.Fx} (off-center drift)`,
  );
  return { r, w, g };
}

/** Integrate thruster yaw only — lock roll/pitch so buoyancy flip ≠ "yaw bug". */
function simulatePlanarW(control, duties, seconds = 2) {
  let body = createBody({ z: -0.05 });
  const params = defaultPhysicsParams({
    forceMode: "geometric",
    comX: control.com_x,
    comY: control.com_y,
    comZ: control.com_z,
    geometricForceScale: 40,
    linearDrag: 0.5,
    angularDrag: 1.2,
  });
  let yawUnwrapped = 0;
  let prevYaw = body.yaw;
  const n = Math.round(seconds * 60);
  for (let i = 0; i < n; i++) {
    body = step(body, control.thrusters, duties, params, 1 / 60).body;
    body.roll = 0;
    body.pitch = 0;
    body.wx = 0;
    body.wy = 0;
    let dy = body.yaw - prevYaw;
    if (dy > Math.PI) dy -= 2 * Math.PI;
    if (dy < -Math.PI) dy += 2 * Math.PI;
    yawUnwrapped += dy;
    prevYaw = body.yaw;
  }
  return { body, yawDeg: (yawUnwrapped * 180) / Math.PI, yawRad: yawUnwrapped };
}

function assertPlanarForwardQuiet(control, label, opts = {}) {
  const yawMax = opts.yawDegMax ?? PLANAR_YAW_DEG_MAX;
  const fwdMin = opts.fwdMin ?? PLANAR_FWD_MIN;
  const r = applyCommand(JSON.parse(JSON.stringify(control)), 1, 0, 0);
  assert.equal(r.ok, true, `${label} planar W ok`);
  const sim = simulatePlanarW(control, r.duties, 2);
  assert.ok(
    sim.body.y > fwdMin,
    `${label} planar forward y=${sim.body.y} (want >${fwdMin})`,
  );
  assert.ok(
    Math.abs(sim.yawDeg) < yawMax,
    `${label} planar |Δyaw|=${sim.yawDeg.toFixed(2)}° (want <${yawMax}°) wz=${sim.body.wz}`,
  );
  return sim;
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
  it("pure W: Fx above threshold, |Tz| and |Fy| tightly bounded", () => {
    assertPureW(loadFixture("asymmetric_cardinal"), "asymmetric_cardinal");
  });

  it("S / strafe / A/D still correct", () => {
    assertAxisSuite(loadFixture("asymmetric_cardinal"), "asymmetric_cardinal");
  });

  it("planar physics: W advances with |Δyaw| < 5.5° over 2s", () => {
    assertPlanarForwardQuiet(fixtureAsymmetricCardinal(), "asymmetric_cardinal");
  });
});

describe("weird_positions", () => {
  it("pure W moves forward, residuals tightly bounded", () => {
    assertPureW(loadFixture("weird_positions"), "weird_positions", {
      fxMin: 0.25,
    });
  });

  it("full axis suite", () => {
    assertAxisSuite(fixtureWeirdPositions(), "weird_positions");
  });

  it("planar physics: forward grows, yaw stays quiet", () => {
    assertPlanarForwardQuiet(fixtureWeirdPositions(), "weird_positions", {
      fwdMin: 0.6,
    });
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

  it("planar physics: forward grows, yaw stays quiet", () => {
    assertPlanarForwardQuiet(fixtureOffCenterMassAsym(), "offcenter_mass_asym");
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
      targetRatio: 0.035,
      targetAbs: 0.012,
    });
    const after = netWrench(control.thrusters, afterDuties);
    assert.ok(
      after.Fx >= before.Fx * 0.55 - 1e-6,
      `null killed surge: before Fx=${before.Fx} after=${after.Fx}`,
    );
    assert.ok(Math.abs(after.Tz) < Math.abs(before.Tz) * 0.25 + 0.02);
  });
});

describe("adversarial seeded weird layouts", () => {
  it("seeded layouts: strong Fx, tight |Tz|/Fx, quiet planar yaw", () => {
    for (const seed of [42, 99, 7, 1234, 2026]) {
      const control = fixtureSeededWeird(seed);
      const { w } = assertPureW(control, `seed_${seed}`, { fxMin: 0.2 });
      assert.ok(
        Math.abs(w.Tz) / Math.max(Math.abs(w.Fx), 1e-9) < TZ_RATIO + 0.01,
        `seed ${seed} tzRatio`,
      );
      assertPlanarForwardQuiet(control, `seed_${seed}`, {
        fwdMin: 0.5,
        yawDegMax: PLANAR_YAW_DEG_MAX,
      });
    }
  });

  it("named seeded fixtures load with tight W checks", () => {
    assertPureW(loadFixture("seeded_weird_42"), "seeded_42", { fxMin: 0.2 });
    assertPureW(loadFixture("seeded_weird_99"), "seeded_99", { fxMin: 0.2 });
    assertPlanarForwardQuiet(loadFixture("seeded_weird_99"), "seeded_99");
    assertPlanarForwardQuiet(loadFixture("seeded_weird_42"), "seeded_42");
  });
});
