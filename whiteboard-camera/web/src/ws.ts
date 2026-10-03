// WebSocket client for ws://<mac>:7788/ink (PROTOCOL 1, 8). Offers the solstream.v1 subprotocol and
// requires it back; backoff 1000 ms x 1.7 capped at 15 s; PING every 10 s; ring replay on ACK 0;
// no ink leaves while the Mac shows the Allow panel (ACK 1); re-dials on visibilitychange and online;
// a Mac that answers /api/info while the socket keeps failing is "refused" and re-dialled every 60 s.

import type { ConnectionPhase } from "./chip-state.js";
import { Encoder, decodeServer, nowUs, type HandshakeAck, type StateReport } from "./protocol.js";
import { Ring } from "./ring.js";

export const SUBPROTOCOL = "solstream.v1";
export const BACKOFF_BASE_MS = 1000;
export const BACKOFF_FACTOR = 1.7;
export const BACKOFF_CAP_MS = 15_000;
export const PING_INTERVAL_MS = 10_000;
export const HOLD_BYTES = 64 * 1024;
export const THIN_BYTES = 1024 * 1024;
export const HANDSHAKE_DPI = 200;
/**
 * Chromium fails the upgrade itself when the offered subprotocol is not echoed, so a Mac that speaks a
 * different protocol version looks like a socket that never opens. After this many consecutive failures
 * the client asks GET /api/info; a daylight answer means "reachable but not compatible": stop retrying.
 */
export const INCOMPATIBLE_PROBE_AFTER = 5;
/** While "refused" (the probe found a Daylight that will not take the socket) one re-dial per minute, plus taps. */
export const REFUSED_REDIAL_MS = 60_000;

export function backoffDelay(attempt: number): number {
  return Math.min(BACKOFF_CAP_MS, BACKOFF_BASE_MS * Math.pow(BACKOFF_FACTOR, attempt));
}

export interface InkClientEvents {
  onPhase(phase: ConnectionPhase): void;
  onState(state: StateReport): void;
  onAck?(ack: HandshakeAck): void;
  onPong?(rttMs: number): void;
}

export interface InkClientStats {
  dials: number;
  opens: number;
  closes: number;
  framesSent: number;
  framesRinged: number;
  framesReplayed: number;
  controlDropped: number;
  /** Re-dials made by the 60 s timer of the refused phase. */
  refusedRedials: number;
  lastDelayMs: number;
  rttMs: number | null;
  lastCloseCode: number | null;
}

/** Narrow view of the WebSocket surface the client uses, so tests can inject a fake. */
export type SocketFactory = (url: string, protocols: string[]) => WebSocket;

export class InkClient {
  readonly encoder = new Encoder(nowUs);
  readonly ring: Ring;
  phase: ConnectionPhase = "disconnected";
  readonly stats: InkClientStats = { dials: 0, opens: 0, closes: 0, framesSent: 0, framesRinged: 0, framesReplayed: 0, controlDropped: 0, refusedRedials: 0, lastDelayMs: 0, rttMs: null, lastCloseCode: null };
  private ws: WebSocket | null = null;
  private stopped = true;
  private attempt = 0;
  private redialTimer: number | null = null;
  private refusedTimer: number | null = null;
  private pingTimer: number | null = null;
  private pingSeq = 0n;
  private consecutiveFailures = 0;
  private ackedOnThisSocket = false;

  constructor(
    private readonly url: string,
    private readonly identity: string,
    private readonly events: InkClientEvents,
    options: { ring?: Ring; socketFactory?: SocketFactory } = {},
  ) {
    this.ring = options.ring ?? new Ring();
    this.socketFactory = options.socketFactory ?? ((u, p) => new WebSocket(u, p));
    document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") this.nudge(); });
    window.addEventListener("online", () => this.nudge());
  }

  private readonly socketFactory: SocketFactory;

