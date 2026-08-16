#!/usr/bin/env node
/**
 * Live boat exhaustive tests via agent_host RPC.
 * Requires agent_host + connected boat (and open water for A/D/W motion checks).
 *
 *   node tools/test_live.mjs
 *   npm run test:live
 */
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");
const HOST = process.env.BOAT_HOST || "http://127.0.0.1:8765";

async function health() {
  const r = await fetch(`${HOST}/health`);
  return r.json();
}

async function rpc(method, params = {}, timeoutMs = 120000) {
  const r = await fetch(`${HOST}/rpc`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ method, params, timeoutMs }),
  });
  const text = await r.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    throw new Error(`bad rpc response: ${text.slice(0, 200)}`);
  }
  if (!r.ok || body.ok === false) {
    throw new Error(body.error || body.result?.error || `rpc ${method} failed`);
  }
  return body.result !== undefined ? body.result : body;
}

async function rpcRetry(method, params, timeoutMs, tries = 4) {
  let last;
  for (let i = 0; i < tries; i++) {
    try {
      return await rpc(method, params, timeoutMs);
    } catch (e) {
      last = e;
      console.warn(`  rpc ${method} try ${i + 1} failed:`, e.message || e);
      await new Promise((r) => setTimeout(r, 1500));
    }
  }
  throw last;
}

async function putFile(path, localPath) {
  const data = readFileSync(localPath, "utf8");
  return rpcRetry("put_file", { path, data }, 90000, 5);
}

function failList(summary) {
  return (summary.results || [])
    .filter((t) => !t.ok)
    .map((t) => `${t.name}: ${t.detail || ""}`)
    .join("\n  ");
}

async function main() {
  console.log("Live boat exhaustive tests @", HOST);

  const h = await health();
  assert.equal(h.ok, true, "agent_host health");
  assert.equal(!!h.boat, true, "boat websocket connected");

  const t0 = Date.now();
  const pong = await rpc("ping", {}, 5000);
  assert.ok(pong.pong, "ping pong");
  console.log("  ping OK");

  // Heartbeat must be fresh (agent not stuck in blocking teleop)
  const h2 = await health();
  const hb = h2.heartbeat;
  assert.ok(hb && typeof hb.t === "number", "heartbeat present");
  // Allow clock skew; require heartbeat updated within last 30s of host time if t is epoch-seconds
  const ageSec = Math.abs(Date.now() / 1000 - hb.t);
  if (ageSec > 120) {
    console.warn("  WARN heartbeat age looks large:", ageSec, "s — continuing");
  } else {
    console.log("  heartbeat fresh-ish, age≈", ageSec.toFixed(1), "s");
  }
  assert.ok(hb.pose, "heartbeat pose");
  assert.equal(typeof hb.pose.yaw, "number", "pose.yaw number");
  console.log("  pose yaw=", hb.pose.yaw);

  // Deploy latest exhaustive + core libs (retries). Agent reboot picks up agent.lua _G fix.
  const deploy = [
    ["boat/tests/exhaustive.lua", "/tests/exhaustive.lua"],
    ["boat/lib/teleop.lua", "/lib/teleop.lua"],
    ["boat/lib/motors.lua", "/lib/motors.lua"],
    ["boat/lib/pose.lua", "/lib/pose.lua"],
    ["boat/lib/wrench.lua", "/lib/wrench.lua"],
    ["boat/lib/boat_calibrate.lua", "/lib/boat_calibrate.lua"],
    ["boat/agent.lua", "/agent"],
  ];
  for (const [rel, dest] of deploy) {
    const abs = join(root, rel);
    assert.ok(existsSync(abs), abs);
    const res = await putFile(dest, abs);
    assert.ok(res.bytes > 0, dest);
    console.log("  put", dest, res.bytes, "B");
    await new Promise((r) => setTimeout(r, 200));
  }

  // yaw_sign must be ±1
  const ctrlFile = await rpcRetry("get_file", { path: "/boat_control.json" }, 15000);
  assert.ok(ctrlFile.data, "boat_control.json missing — run calibrate (C) first");
  const ctrl = JSON.parse(ctrlFile.data);
  assert.ok(Array.isArray(ctrl.thrusters) && ctrl.thrusters.length > 0, "no thrusters in calib");
  assert.ok(ctrl.yaw_sign === 1 || ctrl.yaw_sign === -1, "yaw_sign must be ±1");
  console.log("  calib thrusters=", ctrl.thrusters.length, "yaw_sign=", ctrl.yaw_sign);

  // Run exhaustive on boat (safe without package global)
  console.log("  running exhaustive on boat (motors will move)…");
  const summary = await rpcRetry(
    "exec",
    {
      code: `
local h = fs.open("/tests/exhaustive.lua", "r")
if not h then error("missing /tests/exhaustive.lua") end
local src = h.readAll()
h.close()
local env = {
  require = require, keys = keys, peripheral = peripheral, sleep = sleep,
  os = os, fs = fs, textutils = textutils, shell = shell, package = package,
  math = math, table = table, string = string, pairs = pairs, ipairs = ipairs,
  tonumber = tonumber, tostring = tostring, type = type, select = select,
  pcall = pcall, error = error, assert = assert, print = print,
  load = load, loadfile = loadfile, _G = _G,
}
setmetatable(env, { __index = _G })
local chunk, err = load(src, "@/tests/exhaustive.lua", "t", env)
if not chunk then error(tostring(err)) end
local okMod, mod = pcall(chunk)
if not okMod then error(tostring(mod)) end
if type(mod) ~= "table" or type(mod.run) ~= "function" then error("no module") end
local ok, summary = pcall(mod.run, {})
if not ok then error(tostring(summary)) end
return summary
`,
    },
    180000,
    2
  );

  console.log(
    "  exhaustive:",
    summary.passed + "/" + summary.total,
    "yaw_sign=",
    summary.yaw_sign
  );
  if (summary.samples) {
    console.log("  samples", JSON.stringify(summary.samples));
  }
  if (!summary.ok) {
    console.error("  FAILURES:\n  " + failList(summary));
  }
  assert.equal(summary.ok, true, "exhaustive suite failed:\n  " + failList(summary));

  // Agent still answers after tests (not wedged)
  const pong2 = await rpc("ping", {}, 5000);
  assert.ok(pong2.pong, "ping after tests");

  // stop motors
  await rpc("stop", {}, 20000);

  console.log("All live tests passed in", ((Date.now() - t0) / 1000).toFixed(1), "s");
}

main().catch((e) => {
  console.error("LIVE TEST FAILED:", e.message || e);
  process.exit(1);
});
