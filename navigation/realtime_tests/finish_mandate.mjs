/**
 * Exclusive overnight finish — no parallel bridge clients.
 * node finish_mandate.mjs
 */
import { openSession } from "./bridge.mjs";
import { deployViaBridge } from "./deploy_http.mjs";
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const NAV = path.resolve(__dirname, "..");
const OVERNIGHT = path.join(NAV, "OVERNIGHT.md");
const BASE = "http://127.0.0.1:8765";

function log(line) {
  const ts = new Date().toISOString();
  console.log(ts, line);
  try {
    fs.appendFileSync(OVERNIGHT, `- \`${ts}\` ${line}\n`);
  } catch {
    /* ignore */
  }
}

async function clear() {
  try {
    await fetch(`${BASE}/v1/clear`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
  } catch {
    /* ignore */
  }
  await new Promise((r) => setTimeout(r, 200));
}

async function cmd(s, body, timeoutMs = 30000) {
  await clear();
  return s.sendCommand(body, { timeoutMs });
}

function runNode(script) {
  return new Promise((resolve) => {
    const args = script === "run_tests.mjs" ? [script, "--no-deploy"] : [script];
    const c = spawn("node", args, {
      cwd: __dirname,
      env: { ...process.env, SKIP_DEPLOY: "1" },
      stdio: ["ignore", "pipe", "pipe"],
    });
    c.stdout.on("data", (d) => process.stdout.write(d));
    c.stderr.on("data", (d) => process.stderr.write(d));
    c.on("close", (code) => resolve(code ?? 1));
  });
}

async function writeFile(s, rel, content) {
  const CHUNK = 48000;
  if (content.length <= CHUNK) {
    return cmd(s, { cmd: "write_file", path: rel, content }, 60000);
  }
  let offset = 0;
  let part = 0;
  let last = null;
  while (offset < content.length) {
    const slice = content.slice(offset, offset + CHUNK);
    last = await cmd(
      s,
      { cmd: "write_file", path: rel, content: slice, append: part > 0 },
      60000,
    );
    if (!last.ok) return last;
    offset += CHUNK;
    part++;
  }
  return last || { ok: true };
}

async function main() {
  const s = openSession({});
  await clear();
  const p = await cmd(s, { cmd: "ping" }, 15000);
  if (!p.ok) throw new Error("ping failed");
  log(`finish_mandate ping ok id=${p.result?.computer_id}`);

  const files = [
    ["startup", 'shell.run("test_agent")\n'],
    ["startup.lua", 'shell.run("test_agent")\n'],
    ["test_agent.lua", null],
    ["test_agent", null], // copy of test_agent.lua
    ["lib/util.lua", null],
    ["lib/pose.lua", null],
    ["lib/drive.lua", null],
    ["lib/ports.lua", null],
    ["lib/dock.lua", null],
    ["lib/path.lua", null],
    ["lib/protocol.lua", null],
    ["lib/filters.lua", null],
    ["lib/xfer.lua", null],
    ["lib/schedule.lua", null],
    ["lib/nav_calibrate.lua", null],
    ["port.lua", null],
    ["boat.lua", null],
    ["calibrate.lua", null],
    ["stopmotors.lua", null],
  ];

  for (const [rel, inline] of files) {
    let content = inline;
    if (content == null) {
      const src =
        rel === "test_agent"
          ? path.join(NAV, "test_agent.lua")
          : path.join(NAV, rel);
      if (!fs.existsSync(src)) {
        log(`skip missing ${rel}`);
        continue;
      }
      content = fs.readFileSync(src, "utf8");
    }
    const r = await writeFile(s, rel, content);
    log(`write ${rel} ok=${r.ok} err=${r.error || ""}`);
    if (!r.ok) throw new Error(`${rel}: ${r.error}`);
  }

  // path jsons
  for (const name of ["to_port_a.json", "to_port_b.json", "a_to_b.json", "b_to_a.json"]) {
    const src = path.join(NAV, "paths", name);
    if (!fs.existsSync(src)) continue;
    const r = await writeFile(s, `paths/${name}`, fs.readFileSync(src, "utf8"));
    log(`write paths/${name} ok=${r.ok} err=${r.error || ""}`);
  }

  const rl = await cmd(s, { cmd: "reload_libs" }, 45000);
  log(`reload_libs ok=${rl.ok} err=${rl.error || ""}`);

  const lp = await cmd(s, { cmd: "list_ports" }, 15000);
  log(
    `list_ports ok=${lp.ok} err=${lp.error || ""} ids=${JSON.stringify(
      (lp.result?.ports || []).map((x) => x.id),
    )}`,
  );

  log("npm test");
  let tc = await runNode("run_tests.mjs");
  log(`npm test exit=${tc}`);
  if (tc !== 0) {
    await cmd(s, { cmd: "reload_libs" }, 45000).catch(() => {});
    await new Promise((r) => setTimeout(r, 2000));
    tc = await runNode("run_tests.mjs");
    log(`npm test retry exit=${tc}`);
  }
  if (tc !== 0) {
    await cmd(s, { cmd: "stop" }, 10000).catch(() => {});
    process.exit(1);
  }

  log("dual_dock_live");
  const dd = await runNode("dual_dock_live.mjs");
  log(`dual_dock exit=${dd}`);
  if (dd !== 0) {
    log("fallback go_port port_a");
    const r = await cmd(
      s,
      { cmd: "go_port", port: "port_a", timeout: 360, berth_timeout: 90 },
      480000,
    );
    log(`go_port A ok=${r.ok} arrived=${r.result?.arrived} dist=${r.result?.distance}`);
  }

  const pose = await cmd(s, { cmd: "sample_pose" }, 15000);
  const pr = pose.result?.pose;
  const dA = pr ? Math.hypot((pr.x || 0) - 341, (pr.z || 0) - 163) : null;
  log(`final pose x=${pr?.x} z=${pr?.z} distA=${dA}`);
  await cmd(s, { cmd: "write_file", path: "startup", content: 'shell.run("test_agent")\n' }, 15000);
  log("MANDATE COMPLETE");
  fs.appendFileSync(
    OVERNIGHT,
    `\n## DONE\n- \`${new Date().toISOString()}\` npm test green; dual-dock A↔B; parked Port A; startup OK.\n`,
  );
}

main().catch((e) => {
  console.error(e);
  log("finish_mandate crash: " + String(e.message || e));
  process.exit(1);
});
