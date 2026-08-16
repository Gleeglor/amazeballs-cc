/**
 * HTTP poll bridge for multiplayer: host holds inbox; boat agent GETs cmds
 * and POSTs results/status. Local npm test talks to the same server over loopback.
 *
 *   node http_server.mjs
 *   node http_server.mjs --listen 0.0.0.0:8765
 */
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadBridgeConfig } from "./discover.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CC_SCRIPTS_ROOT = path.resolve(__dirname, "../..");

/** @type {{ pending: object|null, results: Map<string, object>, status: object|null, claimedId: string|null }} */
const state = {
  pending: null,
  results: new Map(),
  status: null,
  claimedId: null,
};

const MAX_RESULTS = 64;
const MAX_ACCESS_LOG = 80;
/** @type {string[]} */
const accessLog = [];

function remoteAddr(req) {
  const xf = req.headers["x-forwarded-for"];
  if (typeof xf === "string" && xf.trim()) return xf.split(",")[0].trim();
  return req.socket?.remoteAddress || "?";
}

function logAccess(req, pathname, code) {
  const line = `${new Date().toISOString()} ${req.method} ${pathname} from ${remoteAddr(req)} → ${code}`;
  accessLog.push(line);
  while (accessLog.length > MAX_ACCESS_LOG) accessLog.shift();
  console.log(line);
}

function json(res, code, body) {
  const raw = JSON.stringify(body);
  res.writeHead(code, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(raw),
    "Cache-Control": "no-store",
  });
  res.end(raw);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let n = 0;
    req.on("data", (c) => {
      n += c.length;
      if (n > 2_000_000) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      if (!raw.trim()) {
        resolve(null);
        return;
      }
      try {
        resolve(JSON.parse(raw));
      } catch (e) {
        reject(new Error("invalid JSON: " + e.message));
      }
    });
    req.on("error", reject);
  });
}

function parseListen(str) {
  const s = String(str || "0.0.0.0:8765").trim();
  if (s.startsWith("[")) {
    // [ipv6]:port
    const m = s.match(/^\[([^\]]+)\]:(\d+)$/);
    if (!m) throw new Error(`Bad listen address: ${s}`);
    return { host: m[1], port: Number(m[2]) };
  }
  const idx = s.lastIndexOf(":");
  if (idx <= 0) return { host: s, port: 8765 };
  return { host: s.slice(0, idx), port: Number(s.slice(idx + 1)) || 8765 };
}

function rememberResult(obj) {
  if (!obj?.id) return;
  state.results.set(String(obj.id), obj);
  while (state.results.size > MAX_RESULTS) {
    const first = state.results.keys().next().value;
    state.results.delete(first);
  }
}

/**
 * Host API used by bridge.mjs (same process or via HTTP).
 */
export function hostEnqueue(cmd) {
  if (!cmd || !cmd.id || !cmd.cmd) {
    throw new Error("enqueue requires { id, cmd, ... }");
  }
  const id = String(cmd.id);
  state.results.delete(id);
  state.pending = { ...cmd, id };
  state.claimedId = null;
  return state.pending;
}

export function hostGetResult(id) {
  return state.results.get(String(id)) || null;
}

export function hostGetStatus() {
  return state.status;
}

export function hostClearPending() {
  state.pending = null;
  state.claimedId = null;
}

