/**
 * Discover CC:Tweaked computer folders under Prism/Minecraft saves.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/** Default: Amazeballs instance minecraft/ next to cc-scripts/. */
export function defaultMinecraftRoot() {
  // realtime_tests/ → navigation/ → cc-scripts/ → minecraft/
  return path.resolve(__dirname, "../../..");
}

export function loadBridgeConfig(minecraftRoot = defaultMinecraftRoot()) {
  const cfgPath = path.join(__dirname, "bridge.json");
  if (!fs.existsSync(cfgPath)) return { path: cfgPath, config: null };
  const config = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
  return { path: cfgPath, config };
}

function scoreComputer(dir) {
  let score = 0;
  const names = new Set(fs.readdirSync(dir));
  if (names.has("boat.lua")) score += 50;
  if (names.has("boat_control.json")) score += 40;
  if (names.has("test_agent.lua")) score += 30;
  if (names.has("realtime_status.json")) score += 20;
  if (names.has("lib") && fs.existsSync(path.join(dir, "lib", "drive.lua"))) score += 25;
  if (names.has("calibrate.lua")) score += 5;
  return score;
}

/**
 * @returns {{ world: string, id: string, dir: string, score: number }[]}
 */
export function discoverComputers(minecraftRoot = defaultMinecraftRoot()) {
  const saves = path.join(minecraftRoot, "saves");
  if (!fs.existsSync(saves)) return [];
  const found = [];
  for (const world of fs.readdirSync(saves)) {
    const computers = path.join(saves, world, "computercraft", "computer");
    if (!fs.existsSync(computers)) continue;
    for (const id of fs.readdirSync(computers)) {
      const dir = path.join(computers, id);
      if (!fs.statSync(dir).isDirectory()) continue;
      if (!/^\d+$/.test(id)) continue;
      found.push({
        world,
        id,
        dir,
        score: scoreComputer(dir),
      });
    }
  }
  found.sort((a, b) => b.score - a.score || a.world.localeCompare(b.world));
  return found;
}

/**
 * Resolve target computer dir from bridge.json or CLI / discovery.
 */
export function resolveComputer(opts = {}) {
  const minecraftRoot = opts.minecraftRoot || defaultMinecraftRoot();
  const { config } = loadBridgeConfig(minecraftRoot);
  const world = opts.world || config?.world || null;
  const id = opts.computerId != null ? String(opts.computerId) : config?.computer_id != null ? String(config.computer_id) : null;

  if (world != null && id != null) {
    const dir = path.join(minecraftRoot, "saves", world, "computercraft", "computer", id);
    if (!fs.existsSync(dir)) {
      throw new Error(`Computer path missing: ${dir}`);
    }
    return { world, id, dir, score: scoreComputer(dir), source: "config" };
  }

  const all = discoverComputers(minecraftRoot);
  if (opts.listOnly) return { all };
  const boatish = all.filter((c) => c.score >= 25);
  const pick = (boatish[0] || all[0]) ?? null;
  if (!pick) {
    throw new Error(
      `No CC computers under ${path.join(minecraftRoot, "saves")}. Create bridge.json with world + computer_id.`,
    );
  }
  return { ...pick, source: "discover", all };
}
