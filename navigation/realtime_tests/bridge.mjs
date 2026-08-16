/**
 * Filesystem bridge: write realtime_inbox.json, wait for matching outbox.
 */
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const INBOX = "realtime_inbox.json";
const OUTBOX = "realtime_outbox.json";
const STATUS = "realtime_status.json";

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function readJson(file) {
  try {
    if (!fs.existsSync(file)) return null;
    const raw = fs.readFileSync(file, "utf8");
    if (!raw || !raw.trim()) return null;
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function writeJsonAtomic(file, data) {
  const tmp = file + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + "\n", "utf8");
  fs.renameSync(tmp, file);
}

export function readStatus(computerDir) {
  return readJson(path.join(computerDir, STATUS));
}

/**
 * Send a command and wait for outbox with same id.
 * @param {string} computerDir
 * @param {object} cmd fields: cmd, plus args
 * @param {{ timeoutMs?: number, pollMs?: number }} [opts]
 */
export async function sendCommand(computerDir, cmd, opts = {}) {
  const timeoutMs = opts.timeoutMs ?? 20000;
  const pollMs = opts.pollMs ?? 100;
  const id = cmd.id || crypto.randomUUID();
  const payload = { ...cmd, id };

  const inboxPath = path.join(computerDir, INBOX);
  const outboxPath = path.join(computerDir, OUTBOX);

  // Clear stale outbox with same id if any
  const stale = readJson(outboxPath);
  if (stale && stale.id === id) {
    try {
      fs.unlinkSync(outboxPath);
    } catch {
      /* ignore */
    }
  }

  writeJsonAtomic(inboxPath, payload);

  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    const out = readJson(outboxPath);
    if (out && out.id === id) {
      return out;
    }
    await sleep(pollMs);
  }
  throw new Error(
    `Timeout waiting for outbox id=${id} cmd=${payload.cmd} (${timeoutMs}ms). Is test_agent running on the boat?`,
  );
}

export async function stopMotors(computerDir, opts) {
  return sendCommand(computerDir, { cmd: "stop" }, opts);
}

export async function ping(computerDir, opts) {
  return sendCommand(computerDir, { cmd: "ping" }, { timeoutMs: 8000, ...opts });
}