  start(): void {
    this.stopped = false;
    this.attempt = 0;
    this.dial();
  }

  stop(): void {
    this.stopped = true;
    this.clearTimers();
    const ws = this.ws;
    this.ws = null;
    try { ws?.close(1000, "page closed"); } catch { /* already closed */ }
    this.setPhase("disconnected");
  }

  /** User action after "Not allowed by the Mac", a refused socket or an incompatible server: dial again from scratch. */
  retry(): void {
    this.clearTimers();
    this.consecutiveFailures = 0;
    try { this.ws?.close(1000, "retry"); } catch { /* ignore */ }
    this.ws = null;
    this.start();
  }

  isLive(): boolean {
    return this.phase === "live" && this.ws !== null && this.ws.readyState === WebSocket.OPEN;
  }

  /** Ink and erase: live -> sent now; otherwise ringed for replay after ACK 0. */
  sendInk(frame: ArrayBuffer, strokeKey: string, points: number): boolean {
    if (this.isLive()) {
      this.rawSend(frame);
      return true;
    }
    this.ring.push(frame, strokeKey, points);
    this.stats.framesRinged++;
    return false;
  }

  /** Pin, return, undo, redo, clear, page change, laser: meaningful now or never; dropped while not live. */
  sendControl(frame: ArrayBuffer): boolean {
    if (!this.isLive()) { this.stats.controlDropped++; return false; }
    this.rawSend(frame);
    return true;
  }

  backpressure(): "ok" | "hold" | "thin" {
    const ws = this.ws;
    if (!ws || ws.readyState !== WebSocket.OPEN) return "ok";
    if (ws.bufferedAmount > THIN_BYTES) return "thin";
    if (ws.bufferedAmount > HOLD_BYTES) return "hold";
    return "ok";
  }

  get bufferedAmount(): number {
    return this.ws?.bufferedAmount ?? 0;
  }

  /** Dial now if a re-dial is pending (visibility, online). */
  nudge(): void {
    if (this.stopped || this.ws || this.phase === "denied" || this.phase === "incompatible") return;
    if (this.redialTimer !== null) { clearTimeout(this.redialTimer); this.redialTimer = null; }
    this.dial();
  }

  private rawSend(frame: ArrayBuffer): void {
    try {
      this.ws?.send(frame);
      this.stats.framesSent++;
    } catch {
      // CONNECTING throws InvalidStateError; the frame is lost like any send on a dead socket.
    }
  }

  private setPhase(phase: ConnectionPhase): void {
    if (this.phase === phase) return;
    this.phase = phase;
    this.events.onPhase(phase);
  }

  private clearTimers(): void {
    if (this.redialTimer !== null) { clearTimeout(this.redialTimer); this.redialTimer = null; }
    if (this.refusedTimer !== null) { clearTimeout(this.refusedTimer); this.refusedTimer = null; }
    if (this.pingTimer !== null) { clearInterval(this.pingTimer); this.pingTimer = null; }
  }

  /** Refused: the chip says "Tap to retry"; one quiet re-dial a minute catches a Mac that was merely restarting. */
  private scheduleRefusedRedial(): void {
    if (this.stopped || this.refusedTimer !== null) return;
    this.refusedTimer = window.setTimeout(() => {
      this.refusedTimer = null;
      if (this.stopped || this.ws || this.phase !== "refused") return;
      this.stats.refusedRedials++;
      this.dial();
    }, REFUSED_REDIAL_MS);
  }

