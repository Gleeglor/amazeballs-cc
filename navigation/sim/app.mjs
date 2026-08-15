/**
 * Interactive boat physics play-space (top + side views).
 * Uses the same allocation.mjs as unit tests (CC applyCommand / teleop / roles).
 */
import {
  applyTeleop,
  applyCommand,
  applyCardinalRoles,
  commandFromKeys,
  dutyToRpm,
  healYawThrusters,
  syncWrenchFromFacing,
} from "./allocation.mjs";
import {
  createBody,
  defaultPhysicsParams,
  step,
  forcesFromDuties,
  thrusterDirection,
  bodyToWorld,
} from "./physics.mjs";
import {
  FIXTURES,
  DEFAULT_FIXTURE,
  loadFixture,
  controlFromJson,
  sampleBoatControlJson,
} from "./fixtures.mjs";

const canvasTop = document.getElementById("viewTop");
const canvasSide = document.getElementById("viewSide");
const ctxTop = canvasTop.getContext("2d");
const ctxSide = canvasSide.getContext("2d");
const hud = document.getElementById("hud");
const dutyTable = document.getElementById("duties");
const jsonArea = document.getElementById("json");
const statusEl = document.getElementById("status");

const held = { w: false, a: false, s: false, d: false, z: false, c: false };
let control = loadFixture(DEFAULT_FIXTURE);
let body = createBody({ z: -0.05 });
let allocMode = "reassembly";
let forceMode = "geometric";
let lastDuties = control.thrusters.map(() => 0);
let lastBranch = "idle";
let lastPath = "";
let lastForces = { Fx: 0, Fy: 0, Fz: 0, Tx: 0, Ty: 0, Tz: 0 };
let lastHydro = { buoyancy: 0, weight: 0, waterline: 0 };
let selectedThruster = 0;
let running = true;
let baseMass = 8;

const params = defaultPhysicsParams({
  mass: 8,
  Iz: 4,
  inertia: 4,
  linearDrag: 1.2,
  quadraticDrag: 0.35,
  angularDrag: 2.0,
  verticalDrag: 6,
  wrenchForceScale: 40,
  wrenchTorqueScale: 25,
  geometricForceScale: 50,
  forceMode: "geometric",
});

function syncControlsFromDom() {
  baseMass = num("mass", 8);
  const ballast = num("ballast", 0);
  params.mass = Math.max(0.5, baseMass + ballast);
  params.inertia = num("inertia", 4);
  params.Iz = params.inertia;
  params.linearDrag = num("linDrag", 1.2);
  params.quadraticDrag = num("quadDrag", 0.35);
  params.angularDrag = num("angDrag", 2.0);
  params.verticalDrag = num("vertDrag", 6);
  params.hullVolume = num("hullVol", 0.012);
  params.comX = num("comX", 0);
  params.comY = num("comY", 0);
  params.comZ = num("comZ", -0.05);
  // Allocation uses the same CoM as physics (τ about CoM + cancel).
  control.com_x = params.comX;
  control.com_y = params.comY;
  control.com_z = params.comZ;
  control.comX = params.comX;
  control.comY = params.comY;
  control.comZ = params.comZ;
  if (control.com_compensate == null) control.com_compensate = true;
  if (control.yaw_sign == null) control.yaw_sign = 1;
  params.wrenchForceScale = num("fScale", 40);
  params.wrenchTorqueScale = num("tScale", 25);
  const maxRpm = num("maxRpm", 24);
  for (const t of control.thrusters) t.max_rpm = maxRpm;
  control.default_motor_rpm = maxRpm;
  allocMode = document.getElementById("allocMode").value;
  forceMode = document.getElementById("forceMode").value;
  params.forceMode = forceMode;
}

function num(id, fallback) {
  const el = document.getElementById(id);
  if (!el) return fallback;
  const v = Number(el.value);
  return Number.isFinite(v) ? v : fallback;
}

function allocate(cmd) {
  let r;
  if (allocMode === "teleop") {
    r = applyTeleop(control, cmd.fx, cmd.fy, cmd.tz);
    lastPath = "teleop";
  } else if (allocMode === "cardinal") {
    r = applyCardinalRoles(control, cmd.fx, cmd.fy, cmd.tz);
    lastPath = "cardinal";
  } else {
    r = applyCommand(control, cmd.fx, cmd.fy, cmd.tz);
    lastPath = r.path || "reassembly";
  }
  lastDuties = r.duties || control.thrusters.map(() => 0);
  lastBranch = r.branch || "?";
  return r;
}

