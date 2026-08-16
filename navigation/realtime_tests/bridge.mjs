/**
 * Realtime bridge: filesystem (local SP / sshfs) or HTTP poll (multiplayer).
 *
 * Prefer openSession() from run_tests / overnight. Legacy sendCommand(computerDir, …)
 * still works for FS-only callers.
 */
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { loadBridgeConfig, resolveComputer, defaultMinecraftRoot } from "./discover.mjs";

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
 * Send a command via filesystem and wait for matching outbox.
 * @param {string} computerDir
 * @param {object} cmd
 * @param {{ timeoutMs?: number, pollMs?: number }} [opts]
 */
export async function sendCommand(computerDir, cmd, opts = {}) {
  const timeoutMs = opts.timeoutMs ?? 20000;
  const pollMs = opts.pollMs ?? 100;
  const id = cmd.id || crypto.randomUUID();
  const payload = { ...cmd, id };

  const inboxPath = path.join(computerDir, INBOX);
  const outboxPath = path.join(computerDir, OUTBOX);

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

function normalizeBaseUrl(url) {
  return String(url || "").replace(/\/+$/, "");
}

async function httpJson(method, url, body, opts = {}) {
  const timeoutMs = opts.timeoutMs ?? 8000;
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const headers = {};
    if (body != null) headers["Content-Type"] = "application/json";
    if (opts.lockToken) headers["X-Host-Lock"] = opts.lockToken;
    if (opts.headers && typeof opts.headers === "object") {
      Object.assign(headers, opts.headers);
    }
    const init = {
      method,
      signal: ctrl.signal,
      headers: Object.keys(headers).length ? headers : undefined,
      body: body != null ? JSON.stringify(body) : undefined,
    };
    const res = await fetch(url, init);
    const text = await res.text();
    let data = null;
    if (text && text.trim()) {
      try {
        data = JSON.parse(text);
      } catch {
        data = { raw: text };
      }
    }
    return { ok: res.ok, status: res.status, data };
  } finally {
    clearTimeout(t);
  }
}

const TIMEOUT_HINTS = [
  "Boat must use LAN IP or tunnel in /realtime_bridge.json — never 127.0.0.1 (CC http runs on the MC server).",
  "If MC server is a remote VPS (not on your LAN), LAN IPs like 192.168.x.x are unreachable — use ngrok/cloudflare tunnel.",
  "CC http.rules: allow host:port ABOVE host=$private deny; restart/reload after edit.",
  "Host firewall if needed: sudo ufw allow 8765/tcp",
  "Confirm npm run serve is listening (ss -tlnp | grep 8765) and boat prints HTTP errors each poll.",
];

async function printHttpTimeoutDiagnostics(base) {
  console.error("\n--- HTTP bridge timeout diagnostics ---");
  for (const h of TIMEOUT_HINTS) {
    console.error(`  • ${h}`);
  }
  try {
    const health = await httpJson("GET", `${base}/v1/health`, null, { timeoutMs: 2000 });
    if (health.ok && health.data) {
      console.error(
        `  health: agent_alive=${health.data.agent_alive} age_ms=${health.data.agent_age_ms} pending=${JSON.stringify(health.data.pending)}`,
      );
    }
  } catch (e) {
    console.error(`  health fetch failed: ${e.message || e}`);
  }
  try {
    const log = await httpJson("GET", `${base}/v1/accesslog?n=15`, null, { timeoutMs: 2000 });
    const lines = log.data?.lines || [];
    if (lines.length) {
      console.error("  last server access log:");
      for (const line of lines) console.error(`    ${line}`);
      const boatish = lines.some((l) => /\/v1\/(cmd|status|result)/.test(l) && !/127\.0\.0\.1|::1/.test(l));
      if (!boatish) {
        console.error(
          "  → No non-loopback agent hits in access log. Boat is not reaching this host (wrong base_url, $private deny, firewall, or need tunnel).",
        );
      }
    } else {
      console.error("  access log empty (restart serve to enable request logging, or no requests yet).");
    }
  } catch (e) {
    console.error(`  accesslog fetch failed: ${e.message || e}`);
  }
  console.error("---\n");
}

/**
 * HTTP session: talks to local http_server (loopback). Boat polls the same server.
 * Acquires /v1/lock so rival host clients cannot supersede mid-command.
 */
