// The fake Mac for the Playwright suite: serves dist/ statically plus /healthz, /api/info and
// /daylight-ink.apk like the real WebServer, upgrades /ink to a WebSocket that speaks SolStream-v1,
// answers HANDSHAKE per a scripted scenario, and records every received frame for the specs.
//
// Control surface (tests only, never on the Mac):
//   GET  /__frames            every decoded frame since the last reset, in arrival order
//   GET  /__dials             upgrade attempts (ms timestamps), refused ones included
//   GET  /__clients           { open: n }
//   POST /__reset             forget frames and dials; scenario back to defaults
//   POST /__scenario {...}    ack 0|1|2|3|"none"; echoProtocol bool; refuse bool; inkSource 0|1|2; state {...}; apk bool
//   POST /__ack {status}      send HANDSHAKE_ACK to every open socket (the owner clicked Allow)
//   POST /__state {...}       send one STATE to every open socket (fields as in encodeState)
//   POST /__close {code}      close every open socket with that code
import { createServer } from "node:http";
import { readFileSync, existsSync, statSync } from "node:fs";
import { join, extname, normalize, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocketServer } from "ws";
import { decodeClient, encodeAck, encodePong, encodeState } from "./solstream-node.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const dist = process.env.DAYLIGHT_DIST ?? join(here, "..", "dist");
const port = Number(process.env.FAKE_MAC_PORT ?? process.argv[2] ?? 4173);
const host = "127.0.0.1";

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".webmanifest": "application/manifest+json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
  ".txt": "text/plain",
};

function defaultScenario() {
  return { ack: 0, echoProtocol: true, refuse: false, inkSource: 0, state: null, apk: false, closeAfterAck: null };
}

const fake = {
  scenario: defaultScenario(),
  frames: [],
  dials: [],
  sockets: new Set(),
  connSeq: 0,
};

function defaultState(ack) {
  return {
    governor: 0,
    flags: { allowed: ack === 0, activeSource: ack === 0, cameraAttached: true, sinkConnected: true },
    mode: 0,
    inkSource: fake.scenario.inkSource,
    progress: 0,
    msToReturn: null,
    pageIndex: 0,
    strokeCount: 0,
    undoDepth: 0,
    redoDepth: 0,
  };
}

function json(res, status, body) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, { "Content-Type": "application/json", "Content-Length": data.length, "Cache-Control": "no-cache", Connection: "close" });
  res.end(data);
}

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8");
      try { resolve(text ? JSON.parse(text) : {}); } catch { resolve({}); }
    });
  });
}

function broadcast(buf) {
  let n = 0;
  for (const ws of fake.sockets) {
    if (ws.readyState === ws.OPEN) { ws.send(buf); n++; }
  }
  return n;
}