  private dial(): void {
    if (this.stopped || this.ws) return;
    this.stats.dials++;
    this.setPhase("connecting");
    let ws: WebSocket;
    try {
      ws = this.socketFactory(this.url, [SUBPROTOCOL]);
    } catch {
      this.scheduleRedial();
      return;
    }
    ws.binaryType = "arraybuffer";
    this.ws = ws;
    ws.onopen = () => {
      if (this.ws !== ws) return;
      this.stats.opens++;
      if (ws.protocol !== SUBPROTOCOL) {
        // Offered and not echoed: not a compatible Daylight; stop retrying (PROTOCOL 1).
        this.setPhase("incompatible");
        this.ws = null;
        try { ws.close(1002, "no solstream.v1"); } catch { /* ignore */ }
        return;
      }
      this.attempt = 0;
      ws.send(this.encoder.handshake(1200, 1600, HANDSHAKE_DPI, this.identity));
      this.stats.framesSent++;
      if (this.pingTimer !== null) clearInterval(this.pingTimer);
      this.pingTimer = window.setInterval(() => {
        if (ws.readyState === WebSocket.OPEN) { ws.send(this.encoder.ping(this.pingSeq++)); this.stats.framesSent++; }
      }, PING_INTERVAL_MS);
    };
    ws.onmessage = (ev: MessageEvent) => {
      if (this.ws !== ws || !(ev.data instanceof ArrayBuffer)) return;
      const msg = decodeServer(ev.data);
      if (!msg) return;
      if ("ack" in msg) this.handleAck(msg.ack);
      else if ("state" in msg) this.events.onState(msg.state);
      else if ("pong" in msg) {
        const rtt = Number(nowUs() - msg.pong.t) / 1000;
        this.stats.rttMs = rtt;
        this.events.onPong?.(rtt);
      }
    };
    ws.onerror = () => { /* onclose follows */ };
    ws.onclose = (ev: CloseEvent) => {
      if (this.ws !== ws) return;
      this.ws = null;
      this.stats.closes++;
      this.stats.lastCloseCode = ev.code;
      if (this.pingTimer !== null) { clearInterval(this.pingTimer); this.pingTimer = null; }
      if (this.phase === "denied" || this.phase === "incompatible" || this.stopped) return;
      this.setPhase("disconnected");
      if (!this.ackedOnThisSocket) this.consecutiveFailures++;
      this.ackedOnThisSocket = false;
      if (this.consecutiveFailures >= INCOMPATIBLE_PROBE_AFTER) {
        void this.probeIncompatible().then((reachable) => {
          if (this.stopped || this.ws) return;
          if (reachable) { this.setPhase("refused"); this.clearTimers(); this.scheduleRefusedRedial(); }
          else this.scheduleRedial();
        });
        return;
      }
      this.scheduleRedial();
    };
  }

  /** True when the Mac answers /api/info as daylight while our socket keeps failing (refused, or an old protocol). */
  private async probeIncompatible(): Promise<boolean> {
    try {
      const u = new URL(this.url);
      u.protocol = u.protocol === "wss:" ? "https:" : "http:";
      u.pathname = "/api/info";
      u.search = "";
      const res = await fetch(u.toString(), { cache: "no-cache" });
      if (!res.ok) return false;
      const info = (await res.json()) as { app?: string };
      return info.app === "daylight";
    } catch {
      return false;
    }
  }

  private handleAck(ack: HandshakeAck): void {
    this.events.onAck?.(ack);
    this.ackedOnThisSocket = true;
    this.consecutiveFailures = 0;
    switch (ack.status) {
      case 0: {
        this.setPhase("live");
        const replay = this.ring.drain();
        for (const frame of replay) this.rawSend(frame);
        this.stats.framesReplayed += replay.length;
        break;
      }
      case 1:
        this.setPhase("pending");
        break;
      case 2:
        this.setPhase("denied");   // the server closes 1008; we do not re-dial until the owner taps
        break;
      default:
        this.setPhase("incompatible");
        break;
    }
  }

  private scheduleRedial(): void {
    if (this.stopped || this.redialTimer !== null) return;
    const delay = backoffDelay(this.attempt++);
    this.stats.lastDelayMs = delay;
    this.redialTimer = window.setTimeout(() => { this.redialTimer = null; this.dial(); }, delay);
  }
}
