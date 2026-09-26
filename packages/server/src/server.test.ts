import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { WebSocket } from "ws";
import { parseServerMessage, type ServerMessage, type StateSnapshot } from "@twelve/protocol";
import { startServer } from "./server.js";
import { ConfigStore } from "./config.js";
import { Store } from "./store.js";
import { MockBrain } from "./brain.js";
import { StaticCalendar } from "./calendar.js";

function connect(url: string, role: "mac" | "daylight") {
  const ws = new WebSocket(url);
  const inbox: ServerMessage[] = [];
  const waiters: ((m: ServerMessage) => void)[] = [];
  ws.on("message", (d) => {
    const m = parseServerMessage(JSON.parse(d.toString()));
    if (!m) return;
    inbox.push(m);
    for (const w of waiters.splice(0)) w(m);
  });
  const opened = new Promise<void>((r) => ws.once("open", () => r()));
  const send = (m: unknown) => ws.send(JSON.stringify(m));
  const until = (pred: (m: ServerMessage) => boolean, ms = 3000): Promise<ServerMessage> =>
    new Promise((resolve, reject) => {
      const hit = inbox.find(pred);
      if (hit) return resolve(hit);
      const t = setTimeout(() => reject(new Error("timeout waiting for message")), ms);
      const check = (m: ServerMessage) => {
        if (pred(m)) {
          clearTimeout(t);
          resolve(m);
        } else waiters.push(check);
      };
      waiters.push(check);
    });
  const state = (pred: (s: StateSnapshot) => boolean) => until((m) => m.type === "state" && pred(m.state)).then((m) => (m as { state: StateSnapshot }).state);
  return { ws, opened, send, until, state, inbox, role, hello: () => send({ type: "hello", role, deviceId: role + "-test", version: "test" }) };
}

test("mac and daylight talk through the hub; auth is enforced", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "twelve-srv-"));
  const configStore = new ConfigStore(path.join(root, "config.json"));
  configStore.update({ schedule: { days: [0, 1, 2, 3, 4, 5, 6], start: "00:00", end: "23:59", timezone: "UTC" } });
  const token = configStore.get().pairing.token;
  const server = await startServer({
    port: 0,
    host: "127.0.0.1",
    configStore,
    store: new Store(root),
    brain: new MockBrain(),
    calendar: new StaticCalendar([], () => configStore.get().calendar),
    staticDir: root,
    quiet: true,
  });
  try {
    const base = `http://127.0.0.1:${server.port}`;
    // REST auth
    assert.equal((await fetch(`${base}/api/state`)).status, 401);
    assert.equal((await fetch(`${base}/api/state?token=${token}`)).status, 200);
    assert.equal((await fetch(`${base}/healthz`)).status, 200);
    // The pairing page is local-only (we are local here) and includes a QR + link with the token.
    const pair = await (await fetch(`${base}/pair`)).text();
    assert.match(pair, /<svg/);

    // WS auth
    const bad = new WebSocket(`ws://127.0.0.1:${server.port}/ws?token=nope`);
    await new Promise<void>((r) => bad.once("error", () => r()));

    const mac = connect(`ws://127.0.0.1:${server.port}/ws?token=${token}`, "mac");
    const day = connect(`ws://127.0.0.1:${server.port}/ws?token=${token}`, "daylight");
    await Promise.all([mac.opened, day.opened]);
    mac.hello();
    day.hello();
    let s = await mac.state((x) => x.clients.mac && x.clients.daylight);
    assert.equal(s.lockMode, "shield");
    assert.equal(s.phase, "idle");

    day.send({ type: "plan.start" });
    await mac.state((x) => x.phase === "planning");
    day.send({ type: "ink.submit", purpose: "plan", text: "intention: finish the hub test\n1. make it pass" });
    const ai = await day.until((m) => m.type === "ai.message");
    assert.equal(ai.type, "ai.message");
    s = await day.state((x) => x.phase === "reviewing");
    assert.equal(s.session?.plan.intention, "finish the hub test");
    day.send({ type: "plan.confirm" });
    s = await mac.state((x) => x.phase === "working");
    assert.equal(s.lockMode, "free");

    // Mac reports the foreground app (only logged in allowlist mode) and can trigger an emergency unlock.
    mac.send({ type: "mac.foreground", bundleId: "com.apple.Safari", name: "Safari" });
    day.send({ type: "session.end" });
    s = await mac.state((x) => x.phase === "wrapup");
    assert.equal(s.lockMode, "shield");
    mac.send({ type: "emergency.unlock", reason: "Need to join a call that is not on the calendar" });
    s = await mac.state((x) => x.lockMode === "free" && x.emergencyUntil !== null);
    assert.ok(s.session?.events.some((e) => e.kind === "emergency_unlock"));

    // Voice tool webhook drives the same engine.
    const r = await fetch(`${base}/api/voice/tools/get_plan?token=${token}`, { method: "POST", body: "{}" });
    const body = (await r.json()) as { phase: string; plan: { intention: string } };
    assert.equal(body.phase, "wrapup");
    assert.equal(body.plan.intention, "finish the hub test");

    // Config update over REST is validated and broadcast.
    const cr = await fetch(`${base}/api/config?token=${token}`, { method: "PUT", body: JSON.stringify({ checkin: { intervalMinutes: 45 } }) });
    assert.equal(cr.status, 200);
    s = await day.state((x) => x.config.checkin.intervalMinutes === 45);
    assert.equal(s.config.checkin.intervalMinutes, 45);

    mac.ws.close();
    day.ws.close();
  } finally {
    await server.close();
  }
});
