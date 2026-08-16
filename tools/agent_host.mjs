#!/usr/bin/env node
/**
 * Boat agent host: WebSocket server Cursor (or you) talks to.
 * Expose via Cloudflare tunnel and put the public wss URL in boat/rendezvous.json
 * or the boat's /agent.json.
 *
 * Usage:
 *   node tools/agent_host.mjs [--port 8765]
 *   cloudflared tunnel --url http://localhost:8765   # then use wss://... from cloudflare
 *
 * Note: CC websockets need a WS/WSS endpoint. If cloudflared gives https://, use wss:// same host.
 */
import http from "node:http";
import { WebSocketServer } from "ws";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");

const args = process.argv.slice(2);
let port = 8765;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--port") port = Number(args[++i]) || 8765;
}

/** @type {import('ws').WebSocket | null} */
let boat = null;
let lastHello = null;
let lastHeartbeat = null;
const pending = new Map();
let nextId = 1;

function rpc(method, params = {}, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    if (!boat || boat.readyState !== 1) {
      reject(new Error("boat not connected"));
      return;
    }
    const id = nextId++;
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error("timeout " + method));
    }, timeoutMs);
    pending.set(id, { resolve, reject, timer });
    boat.send(JSON.stringify({ type: "rpc", id, method, params }));
  });
}

const server = http.createServer((req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true, boat: !!boat, hello: lastHello, heartbeat: lastHeartbeat }));
    return;
  }
  if (req.url === "/rpc" && req.method === "POST") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", async () => {
      try {
        const msg = JSON.parse(body || "{}");
        const result = await rpc(msg.method, msg.params || {}, msg.timeoutMs || 30000);
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify(result));
      } catch (e) {
        res.writeHead(500, { "content-type": "application/json" });
        res.end(JSON.stringify({ ok: false, error: String(e.message || e) }));
      }
    });
    return;
  }
  res.writeHead(200, { "content-type": "text/plain" });
  res.end(
    "Boat agent host\n" +
      "  GET /health\n" +
      "  POST /rpc  {\"method\":\"pose\"}\n" +
      "  WS clients: boat agent connects here\n"
  );
});

const wss = new WebSocketServer({ server });

wss.on("connection", (ws, req) => {
  console.log("client connected", req.socket.remoteAddress);
  boat = ws;
  ws.on("message", (data) => {
    let msg;
    try {
      msg = JSON.parse(String(data));
    } catch {
      return;
    }
    if (msg.type === "hello") {
      lastHello = msg;
      console.log("boat hello", msg);
    } else if (msg.type === "heartbeat") {
      lastHeartbeat = msg;
    } else if (msg.type === "reply" && pending.has(msg.id)) {
      const p = pending.get(msg.id);
      pending.delete(msg.id);
      clearTimeout(p.timer);
      if (msg.ok) p.resolve(msg);
      else p.reject(new Error(msg.error || "rpc failed"));
    }
  });
  ws.on("close", () => {
    if (boat === ws) boat = null;
    console.log("client disconnected");
    for (const [id, p] of pending) {
      clearTimeout(p.timer);
      p.reject(new Error("disconnected"));
      pending.delete(id);
    }
  });
});

server.listen(port, () => {
  console.log(`agent_host listening on http://0.0.0.0:${port} (ws on same port)`);
  console.log("Tunnel example: cloudflared tunnel --url http://127.0.0.1:" + port);
  console.log("Then set boat/rendezvous.json wss field to wss://<tunnel-host>");
});

export { rpc, server };
