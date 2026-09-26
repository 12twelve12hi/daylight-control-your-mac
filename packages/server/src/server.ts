import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { WebSocketServer, WebSocket } from "ws";
import QRCode from "qrcode";
import {
  DEFAULT_PORT,
  parseClientMessage,
  PublicConfigSchema,
  type ClientMessage,
  type ClientRole,
  type ServerMessage,
  type StateSnapshot,
} from "@twelve/protocol";
import { ConfigStore } from "./config.js";
import { Store } from "./store.js";
import { Engine } from "./session.js";
import { createBrain, type Brain } from "./brain.js";
import { IcsCalendar, type CalendarProvider } from "./calendar.js";
import { createVoice } from "./voice.js";

const here = path.dirname(fileURLToPath(import.meta.url));

export interface ServerOptions {
  port?: number;
  host?: string;
  configStore?: ConfigStore;
  store?: Store;
  brain?: Brain;
  calendar?: CalendarProvider;
  /** Directory with the built Daylight PWA. */
  staticDir?: string;
  quiet?: boolean;
}

export interface RunningServer {
  port: number;
  engine: Engine;
  configStore: ConfigStore;
  close(): Promise<void>;
  urls(): { local: string; lan: string[]; pair: string };
}

interface Client {
  ws: WebSocket;
  role: ClientRole | null;
  deviceId: string;
}

