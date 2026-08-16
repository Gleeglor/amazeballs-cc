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
  // Cannon / non-boat roles — never win discovery when scores are otherwise tied at 0.
  const cannonish =
    names.has("hub.lua") || names.has("fire.lua") || names.has("ammo.lua");
  const boatish =
    names.has("boat.lua") ||
    names.has("boat_control.json") ||
    names.has("test_agent.lua") ||
    (names.has("lib") && fs.existsSync(path.join(dir, "lib", "drive.lua")));
  if (cannonish && !boatish) score -= 100;
  return score;
}

/** Minimum score to treat a computer as a boat candidate (not cannon fallback). */
export const MIN_BOAT_SCORE = 25;

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
 * Local discover only applies to FS mode — multiplayer boats are not on this disk.
 */
export function resolveComputer(opts = {}) {
  const { config } = loadBridgeConfig();
  const mode = String(opts.mode || config?.mode || "fs").toLowerCase();
  if (mode === "http") {
    throw new Error(
      'bridge.json mode is "http" — local saves will not contain the multiplayer boat. Use openSession() / npm test with the HTTP server (npm run serve).',
    );
  }

  const minecraftRoot = opts.minecraftRoot || config?.root || defaultMinecraftRoot();
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
  const boatish = all.filter((c) => c.score >= MIN_BOAT_SCORE);
  const pick = boatish[0] ?? null;
  if (!pick) {
    const hint =
      all.length === 0
        ? `No CC computers under ${path.join(minecraftRoot, "saves")} (expected for multiplayer — use bridge.json "mode":"http").`
        : `Found ${all.length} local computer(s) but none look like a boat (cannon hubs only). Local discover cannot see a multiplayer boat. Highest score=${all[0].score} at world=${JSON.stringify(all[0].world)} id=${all[0].id}.`;
    throw new Error(
      `${hint} For MP: set bridge.json mode=http, npm run serve, put /realtime_bridge.json on the boat with base_url. For SP: open boat computer, npm run list, deploy_to_computer.mjs.`,
    );
  }
  return { ...pick, source: "discover", all };
}