async function handle(req, res) {
  const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
  const p = url.pathname.replace(/\/+$/, "") || "/";
  let code = 500;

  try {
    // --- Agent endpoints ---
    if (req.method === "GET" && (p === "/v1/cmd" || p === "/cmd")) {
      const pending = state.pending;
      if (!pending) {
        code = 200;
        json(res, code, { cmd: null });
        return;
      }
      // Hand out once per id (agent may poll while executing).
      if (state.claimedId === pending.id) {
        code = 200;
        json(res, code, { cmd: null, in_flight: pending.id });
        return;
      }
      state.claimedId = pending.id;
      code = 200;
      json(res, code, pending);
      return;
    }

    if (req.method === "POST" && (p === "/v1/result" || p === "/result" || p === "/outbox")) {
      const body = await readBody(req);
      if (!body || !body.id) {
        code = 400;
        json(res, code, { ok: false, error: "need { id, ... }" });
        return;
      }
      rememberResult(body);
      if (state.pending && String(state.pending.id) === String(body.id)) {
        state.pending = null;
        state.claimedId = null;
      }
      code = 200;
      json(res, code, { ok: true });
      return;
    }

    if (req.method === "POST" && (p === "/v1/status" || p === "/status")) {
      const body = (await readBody(req)) || {};
      state.status = { ...body, alive: body.alive !== false, recv_ts: Date.now() };
      code = 200;
      json(res, code, { ok: true });
      return;
    }

    if (req.method === "GET" && (p === "/v1/status" || p === "/status")) {
      code = 200;
      json(res, code, state.status || { alive: false });
      return;
    }

    // --- Host endpoints (npm test / overnight on this machine) ---
    if (req.method === "POST" && (p === "/v1/inbox" || p === "/inbox")) {
      const body = await readBody(req);
      try {
        const enq = hostEnqueue(body);
        code = 200;
        json(res, code, { ok: true, id: enq.id });
      } catch (e) {
        code = 400;
        json(res, code, { ok: false, error: String(e.message || e) });
      }
      return;
    }

    if (req.method === "GET" && (p === "/v1/result" || p === "/outbox")) {
      const id = url.searchParams.get("id");
      if (!id) {
        code = 400;
        json(res, code, { ok: false, error: "need ?id=" });
        return;
      }
      const got = hostGetResult(id);
      if (!got) {
        code = 404;
        json(res, code, { ok: false, error: "not ready" });
        return;
      }
      code = 200;
      json(res, code, got);
      return;
    }

    if (req.method === "GET" && (p === "/v1/accesslog" || p === "/accesslog")) {
      const n = Math.min(50, Math.max(1, Number(url.searchParams.get("n")) || 20));
      code = 200;
      json(res, code, { ok: true, lines: accessLog.slice(-n) });
      return;
    }

    if (req.method === "GET" && (p === "/v1/health" || p === "/health" || p === "/")) {
      code = 200;
      json(res, code, {
        ok: true,
        service: "amazeballs-realtime-http-bridge",
        pending: state.pending ? { id: state.pending.id, cmd: state.pending.cmd } : null,
        agent_alive: !!(state.status?.alive),
        agent_age_ms:
          state.status?.recv_ts != null ? Date.now() - state.status.recv_ts : null,
        access_log_len: accessLog.length,
      });
      return;
    }

    // Raw Lua tree for one-time boat bootstrap: wget <base>/v1/repo/navigation/test_agent.lua
    if (req.method === "GET" && (p === "/v1/repo" || p.startsWith("/v1/repo/"))) {
      const rel = p === "/v1/repo" ? "" : p.slice("/v1/repo/".length);
      const decoded = decodeURIComponent(rel).replace(/\\/g, "/");
      if (!decoded || decoded.includes("..") || path.isAbsolute(decoded)) {
        code = 400;
        json(res, code, { ok: false, error: "bad repo path" });
        return;
      }
      const abs = path.resolve(CC_SCRIPTS_ROOT, decoded);
      if (!abs.startsWith(CC_SCRIPTS_ROOT) || !fs.existsSync(abs) || !fs.statSync(abs).isFile()) {
        code = 404;
        json(res, code, { ok: false, error: "file not found", path: decoded });
        return;
      }
      const body = fs.readFileSync(abs);
      code = 200;
      res.writeHead(code, {
        "Content-Type": "text/plain; charset=utf-8",
        "Content-Length": body.length,
        "Cache-Control": "no-store",
      });
      res.end(body);
      return;
    }

    code = 404;
    json(res, code, { ok: false, error: "not found", path: p });
  } catch (e) {
    code = 500;
    json(res, code, { ok: false, error: String(e.message || e) });
  } finally {
    logAccess(req, p, code);
  }
}

export function createHttpBridgeServer() {
  return http.createServer((req, res) => {
    handle(req, res).catch((e) => {
      try {
        json(res, 500, { ok: false, error: String(e.message || e) });
      } catch {
        res.destroy();
      }
    });
  });
}

export function startHttpBridgeServer(listenSpec) {
  const { host, port } = parseListen(listenSpec);
  const server = createHttpBridgeServer();
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, host, () => {
      const addr = server.address();
      resolve({
        server,
        host,
        port: typeof addr === "object" && addr ? addr.port : port,
        listen: `${host}:${port}`,
        state,
        enqueue: hostEnqueue,
        getResult: hostGetResult,
        getStatus: hostGetStatus,
      });
    });
  });
}

function resolveListenFromConfigOrArgs(argv) {
  let listen = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--listen") listen = argv[++i];
  }
  if (listen) return listen;
  if (process.env.PORT) {
    const port = String(process.env.PORT).trim();
    if (port) return `0.0.0.0:${port}`;
  }
  const { config } = loadBridgeConfig();
  return config?.listen || "0.0.0.0:8765";
}

const isMain =
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isMain) {
  const listen = resolveListenFromConfigOrArgs(process.argv.slice(2));
  startHttpBridgeServer(listen)
    .then((s) => {
      console.log(`Realtime HTTP bridge listening on http://${s.listen}`);
      console.log("Logging every request (method path remote → status).");
      console.log("Agent endpoints: GET /v1/cmd  POST /v1/result  POST /v1/status");
      console.log("Host endpoints:  POST /v1/inbox  GET /v1/result?id=  GET /v1/status  GET /v1/accesslog");
      console.log("Boat /realtime_bridge.json: base_url must be reachable FROM the Minecraft SERVER.");
      console.log("  Same LAN → http://YOUR_LAN_IP:8765   Remote VPS → ngrok/cloudflare tunnel URL");
      console.log("  Never 127.0.0.1 (server loops to itself). Firewall: sudo ufw allow 8765/tcp");
      console.log(
        JSON.stringify(
          { mode: "http", base_url: "http://YOUR_LAN_IP_OR_TUNNEL:8765", poll: 0.3 },
          null,
          2,
        ),
      );
      // Keep process alive; ignore unused config path helper.
      void fs.existsSync(path.join(__dirname, "bridge.json"));
    })
    .catch((e) => {
      console.error(e);
      process.exit(1);
    });
}