export async function startServer(opts: ServerOptions = {}): Promise<RunningServer> {
  const configStore = opts.configStore ?? new ConfigStore();
  const store = opts.store ?? new Store();
  const cfg = () => configStore.get();
  const brain = opts.brain ?? createBrain(cfg().brain.provider, cfg().brain.model);
  const calendar = opts.calendar ?? new IcsCalendar(() => cfg().calendar);
  const voice = createVoice(cfg);
  const log = opts.quiet ? () => {} : (...a: unknown[]) => console.log(...a);
  const staticDir = opts.staticDir ?? findStaticDir();

  const clients = new Set<Client>();

  const send = (c: Client, msg: ServerMessage) => {
    if (c.ws.readyState === WebSocket.OPEN) c.ws.send(JSON.stringify(msg));
  };
  const broadcast = (msg: ServerMessage, roles?: ClientRole[]) => {
    for (const c of clients) if (!roles || (c.role && roles.includes(c.role))) send(c, msg);
  };

  const engine = new Engine({
    config: cfg,
    publicConfig: () => configStore.public(),
    store,
    brain,
    calendar,
    onChange: (state) => broadcast({ type: "state", state }),
    onAssistant: (turn, purpose) => broadcast({ type: "ai.message", text: turn.text, questions: turn.questions ?? [], purpose }, ["daylight", "voice"]),
    onBusy: (busy, what) => broadcast({ type: "ai.busy", busy, what }),
    onError: (code, message) => broadcast({ type: "error", code, message }, ["daylight", "voice"]),
  });

  // Calendar polling
  let calTimer: NodeJS.Timeout | null = null;
  const pollCalendar = async () => {
    await calendar.refresh();
    engine.tick();
    calTimer = setTimeout(pollCalendar, cfg().calendar.pollMinutes * 60_000);
  };

  // -- HTTP -----------------------------------------------------------------

  const httpServer = http.createServer(async (req, res) => {
    try {
      await handleHttp(req, res);
    } catch (err) {
      console.error("[http]", err);
      if (!res.headersSent) res.writeHead(500, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: (err as Error).message }));
    }
  });

  const authorized = (req: http.IncomingMessage, url: URL): boolean => {
    const token = cfg().pairing.token;
    const q = url.searchParams.get("token");
    const h = req.headers.authorization?.replace(/^Bearer\s+/i, "");
    return q === token || h === token;
  };

  const isLocal = (req: http.IncomingMessage) => {
    const a = req.socket.remoteAddress ?? "";
    return a === "127.0.0.1" || a === "::1" || a === "::ffff:127.0.0.1";
  };

  const json = (res: http.ServerResponse, status: number, body: unknown) => {
    res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
    res.end(JSON.stringify(body));
  };

  const readBody = (req: http.IncomingMessage): Promise<string> =>
    new Promise((resolve, reject) => {
      const chunks: Buffer[] = [];
      let size = 0;
      req.on("data", (c: Buffer) => {
        size += c.length;
        if (size > 25 * 1024 * 1024) {
          reject(new Error("body too large"));
          req.destroy();
        } else chunks.push(c);
      });
      req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
      req.on("error", reject);
    });

  const urls = () => {
    const port = (httpServer.address() as { port: number }).port;
    const token = cfg().pairing.token;
    const lan = lanAddresses().map((ip) => `http://${ip}:${port}/?token=${token}`);
    return { local: `http://127.0.0.1:${port}/`, lan, pair: `http://127.0.0.1:${port}/pair` };
  };

  async function handleHttp(req: http.IncomingMessage, res: http.ServerResponse) {
    const url = new URL(req.url ?? "/", "http://localhost");
    const p = url.pathname;

    if (p === "/healthz") return json(res, 200, { ok: true, phase: engine.currentPhase });

    if (p === "/pair") {
      if (!isLocal(req)) return json(res, 403, { error: "The pairing page is only served on the Mac itself." });
      const u = urls();
      const target = u.lan[0] ?? u.local;
      const svg = await QRCode.toString(target, { type: "svg", margin: 1, width: 360 });
      res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
      return res.end(pairPage(svg, u.lan, cfg().pairing.token));
    }

    if (p.startsWith("/api/")) {
      if (!authorized(req, url)) return json(res, 401, { error: "unauthorized" });
      if (p === "/api/state" && req.method === "GET") return json(res, 200, engine.snapshot());
      if (p === "/api/sessions" && req.method === "GET") return json(res, 200, store.listSessions(Number(url.searchParams.get("limit") ?? 30)));
      if (p === "/api/config" && req.method === "GET") return json(res, 200, configStore.public());
      if (p === "/api/config" && (req.method === "PUT" || req.method === "POST")) {
        const patch = PublicConfigSchema.deepPartial().parse(JSON.parse(await readBody(req)));
        configStore.update(patch as Record<string, unknown>);
        engine.configChanged();
        void calendar.refresh().then(() => engine.tick());
        return json(res, 200, configStore.public());
      }
      if (p === "/api/command" && req.method === "POST") {
        const msg = parseClientMessage(JSON.parse(await readBody(req)));
        if (!msg) return json(res, 400, { error: "invalid command" });
        await dispatch(msg, { ws: null as unknown as WebSocket, role: "voice", deviceId: "http" });
        return json(res, 200, engine.snapshot());
      }
      if (p.startsWith("/api/ink/") && req.method === "GET") {
        const file = store.inkPath(decodeURIComponent(p.slice("/api/ink/".length)));
        if (!file) return json(res, 404, { error: "not found" });
        res.writeHead(200, { "content-type": "image/png", "cache-control": "private, max-age=3600" });
        return fs.createReadStream(file).pipe(res);
      }
      if (p === "/api/voice/session" && req.method === "GET") {
        const info = await voice.sessionCredentials({ plan: engine.currentSession?.plan ?? null, phase: engine.currentPhase });
        return json(res, 200, { ...info, configured: voice.configured() });
      }
      if (p.startsWith("/api/voice/tools/") && req.method === "POST") {
        const name = p.slice("/api/voice/tools/".length);
        const body = JSON.parse((await readBody(req)) || "{}") as Record<string, unknown>;
        return json(res, 200, await voiceTool(name, body));
      }
      if (p === "/api/pairing-url" && req.method === "GET") return json(res, 200, urls());
      return json(res, 404, { error: "not found" });
    }

    // Static PWA
    return serveStatic(staticDir, p, res);
  }

  /** Voice-agent tool webhooks map onto the same commands as the Daylight. */
  async function voiceTool(name: string, body: Record<string, unknown>) {
    const s = engine.currentSession;
    switch (name) {
      case "get_plan":
        return { phase: engine.currentPhase, plan: s?.plan ?? null };
      case "update_plan": {
        const text = [
          body.intention ? `intention: ${String(body.intention)}` : "",
          ...((body.priorities as string[] | undefined) ?? []).map((x) => `priority: ${x}`),
          ...((body.todos as string[] | undefined) ?? []).map((x) => `todo: ${x}`),
        ]
          .filter(Boolean)
          .join("\n");
        await engine.submitInk({ purpose: engine.currentPhase === "reviewing" ? "reply" : "plan", text, via: "voice" });
        return { ok: true, plan: engine.currentSession?.plan ?? null, phase: engine.currentPhase };
      }
      case "confirm_plan":
        engine.confirmPlan();
        return { ok: engine.currentPhase === "working", phase: engine.currentPhase };
      case "submit_checkin": {
        const text = ["where", "happened", "stuck", "next"].map((k) => (body[k] ? `${k}: ${String(body[k])}` : "")).filter(Boolean).join("\n");
        await engine.submitInk({ purpose: "checkin", text, via: "voice" });
        return { ok: true, reply: engine.currentSession?.checkins.at(-1)?.aiReply ?? "" };
      }
      case "back_to_work":
        engine.backToWork();
        return { ok: true, phase: engine.currentPhase };
      case "end_session":
        engine.endSession();
        return { ok: true, phase: engine.currentPhase };
      default:
        return { error: `unknown tool ${name}` };
    }
  }

  // -- WebSocket ------------------------------------------------------------

  const wss = new WebSocketServer({ noServer: true, maxPayload: 25 * 1024 * 1024 });

  httpServer.on("upgrade", (req, socket, head) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    if (url.pathname !== "/ws" || !authorized(req, url)) {
      socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws, req));
  });

  wss.on("connection", (ws) => {
    const client: Client = { ws, role: null, deviceId: "" };
    clients.add(client);
    send(client, { type: "state", state: engine.snapshot() });
    ws.on("message", async (data) => {
      let raw: unknown;
      try {
        raw = JSON.parse(data.toString());
      } catch {
        return send(client, { type: "error", code: "bad_json", message: "Not JSON" });
      }
      const msg = parseClientMessage(raw);
      if (!msg) return send(client, { type: "error", code: "bad_message", message: "Unknown or malformed message" });
      try {
        await dispatch(msg, client);
      } catch (err) {
        console.error("[ws] dispatch failed", err);
        send(client, { type: "error", code: "internal", message: (err as Error).message });
      }
    });
    ws.on("close", () => {
      clients.delete(client);
      if (client.role === "mac" || client.role === "daylight") {
        const stillThere = [...clients].some((c) => c.role === client.role);
        if (!stillThere) engine.setClient(client.role, false);
      }
    });
    ws.on("error", (err) => log("[ws] error", err.message));
  });

  async function dispatch(msg: ClientMessage, client: Client) {
    switch (msg.type) {
      case "hello":
        client.role = msg.role;
        client.deviceId = msg.deviceId;
        log(`[ws] hello from ${msg.role} ${msg.deviceId} v${msg.version}`);
        if (msg.role === "mac" || msg.role === "daylight") engine.setClient(msg.role, true);
        else send(client, { type: "state", state: engine.snapshot() });
        return;
      case "ping":
        return send(client, { type: "pong", now: Date.now() });
      case "plan.start":
        return engine.startPlanning();
      case "ink.submit":
        return engine.submitInk({ purpose: msg.purpose, png: msg.png, text: msg.text, via: msg.via });
      case "plan.confirm":
        return engine.confirmPlan(msg.plan);
      case "plan.edit":
        return engine.editPlan(msg.plan);
      case "todo.toggle":
        return engine.toggleTodo(msg.id, msg.done);
      case "checkin.now":
        return engine.checkinNow();
      case "checkin.snooze":
        return engine.snooze();
      case "checkin.back":
        return engine.backToWork();
      case "session.end":
        return engine.endSession();
      case "wrapup.close":
        return engine.closeWrapup();
      case "gate.arm":
        return engine.arm();
      case "gate.disarm":
        return engine.disarm();
      case "meeting.pass":
        return engine.manualMeetingPass(msg.minutes);
      case "emergency.unlock":
        return engine.emergencyUnlock(msg.reason);
      case "mac.foreground":
        return engine.noteForeground(msg.bundleId, msg.name);
      case "config.update":
        configStore.update(msg.config as Record<string, unknown>);
        engine.configChanged();
        void calendar.refresh().then(() => engine.tick());
        return;
    }
  }

  // -- start ----------------------------------------------------------------

  const port = opts.port ?? Number(process.env.TWELVE_PORT ?? DEFAULT_PORT);
  const host = opts.host ?? process.env.TWELVE_HOST ?? "0.0.0.0";
  await new Promise<void>((resolve, reject) => {
    httpServer.once("error", reject);
    httpServer.listen(port, host, () => resolve());
  });
  engine.start();
  void pollCalendar();

  const actualPort = (httpServer.address() as { port: number }).port;
  log(`[twelve] listening on http://${host}:${actualPort}  (brain: ${brain.name}, voice: ${voice.kind})`);
  log(`[twelve] pair your Daylight: ${urls().pair}`);

  return {
    port: actualPort,
    engine,
    configStore,
    urls,
    close: async () => {
      if (calTimer) clearTimeout(calTimer);
      engine.stop();
      for (const c of clients) c.ws.close();
      await new Promise<void>((r) => wss.close(() => r()));
      await new Promise<void>((r) => httpServer.close(() => r()));
    },
  };
}

