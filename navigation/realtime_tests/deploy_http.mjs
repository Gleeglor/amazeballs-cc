/**
 * Deploy navigation Lua to the live boat over the HTTP bridge (no updater).
 *
 * Requires test_agent with write_file / sync_tree (once on boat). Bootstrap:
 *   wget <boat_base_url>/v1/repo/navigation/test_agent.lua test_agent
 *   test_agent
 *
 * Usage:
 *   node deploy_http.mjs
 *   node deploy_http.mjs --reboot
 *   node deploy_http.mjs --no-ping
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { openSession, resolveBridgeMode } from "./bridge.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const NAV = path.resolve(__dirname, "..");
const CC_SCRIPTS = path.resolve(NAV, "..");

/** Same set as deploy_to_computer.mjs / test_agent WRITE_ALLOW */
export const DEPLOY_FILES = [
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

const CHUNK = 48_000;

function loadFiles() {
  const out = [];
  for (const [srcRel, destRel] of DEPLOY_FILES) {
    const src = path.join(NAV, srcRel);
    if (!fs.existsSync(src)) {
      console.warn("skip missing", srcRel);
      continue;
    }
    out.push({ path: destRel, content: fs.readFileSync(src, "utf8"), bytes: fs.statSync(src).size });
  }
  return out;
}

function parseArgs(argv) {
  const out = { reboot: false, ping: true };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--reboot") out.reboot = true;
    else if (argv[i] === "--no-ping") out.ping = false;
    else if (argv[i] === "--help" || argv[i] === "-h") out.help = true;
  }
  return out;
}

function bootstrapHint(session) {
  const boatUrl =
    process.env.BOAT_BASE_URL ||
    process.env.PUBLIC_BASE_URL ||
    "(same base_url as /realtime_bridge.json — not 127.0.0.1)";
  return [
    "Boat agent lacks write_file/sync_tree. One-time bootstrap ON THE BOAT computer:",
    "",
    "  wget https://raw.githubusercontent.com/Gleeglor/amazeballs-cc/main/navigation/test_agent.lua test_agent",
    "  test_agent",
    "",
    "Or via the live bridge (use boat base_url, not loopback):",
    `  wget ${boatUrl}/v1/repo/navigation/test_agent.lua test_agent`,
    "  test_agent",
    "",
    "Then: npm run deploy   (host owns updates afterward; no more updater).",
  ].join("\n");
}

/**
 * @param {ReturnType<typeof openSession>} session
 * @param {{ reboot?: boolean, quiet?: boolean }} [opts]
 */
export async function deployViaBridge(session, opts = {}) {
  const files = loadFiles();
  if (!files.length) {
    throw new Error("No deploy files found under navigation/");
  }

  if (!opts.quiet) {
    console.log(`Deploy ${files.length} files via ${session.describe()} (${session.mode})`);
  }

  // Probe capability (empty sync is enough)
  const probe = await session.sendCommand({ cmd: "sync_tree", files: [] }, { timeoutMs: 15000 });
  if (!probe.ok && /unknown cmd/i.test(String(probe.error || ""))) {
    const e = new Error(bootstrapHint(session));
    e.code = "NEED_BOOTSTRAP";
    throw e;
  }
  if (!probe.ok) {
    const e = new Error(
      /unknown/i.test(String(probe.error || ""))
        ? bootstrapHint(session)
        : `sync_tree probe failed: ${probe.error || "unknown"}`,
    );
    if (/unknown/i.test(String(probe.error || ""))) e.code = "NEED_BOOTSTRAP";
    throw e;
  }

  const written = [];
  for (const file of files) {
    // Large files: chunked append
    if (file.content.length > CHUNK) {
      let offset = 0;
      let part = 0;
      while (offset < file.content.length) {
        const slice = file.content.slice(offset, offset + CHUNK);
        const r = await session.sendCommand(
          {
            cmd: "write_file",
            path: file.path,
            content: slice,
            append: part > 0,
          },
          { timeoutMs: 30000 },
        );
        if (!r.ok) {
          if (/unknown cmd/i.test(String(r.error || ""))) {
            const e = new Error(bootstrapHint(session));
            e.code = "NEED_BOOTSTRAP";
            throw e;
          }
          throw new Error(`write_file ${file.path} part ${part}: ${r.error || "failed"}`);
        }
        offset += CHUNK;
        part += 1;
      }
      written.push({ path: file.path, size: file.bytes, chunks: part });
      if (!opts.quiet) console.log(`  wrote ${file.path} (${file.bytes} B, ${part} chunks)`);
    } else {
      const r = await session.sendCommand(
        { cmd: "write_file", path: file.path, content: file.content },
        { timeoutMs: 30000 },
      );
      if (!r.ok) {
        if (/unknown cmd/i.test(String(r.error || ""))) {
          const e = new Error(bootstrapHint(session));
          e.code = "NEED_BOOTSTRAP";
          throw e;
        }
        throw new Error(`write_file ${file.path}: ${r.error || "failed"}`);
      }
      written.push({ path: file.path, size: r.result?.size ?? file.bytes });
      if (!opts.quiet) console.log(`  wrote ${file.path} (${file.bytes} B)`);
    }
  }

  if (opts.reboot) {
    if (!opts.quiet) console.log("Rebooting boat computer (startup should re-run test_agent)…");
    try {
      await session.sendCommand({ cmd: "reboot" }, { timeoutMs: 8000 });
    } catch {
      // reboot may drop the result POST — expected
    }
    await new Promise((r) => setTimeout(r, 8000));
  }

  return { written, files: files.length };
}

export async function deployMain(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  if (args.help) {
    console.log(`Usage: node deploy_http.mjs [--reboot] [--no-ping]
Deploys navigation/*.lua + lib/*.lua to the live agent over the bridge.
Repo root for wget bootstrap: ${CC_SCRIPTS}`);
    return 0;
  }

  const mode = resolveBridgeMode();
  const session = openSession({});
  console.log(`Bridge: ${session.describe()} (mode=${mode})`);

  if (args.ping) {
    const p = await session.ping({ timeoutMs: 10000 });
    if (!p.ok) {
      console.error("ping failed — is test_agent running?", p.error);
      return 1;
    }
    console.log(`ping ok computer_id=${p.result?.computer_id}`);
  }

  try {
    const result = await deployViaBridge(session, { reboot: args.reboot });
    console.log(`Deployed ${result.written.length} files.`);
  } catch (e) {
    console.error(String(e.message || e));
    return e.code === "NEED_BOOTSTRAP" ? 3 : 1;
  }

  if (args.reboot || args.ping) {
    // Wait for agent after optional reboot
    const deadline = Date.now() + (args.reboot ? 45000 : 12000);
    let okPing = false;
    while (Date.now() < deadline) {
      try {
        const p = await session.ping({ timeoutMs: 5000 });
        if (p.ok) {
          okPing = true;
          console.log(`post-deploy ping ok computer_id=${p.result?.computer_id}`);
          break;
        }
      } catch {
        /* retry */
      }
      await new Promise((r) => setTimeout(r, 1500));
    }
    if (!okPing) {
      console.warn("WARNING: no ping after deploy — run test_agent on the boat if needed.");
      return 2;
    }
  }
  return 0;
}

const isMain =
  process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  deployMain().then((code) => process.exit(code));
}