function resetPose() {
  body = createBody({ z: -0.05 });
}

function reloadFixture(name) {
  control = loadFixture(name);
  jsonArea.value = JSON.stringify(control, null, 2);
  selectedThruster = 0;
  resetPose();
  fillThrusterEditor();
  statusEl.textContent = `Loaded fixture: ${name}`;
}

function applyJson() {
  try {
    control = controlFromJson(jsonArea.value);
    fillThrusterEditor();
    resetPose();
    statusEl.textContent = `Loaded ${control.thrusters.length} thrusters from JSON`;
  } catch (e) {
    statusEl.textContent = `JSON error: ${e.message}`;
  }
}

function fillThrusterEditor() {
  const sel = document.getElementById("thrusterSel");
  sel.innerHTML = "";
  control.thrusters.forEach((t, i) => {
    const opt = document.createElement("option");
    opt.value = String(i);
    opt.textContent = `${i}: ${t.name}`;
    sel.appendChild(opt);
  });
  sel.value = String(selectedThruster);
  const t = control.thrusters[selectedThruster];
  if (!t) return;
  document.getElementById("t_lx").value = t.lx ?? 0;
  document.getElementById("t_ly").value = t.ly ?? 0;
  document.getElementById("t_lz").value = t.lz ?? 0;
  document.getElementById("t_fx").value = t.fx ?? 0;
  document.getElementById("t_fy").value = t.fy ?? 0;
  document.getElementById("t_tz").value = t.tz ?? 0;
  document.getElementById("t_force").value = t.max_force ?? t.strength ?? 1;
  document.getElementById("t_facing").value = t.facing || t.role || "forward";
  document.getElementById("t_ang").value = (
    ((t.angleRad ?? 0) * 180) /
    Math.PI
  ).toFixed(1);
}

function commitThrusterEditor() {
  const t = control.thrusters[selectedThruster];
  if (!t) return;
  t.lx = num("t_lx", 0);
  t.ly = num("t_ly", 0);
  t.lz = num("t_lz", 0);
  t.max_force = num("t_force", 1);
  t.facing = document.getElementById("t_facing").value;
  t.role = t.facing;
  syncWrenchFromFacing(t);
  document.getElementById("t_fx").value = t.fx ?? 0;
  document.getElementById("t_fy").value = t.fy ?? 0;
  document.getElementById("t_tz").value = t.tz ?? 0;
  document.getElementById("t_ang").value = (
    ((t.angleRad ?? 0) * 180) /
    Math.PI
  ).toFixed(1);
  jsonArea.value = JSON.stringify(control, null, 2);
}

function addThruster() {
  const n = control.thrusters.length;
  const t = syncWrenchFromFacing({
    name: `thruster_${n}`,
    kind: "motor",
    max_rpm: control.default_motor_rpm || 24,
    facing: "forward",
    role: "forward",
    max_force: 0.6,
    lx: 0,
    ly: 0,
    lz: -0.05,
  });
  control.thrusters.push(t);
  selectedThruster = n;
  fillThrusterEditor();
  jsonArea.value = JSON.stringify(control, null, 2);
  statusEl.textContent = `Added ${t.name} (N=${control.thrusters.length})`;
}

function removeThruster() {
  if (control.thrusters.length <= 1) {
    statusEl.textContent = "Need at least one thruster";
    return;
  }
  const removed = control.thrusters.splice(selectedThruster, 1)[0];
  selectedThruster = Math.min(selectedThruster, control.thrusters.length - 1);
  fillThrusterEditor();
  jsonArea.value = JSON.stringify(control, null, 2);
  statusEl.textContent = `Removed ${removed?.name} (N=${control.thrusters.length})`;
}

function clearCanvas(ctx, canvas) {
  ctx.fillStyle = "#0e141b";
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.strokeStyle = "#1c2733";
  ctx.lineWidth = 1;
  const cx = canvas.width / 2;
  const cy = canvas.height / 2;
  const scale = 36;
  for (let g = -14; g <= 14; g++) {
    ctx.beginPath();
    ctx.moveTo(cx + g * scale, 0);
    ctx.lineTo(cx + g * scale, canvas.height);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(0, cy - g * scale);
    ctx.lineTo(canvas.width, cy - g * scale);
    ctx.stroke();
  }
  return { cx, cy, scale };
}

