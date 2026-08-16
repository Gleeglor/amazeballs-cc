/**
 * Copy navigation Lua scripts into a CC computer folder (skip updater pull).
 * Usage: node deploy_to_computer.mjs [--world "New World"] [--id 0]
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { resolveComputer, defaultMinecraftRoot, discoverComputers } from "./discover.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const NAV = path.resolve(__dirname, "..");

const FILES = [
  ["test_agent.lua", "test_agent.lua"],
  ["boat.lua", "boat.lua"],
  ["calibrate.lua", "calibrate.lua"],
  ["stopmotors.lua", "stopmotors.lua"],
  ["lib/util.lua", "lib/util.lua"],
  ["lib/pose.lua", "lib/pose.lua"],
  ["lib/drive.lua", "lib/drive.lua"],
  ["lib/nav_calibrate.lua", "lib/nav_calibrate.lua"],
  ["lib/path.lua", "lib/path.lua"],
  ["lib/protocol.lua", "lib/protocol.lua"],
  ["lib/filters.lua", "lib/filters.lua"],
  ["lib/xfer.lua", "lib/xfer.lua"],
  ["lib/schedule.lua", "lib/schedule.lua"],
];

function copyTree(targetDir) {
  fs.mkdirSync(path.join(targetDir, "lib"), { recursive: true });
  const copied = [];
  for (const [srcRel, destRel] of FILES) {
    const src = path.join(NAV, srcRel);
    const dest = path.join(targetDir, destRel);
    if (!fs.existsSync(src)) {
      console.warn("skip missing", srcRel);
      continue;
    }
    fs.copyFileSync(src, dest);
    copied.push(destRel);
  }
  return copied;
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--world") out.world = argv[++i];
    else if (argv[i] === "--id") out.computerId = argv[++i];
    else if (argv[i] === "--all-empty") out.allEmpty = true;
    else if (argv[i] === "--list") out.list = true;
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
if (args.list) {
  for (const c of discoverComputers()) {
    console.log(`score=${c.score} world=${JSON.stringify(c.world)} id=${c.id}`);
  }
  process.exit(0);
}

if (args.allEmpty) {
  // Seed New World computer/0 if ids say next is 0 and folder missing — DO NOT invent IDs.
  console.log("Refusing to invent computer ids. Place/open a computer in-game, then:");
  console.log("  node deploy_to_computer.mjs --world \"New World\" --id 0");
  process.exit(1);
}

const target = resolveComputer({
  world: args.world,
  computerId: args.computerId,
  minecraftRoot: defaultMinecraftRoot(),
});
console.log(`Deploy → ${target.dir}`);
const copied = copyTree(target.dir);
console.log(`Copied ${copied.length} files. On the boat computer run: test_agent`);