// ---------------------------------------------------------------------------

function findStaticDir(): string {
  const candidates = [
    process.env.TWELVE_STATIC_DIR,
    path.resolve(here, "../../daylight/dist"),
    path.resolve(here, "../../../daylight/dist"),
  ].filter(Boolean) as string[];
  for (const c of candidates) if (fs.existsSync(path.join(c, "index.html"))) return c;
  return candidates[1]!;
}

const MIME: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".webmanifest": "application/manifest+json",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
  ".map": "application/json",
};

function serveStatic(dir: string, urlPath: string, res: http.ServerResponse) {
  let rel = decodeURIComponent(urlPath);
  if (rel === "/" || rel === "") rel = "/index.html";
  const file = path.normalize(path.join(dir, rel));
  if (!file.startsWith(dir)) {
    res.writeHead(403);
    return res.end();
  }
  const serve = (f: string) => {
    const ext = path.extname(f);
    res.writeHead(200, {
      "content-type": MIME[ext] ?? "application/octet-stream",
      "cache-control": ext === ".html" ? "no-store" : "public, max-age=86400",
    });
    fs.createReadStream(f).pipe(res);
  };
  if (fs.existsSync(file) && fs.statSync(file).isFile()) return serve(file);
  const index = path.join(dir, "index.html");
  if (fs.existsSync(index)) return serve(index); // SPA fallback
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
  res.end(`<!doctype html><meta charset=utf-8><title>Twelve</title><body style="font-family:system-ui;padding:2rem"><h1>Twelve server is running</h1><p>The Daylight app has not been built yet. Run <code>npm run build</code> in the repo, then reload.</p>`);
}

