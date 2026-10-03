// WebSocket client stub for ws://<mac>:7788/ink. Full reconnect, ring replay and STATE handling land in M3.
import { Encoder, decodeServer, nowUs, type StateReport } from "./protocol.js";

export type ConnectionState = "disconnected" | "connecting" | "pending" | "live";

export interface InkClientEvents {
  onConnection(state: ConnectionState): void;
  onState(state: StateReport): void;
}

export class InkClient {
  readonly encoder = new Encoder(nowUs);
  private ws: WebSocket | null = null;
  private closedByUser = false;
  private attempt = 0;
  private timer: number | null = null;

  constructor(private readonly url: string, private readonly identity: string, private readonly events: InkClientEvents) {}

  start(): void {
    this.closedByUser = false;
    this.dial();
  }

  stop(): void {
    this.closedByUser = true;
    if (this.timer !== null) { clearTimeout(this.timer); this.timer = null; }
    this.ws?.close(1000, "page closed");
    this.ws = null;
  }

  /** Sends one SolStream frame when the socket is open; false when it was dropped. */
  send(frame: ArrayBuffer): boolean {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return false;
    this.ws.send(frame);
    return true;
  }

  private dial(): void {
    if (this.closedByUser) return;
    this.events.onConnection("connecting");
    let ws: WebSocket;
    try {
      ws = new WebSocket(this.url, ["solstream.v1"]);
    } catch {
      this.scheduleRedial();
      return;
    }
    ws.binaryType = "arraybuffer";
    ws.onopen = () => {
      this.attempt = 0;
      this.events.onConnection("pending");
      ws.send(this.encoder.handshake(1200, 1600, 200, this.identity));
    };
    ws.onmessage = (ev: MessageEvent) => {
      if (!(ev.data instanceof ArrayBuffer)) return;
      const msg = decodeServer(ev.data);
      if (!msg) return;
      if ("ack" in msg && msg.ack.status === 0) this.events.onConnection("live");
      if ("state" in msg) this.events.onState(msg.state);
    };
    ws.onclose = () => {
      this.ws = null;
      this.events.onConnection("disconnected");
      this.scheduleRedial();
    };
    this.ws = ws;
  }

  private scheduleRedial(): void {
    if (this.closedByUser || this.timer !== null) return;
    const delay = Math.min(15_000, 1000 * Math.pow(1.7, this.attempt++));
    this.timer = window.setTimeout(() => { this.timer = null; this.dial(); }, delay);
  }
}
