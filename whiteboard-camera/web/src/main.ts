// Daylight whiteboard page: a pen-only canvas and a WebSocket client stub. Tools, chip and ring buffer land in M3.
import "./styles.css";
import { Encoder, newUuid16, nowUs, type WirePoint } from "./protocol.js";
import { InkClient, type ConnectionState } from "./ws.js";

const CANVAS_W = 1200;
const CANVAS_H = 1600;

interface DebugState {
  strokes: number;
  points: number;
  ignored: number;
  connection: ConnectionState;
  framesSent: number;
}

const debug: DebugState = { strokes: 0, points: 0, ignored: 0, connection: "disconnected", framesSent: 0 };
(window as unknown as { __daylight: DebugState }).__daylight = debug;

const canvas = document.getElementById("ink") as HTMLCanvasElement;
const chip = document.getElementById("chip") as HTMLSpanElement;
const ctx = canvas.getContext("2d", { desynchronized: true }) ?? canvas.getContext("2d");
if (!ctx) throw new Error("no 2d context");
ctx.lineCap = "round";
ctx.lineJoin = "round";
ctx.strokeStyle = "#111111";

function clientIdentity(): string {
  let id: string | null = null;
  try { id = localStorage.getItem("daylight.clientId"); } catch { /* storage unavailable */ }
  if (!id) {
    id = crypto.randomUUID();
    try { localStorage.setItem("daylight.clientId", id); } catch { /* ignore */ }
  }
  return `web;${id};Chrome on Daylight`;
}

function socketUrl(): string | null {
  const params = new URLSearchParams(location.search);
  const host = params.get("host");
  if (host) return `ws://${host}:7788/ink`;
  // Served by the Mac app itself: same origin, path /ink.
  if (location.port === "7788") return `ws://${location.host}/ink`;
  return null;
}

const url = socketUrl();
const client = url
  ? new InkClient(url, clientIdentity(), {
      onConnection(state) {
        debug.connection = state;
        chip.dataset.state = state === "live" ? "live" : state;
        chip.textContent = state === "live" ? "LIVE" : state === "pending" ? "Look at your Mac" : state === "connecting" ? "Connecting" : "Not connected";
      },
      onState(state) {
        if (state.governor === 3) { chip.dataset.state = "returning"; chip.textContent = "Returning"; }
        else if (state.governor === 0) { chip.dataset.state = "live"; chip.textContent = "Camera"; }
        else { chip.dataset.state = "live"; chip.textContent = state.pinned ? "KEEP WHITEBOARD" : "LIVE"; }
      },
    })
  : null;
client?.start();
if (!client) chip.textContent = "Not connected (open from your Mac's address)";

const encoder = client?.encoder ?? new Encoder(nowUs);

function send(frame: ArrayBuffer): void {
  if (client?.send(frame)) debug.framesSent++;
}

/** Canvas units from a pointer event (independent of CSS size and DPR). */
function canvasPoint(e: PointerEvent): { x: number; y: number } {
  const rect = canvas.getBoundingClientRect();
  return { x: ((e.clientX - rect.left) * CANVAS_W) / rect.width, y: ((e.clientY - rect.top) * CANVAS_H) / rect.height };
}

interface ActiveStroke {
  id: Uint8Array;
  startedAt: number;
  last: { x: number; y: number };
  pending: WirePoint[];
  count: number;
}

let active: ActiveStroke | null = null;
let rafQueued = false;

function flush(): void {
  rafQueued = false;
  if (!active || active.pending.length === 0) return;
  send(encoder.strokeChunk(active.id, active.pending));
  active.count += active.pending.length;
  active.pending = [];
}

function queueFlush(): void {
  if (!rafQueued) { rafQueued = true; requestAnimationFrame(flush); }
}

function isPen(e: PointerEvent): boolean {
  return e.pointerType === "pen";
}

canvas.addEventListener("pointerdown", (e) => {
  // Fingers and palms never draw and never engage; a pen with pressure 0 is a side button in the air.
  if (!isPen(e) || e.buttons === 0 || e.pressure <= 0) { debug.ignored++; return; }
  canvas.setPointerCapture(e.pointerId);
  const p = canvasPoint(e);
  const id = newUuid16();
  active = { id, startedAt: e.timeStamp, last: p, pending: [{ ...p, pressure: e.pressure, deltaMs: 0 }], count: 0 };
  send(encoder.strokeStart(id, 0, 0xff111111, 3.2, e.pressure));
  debug.strokes++;
  debug.points++;
  ctx.beginPath();
  ctx.moveTo(p.x, p.y);
  queueFlush();
});

canvas.addEventListener("pointermove", (e) => {
  if (!active || !isPen(e) || e.buttons === 0) return;
  const events = typeof e.getCoalescedEvents === "function" ? e.getCoalescedEvents() : [e];
  for (const ev of events.length ? events : [e]) {
    const p = canvasPoint(ev);
    ctx.lineWidth = 3.2 * (0.55 + 0.9 * ev.pressure);
    ctx.beginPath();
    ctx.moveTo(active.last.x, active.last.y);
    ctx.lineTo(p.x, p.y);
    ctx.stroke();
    active.last = p;
    active.pending.push({ ...p, pressure: ev.pressure, deltaMs: Math.round(ev.timeStamp - active.startedAt) });
    debug.points++;
  }
  queueFlush();
});

function finish(e: PointerEvent, cancelled: boolean): void {
  if (!active || !isPen(e)) return;
  flush();
  const young = e.timeStamp - active.startedAt < 80 && active.count < 2;
  if (cancelled || young) send(encoder.strokeCancel(active.id));
  else send(encoder.strokeCommit(active.id, active.count));
  active = null;
}

canvas.addEventListener("pointerup", (e) => finish(e, false));
canvas.addEventListener("pointercancel", (e) => finish(e, true));
canvas.addEventListener("pointerleave", (e) => { if (active && e.buttons !== 0) finish(e, false); });
window.addEventListener("beforeunload", () => client?.stop());