function lanAddresses(): string[] {
  const out: string[] = [];
  for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
    for (const a of addrs ?? []) {
      if (a.family !== "IPv4" || a.internal) continue;
      // Tailscale first (works across networks), then Wi-Fi/Ethernet.
      if (a.address.startsWith("100.") || name.startsWith("utun") || name.includes("tailscale")) out.unshift(a.address);
      else out.push(a.address);
    }
  }
  return out;
}

function pairPage(svg: string, lan: string[], token: string): string {
  const links = lan.length
    ? lan.map((u) => `<li><a href="${u}">${u}</a></li>`).join("")
    : "<li>No network address found. Connect the Mac to Wi-Fi or Tailscale.</li>";
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Pair your Daylight — Twelve</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;max-width:720px;margin:3rem auto;padding:0 1.5rem;color:#111;line-height:1.5}h1{font-weight:600}svg{width:320px;height:320px;display:block;margin:1rem 0}code{background:#f2f2f2;padding:.1em .3em;border-radius:4px}li{word-break:break-all;margin:.4rem 0}</style></head>
<body><h1>Pair your Daylight</h1>
<p>On the Daylight, open the camera or a QR app and scan this code, or type one of the links below into Chrome. Then use <em>Add to Home screen</em> so it opens full-screen.</p>
${svg}
<ul>${links}</ul>
<p>The link carries your pairing token <code>${token.slice(0, 6)}…</code>. Anyone with it can control the gate, so keep it on your own network (Wi-Fi or Tailscale).</p>
</body></html>`;
}