function bodyLocalWorld(lx, ly, lz) {
  const w = bodyToWorld(body, lx, ly, lz);
  return { x: body.x + w.x, y: body.y + w.y, z: body.z + w.z };
}

function drawTop() {
  const canvas = canvasTop;
  const ctx = ctxTop;
  const { cx, cy, scale } = clearCanvas(ctx, canvas);
  const ox = cx - body.x * scale;
  const oy = cy + body.y * scale;

  function toScreen(wx, wy) {
    return { x: ox + wx * scale, y: oy - wy * scale };
  }

  ctx.fillStyle = "rgba(56, 139, 253, 0.08)";
  ctx.fillRect(0, 0, canvas.width, canvas.height);

  const hull = [
    [1.2, 0, 0],
    [0.6, 0.7, 0],
    [-1.0, 0.55, 0],
    [-1.0, -0.55, 0],
    [0.6, -0.7, 0],
  ];
  ctx.beginPath();
  hull.forEach((p, i) => {
    const w = bodyLocalWorld(p[0], p[1], p[2]);
    const q = toScreen(w.x, w.y);
    if (i === 0) ctx.moveTo(q.x, q.y);
    else ctx.lineTo(q.x, q.y);
  });
  ctx.closePath();
  ctx.fillStyle = "#243447";
  ctx.fill();
  ctx.strokeStyle = "#6cb6ff";
  ctx.lineWidth = 2;
  ctx.stroke();

  const comW = bodyLocalWorld(params.comX || 0, params.comY || 0, params.comZ || 0);
  const com = toScreen(comW.x, comW.y);
  ctx.fillStyle = "#f0c674";
  ctx.beginPath();
  ctx.arc(com.x, com.y, 5, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = "#9aa7b5";
  ctx.font = "11px ui-sans-serif, system-ui";
  ctx.fillText("CoM", com.x + 8, com.y - 6);

  const noseW = bodyLocalWorld(1.4, 0, 0);
  const nose = toScreen(noseW.x, noseW.y);
  ctx.strokeStyle = "#7ee787";
  ctx.beginPath();
  ctx.moveTo(com.x, com.y);
  ctx.lineTo(nose.x, nose.y);
  ctx.stroke();

  const vScale = 8;
  ctx.strokeStyle = "#d2a8ff";
  ctx.beginPath();
  ctx.moveTo(com.x, com.y);
  ctx.lineTo(com.x + body.vx * vScale, com.y - body.vy * vScale);
  ctx.stroke();

  drawThrusters(
    ctx,
    (lx, ly, lz) => {
      const w = bodyLocalWorld(lx, ly, lz);
      return toScreen(w.x, w.y);
    },
    "xy",
  );
}

function drawSide() {
  const canvas = canvasSide;
  const ctx = ctxSide;
  const { cx, cy, scale } = clearCanvas(ctx, canvas);
  const ox = cx - body.x * scale;
  const oy = cy + body.z * scale;

  function toScreen(wx, wz) {
    return { x: ox + wx * scale, y: oy - wz * scale };
  }

  const waterY = oy;
  ctx.fillStyle = "rgba(56, 139, 253, 0.18)";
  ctx.fillRect(0, waterY, canvas.width, canvas.height - waterY);
  ctx.strokeStyle = "#58a6ff";
  ctx.setLineDash([6, 4]);
  ctx.beginPath();
  ctx.moveTo(0, waterY);
  ctx.lineTo(canvas.width, waterY);
  ctx.stroke();
  ctx.setLineDash([]);
  ctx.fillStyle = "#8b949e";
  ctx.font = "10px ui-sans-serif, system-ui";
  ctx.fillText("waterline z=0", 8, waterY - 6);

  const hull = [
    [1.2, 0, 0.15],
    [1.2, 0, -0.15],
    [-1.0, 0, -0.15],
    [-1.0, 0, 0.15],
  ];
  ctx.beginPath();
  hull.forEach((p, i) => {
    const w = bodyLocalWorld(p[0], p[1], p[2]);
    const q = toScreen(w.x, w.z);
    if (i === 0) ctx.moveTo(q.x, q.y);
    else ctx.lineTo(q.x, q.y);
  });
  ctx.closePath();
  ctx.fillStyle = "#243447";
  ctx.fill();
  ctx.strokeStyle = "#6cb6ff";
  ctx.lineWidth = 2;
  ctx.stroke();

  const comW = bodyLocalWorld(params.comX || 0, params.comY || 0, params.comZ || 0);
  const com = toScreen(comW.x, comW.z);
  ctx.fillStyle = "#f0c674";
  ctx.beginPath();
  ctx.arc(com.x, com.y, 5, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = "#9aa7b5";
  ctx.fillText("CoM", com.x + 8, com.y - 6);

  const origin = toScreen(body.x, body.z);
  const bScale = 0.004;
  ctx.strokeStyle = "#3fb950";
  ctx.beginPath();
  ctx.moveTo(origin.x - 12, origin.y);
  ctx.lineTo(origin.x - 12, origin.y - (lastHydro.buoyancy || 0) * bScale);
  ctx.stroke();
  ctx.strokeStyle = "#f85149";
  ctx.beginPath();
  ctx.moveTo(origin.x + 12, origin.y);
  ctx.lineTo(origin.x + 12, origin.y + (lastHydro.weight || 0) * bScale);
  ctx.stroke();

  drawThrusters(
    ctx,
    (lx, ly, lz) => {
      const w = bodyLocalWorld(lx, ly, lz);
      return toScreen(w.x, w.z);
    },
    "xz",
  );
}

function drawThrusters(ctx, project, plane) {
  control.thrusters.forEach((t, i) => {
    const p = project(t.lx || 0, t.ly || 0, t.lz || 0);
    const duty = lastDuties[i] || 0;
    const on = Math.abs(duty) >= 0.08;
    ctx.fillStyle = on ? (duty > 0 ? "#3fb950" : "#f85149") : "#484f58";
    ctx.beginPath();
    ctx.arc(p.x, p.y, selectedThruster === i ? 8 : 6, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = selectedThruster === i ? "#f0c674" : "#8b949e";
    ctx.stroke();

    let dir;
    if (forceMode === "geometric") {
      dir = thrusterDirection(t);
    } else {
      const fx = t.fx || 0;
      const fy = t.fy || 0;
      const fz = t.fz || 0;
      const len = Math.hypot(fx, fy, fz) || 1;
      dir = { x: fx / len, y: fy / len, z: fz / len };
    }
    const arrow = 0.55 * duty;
    const tip = project(
      (t.lx || 0) + dir.x * arrow,
      (t.ly || 0) + dir.y * arrow,
      (t.lz || 0) + dir.z * arrow,
    );
    ctx.strokeStyle = on ? "#58a6ff" : "#30363d";
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(p.x, p.y);
    ctx.lineTo(tip.x, tip.y);
    ctx.stroke();

    if (plane === "xy") {
      const rpm = dutyToRpm(duty, t.max_rpm || 24, t.rpm_sign || 1);
      ctx.fillStyle = "#c9d1d9";
      ctx.font = "10px ui-sans-serif, system-ui";
      ctx.fillText(`${t.name} ${rpm}`, p.x + 10, p.y + 4);
    }
  });
}

function renderHud(cmd) {
  const speed = Math.hypot(body.vx, body.vy, body.vz);
  const bw = lastHydro.weight || 1;
  const ratio = ((lastHydro.buoyancy || 0) / bw).toFixed(2);
  hud.innerHTML = `
    <div><b>cmd</b> fx=${cmd.fx} fy=${cmd.fy} tz=${cmd.tz}</div>
    <div><b>alloc</b> ${lastPath} · <b>branch</b> ${lastBranch}</div>
    <div><b>pose</b> x=${body.x.toFixed(2)} y=${body.y.toFixed(2)} z=${body.z.toFixed(2)}</div>
    <div><b>att</b> yaw=${((body.yaw * 180) / Math.PI).toFixed(1)}° pitch=${((body.pitch * 180) / Math.PI).toFixed(1)}° roll=${((body.roll * 180) / Math.PI).toFixed(1)}°</div>
    <div><b>vel</b> |v|=${speed.toFixed(2)} ωz=${body.wz.toFixed(2)}</div>
    <div><b>B/W</b> ${ratio} (B=${(lastHydro.buoyancy || 0).toFixed(0)} W=${(lastHydro.weight || 0).toFixed(0)})</div>
    <div><b>wrench</b> Fx=${lastForces.Fx.toFixed(1)} Fy=${lastForces.Fy.toFixed(1)} Tz=${lastForces.Tz.toFixed(1)}</div>
    <div><b>CoM</b> (${(params.comX || 0).toFixed(2)}, ${(params.comY || 0).toFixed(2)}, ${(params.comZ || 0).toFixed(2)})</div>
  `;

  dutyTable.innerHTML = control.thrusters
    .map((t, i) => {
      const d = lastDuties[i] || 0;
      const rpm = dutyToRpm(d, t.max_rpm || 24);
      const on = Math.abs(d) >= 0.08 ? "ON" : "off";
      return `<tr class="${selectedThruster === i ? "sel" : ""}">
        <td>${t.name}</td>
        <td>${t.facing || t.role || "—"}</td>
        <td>${(t.max_force ?? 1).toFixed(2)}</td>
        <td>${d.toFixed(2)}</td>
        <td>${rpm}</td>
        <td>${on}</td>
        <td>${(t.fx || 0).toFixed(2)}</td>
        <td>${(t.fy || 0).toFixed(2)}</td>
        <td>${(t.tz || 0).toFixed(2)}</td>
      </tr>`;
    })
    .join("");
}

let last = performance.now();
function frame(now) {
  const dt = Math.min(0.05, (now - last) / 1000);
  last = now;
  syncControlsFromDom();
  const cmd = commandFromKeys(held);
  allocate(cmd);
  lastForces = forcesFromDuties(control.thrusters, lastDuties, params);
  if (running) {
    const r = step(body, control.thrusters, lastDuties, params, dt);
    body = r.body;
    lastHydro = r.hydro || lastHydro;
  }
  drawTop();
  drawSide();
  renderHud(cmd);
  requestAnimationFrame(frame);
}

document.getElementById("fixture").innerHTML = Object.keys(FIXTURES)
  .map((k) => `<option value="${k}">${k}</option>`)
  .join("");
document.getElementById("fixture").value = DEFAULT_FIXTURE;
document.getElementById("forceMode").value = "geometric";

document.getElementById("fixture").addEventListener("change", (e) => {
  reloadFixture(e.target.value);
});
document.getElementById("btnReset").addEventListener("click", resetPose);
document.getElementById("btnPause").addEventListener("click", () => {
  running = !running;
  document.getElementById("btnPause").textContent = running ? "Pause" : "Resume";
});
document.getElementById("btnHeal").addEventListener("click", () => {
  const healed = healYawThrusters(control);
  jsonArea.value = JSON.stringify(control, null, 2);
  fillThrusterEditor();
  statusEl.textContent = healed ? "Healed weak yaw levers" : "No heal needed";
});
document.getElementById("btnAddThruster").addEventListener("click", addThruster);
document.getElementById("btnRemoveThruster").addEventListener("click", removeThruster);
document.getElementById("btnApplyJson").addEventListener("click", applyJson);
document.getElementById("btnSampleJson").addEventListener("click", () => {
  jsonArea.value = sampleBoatControlJson();
  applyJson();
});
document.getElementById("thrusterSel").addEventListener("change", (e) => {
  selectedThruster = Number(e.target.value) || 0;
  fillThrusterEditor();
});
["t_lx", "t_ly", "t_lz", "t_force", "t_facing", "t_ang"].forEach((id) => {
  document.getElementById(id).addEventListener("change", commitThrusterEditor);
});

window.addEventListener("keydown", (e) => {
  const k = e.key.toLowerCase();
  if ("wasdzc".includes(k)) {
    held[k] = true;
    e.preventDefault();
  }
  if (k === "x") {
    Object.keys(held).forEach((key) => {
      held[key] = false;
    });
  }
  if (k === "r") resetPose();
});
window.addEventListener("keyup", (e) => {
  const k = e.key.toLowerCase();
  if ("wasdzc".includes(k)) {
    held[k] = false;
    e.preventDefault();
  }
});

jsonArea.value = JSON.stringify(control, null, 2);
fillThrusterEditor();
statusEl.textContent =
  `Default: ${DEFAULT_FIXTURE} · buoyancy+CoM · W/S A/D Z/C · X stop · R reset`;
requestAnimationFrame(frame);