export function createHttpSession(opts = {}) {
  const { config } = loadBridgeConfig();
  const base = normalizeBaseUrl(
    opts.baseUrl || opts.base_url || config?.base_url || "http://127.0.0.1:8765",
  );
  const lockToken = opts.lockToken || opts.lock_token || crypto.randomUUID();
  let lockReady = null;

  async function ensureLock(ttlMs = 600_000) {
    if (lockReady) return lockReady;
    lockReady = (async () => {
      const put = await httpJson(
        "POST",
        `${base}/v1/lock`,
        { token: lockToken, ttlMs },
        { timeoutMs: 5000 },
      );
      if (!put.ok) {
        throw new Error(
          `host lock failed (${put.status}): ${put.data?.error || JSON.stringify(put.data)}`,
        );
      }
      return put.data;
    })();
    return lockReady;
  }

  async function renewLock(ttlMs = 600_000) {
    await httpJson(
      "POST",
      `${base}/v1/lock`,
      { token: lockToken, ttlMs },
      { timeoutMs: 5000 },
    );
  }

  async function unlock() {
    try {
      await httpJson(
        "POST",
        `${base}/v1/unlock`,
        { token: lockToken },
        { timeoutMs: 3000, lockToken },
      );
    } catch {
      /* ignore */
    }
    lockReady = null;
  }

  async function send(cmd, sendOpts = {}) {
    const timeoutMs = sendOpts.timeoutMs ?? 20000;
    const pollMs = sendOpts.pollMs ?? 100;
    const id = cmd.id || crypto.randomUUID();
    const payload = { ...cmd, id };

    await ensureLock(Math.max(120_000, timeoutMs + 60_000));
    await renewLock(Math.max(120_000, timeoutMs + 60_000));

    const put = await httpJson("POST", `${base}/v1/inbox`, payload, {
      timeoutMs: 5000,
      lockToken,
    });
    if (!put.ok) {
      throw new Error(
        `HTTP inbox failed (${put.status}): ${put.data?.error || JSON.stringify(put.data)}. Is npm run serve running?`,
      );
    }

    const t0 = Date.now();
    while (Date.now() - t0 < timeoutMs) {
      const got = await httpJson("GET", `${base}/v1/result?id=${encodeURIComponent(id)}`, null, {
        timeoutMs: 5000,
      });
      if (got.ok && got.data && got.data.id === id) {
        return got.data;
      }
      await sleep(pollMs);
    }
    await printHttpTimeoutDiagnostics(base);
    // Clear stuck pending so the next command (and a reborn agent) is not blocked.
    try {
      await httpJson(
        "POST",
        `${base}/v1/result`,
        { id, ok: false, error: "host_timeout", cmd: payload.cmd },
        { timeoutMs: 2000 },
      );
      await httpJson("POST", `${base}/v1/clear`, {}, { timeoutMs: 2000, lockToken });
    } catch {
      /* ignore */
    }
    throw new Error(
      `Timeout waiting for HTTP result id=${id} cmd=${payload.cmd} (${timeoutMs}ms). Is test_agent (HTTP mode) reaching this host?`,
    );
  }

  return {
    mode: "http",
    baseUrl: base,
    lockToken,
    describe() {
      return `http ${base}`;
    },
    async readStatus() {
      const got = await httpJson("GET", `${base}/v1/status`, null, { timeoutMs: 4000 });
      return got.data;
    },
    ensureLock,
    unlock,
    sendCommand: send,
    stopMotors: (o) => send({ cmd: "stop" }, o),
    ping: (o) => send({ cmd: "ping" }, { timeoutMs: 8000, ...o }),
  };
}

/**
 * Filesystem session (local saves or sshfs root).
 */
export function createFsSession(computerDir, meta = {}) {
  return {
    mode: "fs",
    dir: computerDir,
    world: meta.world,
    id: meta.id,
    describe() {
      return `fs ${computerDir}`;
    },
    readStatus: () => readStatus(computerDir),
    sendCommand: (cmd, opts) => sendCommand(computerDir, cmd, opts),
    stopMotors: (opts) => stopMotors(computerDir, opts),
    ping: (opts) => ping(computerDir, opts),
  };
}

/**
 * Open bridge session from bridge.json (mode http | fs).
 * Does not invent a remote boat via local discover when mode=http.
 */
export function openSession(opts = {}) {
  const { config } = loadBridgeConfig();
  const mode = String(opts.mode || config?.mode || "fs").toLowerCase();

  if (mode === "http") {
    return createHttpSession({
      baseUrl: opts.baseUrl || opts.base_url || config?.base_url,
    });
  }

  if (mode === "fs") {
    const minecraftRoot = opts.minecraftRoot || config?.root || defaultMinecraftRoot();
    if (config?.root && !opts.minecraftRoot) {
      // bridge.json root = sshfs (or other) mount that already contains computer/
      // Expect either .../computer/<id> or a saves tree under root.
      const root = config.root;
      if (opts.computerId != null || config.computer_id != null) {
        const id = String(opts.computerId ?? config.computer_id);
        const direct = path.join(root, id);
        const nested = path.join(root, "computercraft", "computer", id);
        const dir = fs.existsSync(direct)
          ? direct
          : fs.existsSync(nested)
            ? nested
            : path.join(root, "saves", config.world || "", "computercraft", "computer", id);
        if (!fs.existsSync(dir)) {
          throw new Error(
            `FS mode root computer missing: tried ${direct}, ${nested}, and saves path. Mount sshfs and set bridge.json root + computer_id.`,
          );
        }
        return createFsSession(dir, { world: config.world || "(sshfs)", id, source: "config.root" });
      }
    }
    const target = resolveComputer({
      mode: "fs",
      world: opts.world,
      computerId: opts.computerId,
      minecraftRoot,
    });
    return createFsSession(target.dir, target);
  }

  throw new Error(`Unknown bridge mode "${mode}" (use "http" or "fs")`);
}

export function resolveBridgeMode() {
  const { config } = loadBridgeConfig();
  return String(config?.mode || "fs").toLowerCase();
}