function serveStatic(reqPath, res) {
  let p = decodeURIComponent(reqPath.split("?")[0]);
  if (p === "/") p = "/index.html";
  const clean = normalize(p).replace(/^(\.\.[/\\])+/, "");
  const file = join(dist, clean);
  if (!file.startsWith(dist) || !existsSync(file) || !statSync(file).isFile()) {
    res.writeHead(404, { "Content-Type": "text/plain", Connection: "close" });
    res.end("Not found");
    return;
  }
  const body = readFileSync(file);
  const type = MIME[extname(file).toLowerCase()] ?? "application/octet-stream";
  const cache = clean.startsWith("/assets/") || clean.startsWith("assets/") ? "public, max-age=31536000, immutable" : "no-cache";
  res.writeHead(200, { "Content-Type": type, "Content-Length": body.length, "Cache-Control": cache, Connection: "close" });
  res.end(body);
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", `http://${host}:${port}`);
  const path = url.pathname;
  if (path === "/healthz") {
    res.writeHead(200, { "Content-Type": "text/plain", Connection: "close" });
    res.end("ok");
    return;
  }
  if (path === "/api/info") {
    json(res, 200, {
      app: "daylight",
      version: "0.1.0-fake",
      build: 0,
      port,
      inkSource: ["web", "native", "mirror"][fake.scenario.inkSource] ?? "web",
      pillStripHeight: 96,
      secureHint: "chrome://flags/#unsafely-treat-insecure-origin-as-secure",
      origin: `http://${host}:${port}`,
    });
    return;
  }
  if (path === "/daylight-ink.apk") {
    if (!fake.scenario.apk) {
      res.writeHead(404, { "Content-Type": "text/plain", Connection: "close" });
      res.end("no APK in this build");
      return;
    }
    const body = Buffer.from("PK\u0003\u0004fake-apk", "binary");
    res.writeHead(200, { "Content-Type": "application/vnd.android.package-archive", "Content-Disposition": 'attachment; filename="DaylightInk.apk"', "Content-Length": body.length, Connection: "close" });
    res.end(body);
    return;
  }
  if (path.startsWith("/__")) {
    if (path === "/__frames") return json(res, 200, fake.frames);
    if (path === "/__dials") return json(res, 200, fake.dials);
    if (path === "/__clients") return json(res, 200, { open: [...fake.sockets].filter((w) => w.readyState === w.OPEN).length });
    const body = req.method === "POST" ? await readBody(req) : {};
    if (path === "/__reset") {
      fake.frames = [];
      fake.dials = [];
      fake.scenario = defaultScenario();
      return json(res, 200, { ok: true });
    }
    if (path === "/__scenario") {
      fake.scenario = { ...fake.scenario, ...body };
      return json(res, 200, fake.scenario);
    }
    if (path === "/__ack") return json(res, 200, { sent: broadcast(encodeAck(body.status ?? 0)) });
    if (path === "/__state") return json(res, 200, { sent: broadcast(encodeState({ ...defaultState(0), ...body })) });
    if (path === "/__close") {
      let n = 0;
      for (const ws of fake.sockets) { try { ws.close(body.code ?? 1001, body.reason ?? "fake mac"); n++; } catch { /* ignore */ } }
      return json(res, 200, { closed: n });
    }
    return json(res, 404, { error: "unknown control" });
  }
  serveStatic(path, res);
});

const wss = new WebSocketServer({
  noServer: true,
  handleProtocols: (protocols) => (fake.scenario.echoProtocol && protocols.has("solstream.v1") ? "solstream.v1" : false),
});

server.on("upgrade", (req, socket, head) => {
  const url = new URL(req.url ?? "/", `http://${host}:${port}`);
  fake.dials.push(Date.now());
  if (url.pathname !== "/ink") {
    socket.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }
  if (fake.scenario.refuse) {
    socket.write("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws, req));
});

wss.on("connection", (ws) => {
  const conn = ++fake.connSeq;
  fake.sockets.add(ws);
  ws.on("close", () => fake.sockets.delete(ws));
  ws.on("error", () => fake.sockets.delete(ws));
  ws.on("message", (data, isBinary) => {
    if (!isBinary) {
      fake.frames.push({ conn, t: Date.now(), error: "text frame", name: "TEXT" });
      return;
    }
    const u8 = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    const decoded = decodeClient(u8);
    fake.frames.push({ conn, t: Date.now(), ...decoded });
    if (decoded.error) return;
    if (decoded.opcode === 0x0001) {
      const ack = fake.scenario.ack;
      if (ack === "none") return;
      ws.send(encodeAck(ack));
      ws.send(encodeState({ ...defaultState(ack), ...(fake.scenario.state ?? {}) }));
      if (ack === 2) ws.close(1008, "denied");
      if (ack === 3) ws.close(1002, "unsupported");
      if (typeof fake.scenario.closeAfterAck === "number") setTimeout(() => ws.close(fake.scenario.closeAfterAck, "scripted"), 50);
    } else if (decoded.opcode === 0x00fe) {
      ws.send(encodePong(u8));
    }
  });
});

server.listen(port, host, () => {
  console.log(`fake mac on http://${host}:${port} serving ${dist}`);
});
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => { server.close(); process.exit(0); });
