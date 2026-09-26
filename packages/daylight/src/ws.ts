import { parseServerMessage, type ClientMessage, type ServerMessage, type StateSnapshot } from "@twelve/protocol";

export interface Connection {
  serverUrl: string; // http(s)://host:port
  token: string;
}

const KEY = "twelve.connection";

export function loadConnection(): Connection | null {
  try {
    const raw = localStorage.getItem(KEY);
    return raw ? (JSON.parse(raw) as Connection) : null;
  } catch {
    return null;
  }
}

export function saveConnection(c: Connection | null) {
  try {
    if (c) localStorage.setItem(KEY, JSON.stringify(c));
    else localStorage.removeItem(KEY);
  } catch {
    /* private mode */
  }
}

/** If the page was opened from the pairing QR (?token=…), adopt it. */
export function connectionFromLocation(): Connection | null {
  const url = new URL(location.href);
  const token = url.searchParams.get("token");
  if (!token) return null;
  const c = { serverUrl: `${url.protocol}//${url.host}`, token };
  saveConnection(c);
  url.searchParams.delete("token");
  history.replaceState(null, "", url.pathname + url.hash);
  return c;
}

export function deviceId(): string {
  try {
    let id = localStorage.getItem("twelve.deviceId");
    if (!id) {
      id = "daylight-" + Math.random().toString(36).slice(2, 10);
      localStorage.setItem("twelve.deviceId", id);
    }
    return id;
  } catch {
    return "daylight";
  }
}

export class Client {
  private ws: WebSocket | null = null;
  private backoff = 1000;
  private closed = false;
  private pingTimer: number | null = null;
  connected = false;
  state: StateSnapshot | null = null;
  onState: ((s: StateSnapshot) => void) | null = null;
  onMessage: ((m: ServerMessage) => void) | null = null;
  onConnection: ((up: boolean) => void) | null = null;

  constructor(readonly conn: Connection) {}

  get wsUrl() {
    const u = new URL(this.conn.serverUrl);
    u.protocol = u.protocol === "https:" ? "wss:" : "ws:";
    u.pathname = "/ws";
    u.search = `?token=${encodeURIComponent(this.conn.token)}`;
    return u.toString();
  }

  open() {
    this.closed = false;
    this.dial();
  }

  close() {
    this.closed = true;
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.ws?.close();
  }

  private dial() {
    if (this.closed) return;
    const ws = new WebSocket(this.wsUrl);
    this.ws = ws;
    ws.onopen = () => {
      this.backoff = 1000;
      this.connected = true;
      this.onConnection?.(true);
      this.send({ type: "hello", role: "daylight", deviceId: deviceId(), version: "0.1.0" });
      if (this.pingTimer) clearInterval(this.pingTimer);
      this.pingTimer = window.setInterval(() => this.send({ type: "ping" }), 25_000);
    };
    ws.onmessage = (ev) => {
      let raw: unknown;
      try {
        raw = JSON.parse(String(ev.data));
      } catch {
        return;
      }
      const m = parseServerMessage(raw);
      if (!m) return;
      if (m.type === "state") {
        this.state = m.state;
        this.onState?.(m.state);
      }
      this.onMessage?.(m);
    };
    ws.onclose = () => {
      this.connected = false;
      this.onConnection?.(false);
      if (this.pingTimer) clearInterval(this.pingTimer);
      if (!this.closed) {
        setTimeout(() => this.dial(), this.backoff);
        this.backoff = Math.min(15_000, this.backoff * 1.7);
      }
    };
    ws.onerror = () => {
      /* onclose follows */
    };
  }

  send(m: ClientMessage) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(m));
  }

  async api<T = unknown>(path: string, init: RequestInit = {}): Promise<T> {
    const res = await fetch(`${this.conn.serverUrl}${path}`, {
      ...init,
      headers: { ...(init.headers ?? {}), authorization: `Bearer ${this.conn.token}`, "content-type": "application/json" },
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return (await res.json()) as T;
  }

  inkUrl(rel: string) {
    return `${this.conn.serverUrl}/api/ink/${encodeURIComponent(rel)}?token=${encodeURIComponent(this.conn.token)}`;
  }
}
