// SolStream-v1 encoder and decoder for the browser (docs/PROTOCOL.md). Little-endian everywhere.
// This file has no DOM dependency so the Node golden test can import it.

export const MAGIC = 0xda;
export const VERSION = 0x01;
export const HEADER_LEN = 16;
export const POINT_LEN = 11;
export const MAX_POINTS_PER_CHUNK = 4096;
/** PROTOCOL 1 and 3: payload_len <= 1 MiB. */
export const MAX_PAYLOAD = 1 << 20;

export const Opcode = {
  HANDSHAKE: 0x0001,
  HANDSHAKE_ACK: 0x0002,
  STROKE_START: 0x0010,
  STROKE_CHUNK: 0x0011,
  STROKE_COMMIT: 0x0012,
  STROKE_CANCEL: 0x0013,
  UNDO: 0x0014,
  REDO: 0x0015,
  ERASE_STROKES: 0x0020,
  LASER_POINT: 0x0030,
  CLEAR_CANVAS: 0x0040,
  PAGE_CHANGE: 0x0050,
  AUTO_ENGAGE_RETURN: 0x0060,
  TOGGLE_PIN: 0x0061,
  STATE: 0x0070,
  PING: 0x00fe,
  PONG: 0x00ff,
} as const;

export interface WirePoint {
  x: number;
  y: number;
  pressure: number;
  /** Milliseconds since the FIRST point of the stroke (saturates at 65535). */
  deltaMs: number;
}

export interface StateReport {
  governor: 0 | 1 | 2 | 3;
  pinned: boolean;
  preWarning: boolean;
  allowed: boolean;
  activeSource: boolean;
  cameraAttached: boolean;
  sinkConnected: boolean;
  saving: boolean;
  captureIdle: boolean;
  mode: 0 | 1 | 2 | 3;
  inkSource: 0 | 1 | 2;
  progress: number;
  /** null when no return is scheduled (0xFFFFFFFF on the wire). */
  msToReturn: number | null;
  pageIndex: number;
  strokeCount: number;
  undoDepth: number;
  redoDepth: number;
}

export interface HandshakeAck {
  w: number;
  h: number;
  fps: number;
  status: 0 | 1 | 2 | 3;
}

export type ServerMessage =
  | { opcode: typeof Opcode.HANDSHAKE_ACK; ack: HandshakeAck }
  | { opcode: typeof Opcode.STATE; state: StateReport }
  | { opcode: typeof Opcode.PONG; pong: { seq: bigint; t: bigint } }
  | { opcode: number };

const ZERO_UUID = new Uint8Array(16);

/** Parses "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" into 16 bytes in RFC 4122 order. */
export function uuidFromString(s: string): Uint8Array {
  const hex = s.replace(/-/g, "");
  if (hex.length !== 32) throw new Error(`bad uuid ${s}`);
  const out = new Uint8Array(16);
  for (let i = 0; i < 16; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

export function uuidToString(b: Uint8Array): string {
  const hex = toHex(b);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function newUuid16(): Uint8Array {
  const c = globalThis.crypto;
  if (c && typeof c.randomUUID === "function") return uuidFromString(c.randomUUID());
  const b = new Uint8Array(16);
  c.getRandomValues(b);
  b[6] = 0x40 | ((b[6] ?? 0) & 0x0f);
  b[8] = 0x80 | ((b[8] ?? 0) & 0x3f);
  return b;
}

export function toHex(bytes: Uint8Array | ArrayBuffer): string {
  const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = "";
  for (const b of u8) s += b.toString(16).padStart(2, "0");
  return s;
}

export function fromHex(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

const textEncoder = new TextEncoder();

/** Builds SolStream frames. `nowUs` is the sender clock in microseconds since the epoch. */
export class Encoder {
  private readonly scratch = new ArrayBuffer(64 * 1024);
  private readonly dv = new DataView(this.scratch);
  private readonly u8 = new Uint8Array(this.scratch);

  constructor(private readonly nowUs: () => bigint) {}

  private frame(opcode: number, payloadLen: number): ArrayBuffer {
    this.dv.setUint8(0, MAGIC);
    this.dv.setUint8(1, VERSION);
    this.dv.setUint16(2, opcode, true);
    this.dv.setUint32(4, payloadLen, true);
    this.dv.setBigUint64(8, this.nowUs(), true);
    return this.scratch.slice(0, HEADER_LEN + payloadLen);
  }

  private putUuid(offset: number, id: Uint8Array): void {
    this.u8.set(id, offset);
  }

  handshake(canvasW: number, canvasH: number, dpi: number, name: string): ArrayBuffer {
    const nameBytes = textEncoder.encode(name);
    if (nameBytes.length < 1 || nameBytes.length > 200) throw new Error("handshake name must be 1..200 UTF-8 bytes");
    let o = HEADER_LEN;
    this.dv.setFloat32(o, canvasW, true); o += 4;
    this.dv.setFloat32(o, canvasH, true); o += 4;
    this.dv.setFloat32(o, dpi, true); o += 4;
    this.dv.setUint16(o, nameBytes.length, true); o += 2;
    this.u8.set(nameBytes, o); o += nameBytes.length;
    return this.frame(Opcode.HANDSHAKE, o - HEADER_LEN);
  }

  strokeStart(id: Uint8Array, tool: 0 | 1 | 2 | 3, colorARGB: number, baseWidth: number, pressure: number): ArrayBuffer {
    let o = HEADER_LEN;
    this.putUuid(o, id); o += 16;
    this.dv.setUint8(o, tool); o += 1;
    this.dv.setUint32(o, colorARGB >>> 0, true); o += 4;
    this.dv.setFloat32(o, baseWidth, true); o += 4;
    this.dv.setUint8(o, 0); o += 1;   // pointer_type stylus
    this.dv.setUint8(o, 1); o += 1;   // phase contact
    this.dv.setFloat32(o, pressure, true); o += 4;
    return this.frame(Opcode.STROKE_START, o - HEADER_LEN);
  }

  strokeChunk(id: Uint8Array, pts: readonly WirePoint[]): ArrayBuffer {
    if (pts.length < 1 || pts.length > MAX_POINTS_PER_CHUNK) throw new Error(`chunk needs 1..${MAX_POINTS_PER_CHUNK} points`);
    let o = HEADER_LEN;
    this.putUuid(o, id); o += 16;
    this.dv.setUint16(o, pts.length, true); o += 2;
    for (const p of pts) {
      this.dv.setInt32(o, Math.round(p.x * 32), true);
      this.dv.setInt32(o + 4, Math.round(p.y * 32), true);
      this.dv.setUint8(o + 8, Math.round(Math.min(1, Math.max(0, p.pressure)) * 255));
      this.dv.setUint16(o + 9, Math.min(65535, Math.max(0, Math.round(p.deltaMs))), true);
      o += POINT_LEN;
    }
    return this.frame(Opcode.STROKE_CHUNK, o - HEADER_LEN);
  }

  strokeCommit(id: Uint8Array, count: number): ArrayBuffer {
    this.putUuid(HEADER_LEN, id);
    this.dv.setUint32(HEADER_LEN + 16, count >>> 0, true);
    return this.frame(Opcode.STROKE_COMMIT, 20);
  }

  strokeCancel(id: Uint8Array): ArrayBuffer {
    this.putUuid(HEADER_LEN, id);
    return this.frame(Opcode.STROKE_CANCEL, 16);
  }

  private pageAndTime(opcode: number, pageId: Uint8Array | null, timeUs: bigint): ArrayBuffer {
    this.putUuid(HEADER_LEN, pageId ?? ZERO_UUID);
    this.dv.setBigUint64(HEADER_LEN + 16, timeUs, true);
    return this.frame(opcode, 24);
  }

  undo(pageId: Uint8Array | null, timeUs: bigint = this.nowUs()): ArrayBuffer { return this.pageAndTime(Opcode.UNDO, pageId, timeUs); }
  redo(pageId: Uint8Array | null, timeUs: bigint = this.nowUs()): ArrayBuffer { return this.pageAndTime(Opcode.REDO, pageId, timeUs); }
  clear(pageId: Uint8Array | null, timeUs: bigint = this.nowUs()): ArrayBuffer { return this.pageAndTime(Opcode.CLEAR_CANVAS, pageId, timeUs); }

  erase(x1: number, y1: number, x2: number, y2: number, radius: number, ids: readonly Uint8Array[]): ArrayBuffer {
    if (ids.length > 1024) throw new Error("erase carries at most 1024 ids");
    let o = HEADER_LEN;
    for (const f of [x1, y1, x2, y2, radius]) { this.dv.setFloat32(o, f, true); o += 4; }
    this.dv.setUint16(o, ids.length, true); o += 2;
    for (const id of ids) { this.putUuid(o, id); o += 16; }
    return this.frame(Opcode.ERASE_STROKES, o - HEADER_LEN);
  }

  laserPoint(x: number, y: number, intensity: number, decayS: number): ArrayBuffer {
    let o = HEADER_LEN;
    for (const f of [x, y, intensity, decayS]) { this.dv.setFloat32(o, f, true); o += 4; }
    return this.frame(Opcode.LASER_POINT, 16);
  }

  pageChange(pageId: Uint8Array, w: number, h: number, index: number): ArrayBuffer {
    let o = HEADER_LEN;
    this.putUuid(o, pageId); o += 16;
    this.dv.setFloat32(o, w, true); o += 4;
    this.dv.setFloat32(o, h, true); o += 4;
    this.dv.setUint32(o, index >>> 0, true); o += 4;
    return this.frame(Opcode.PAGE_CHANGE, 28);
  }

  returnNow(timeUs: bigint = this.nowUs()): ArrayBuffer {
    this.dv.setBigUint64(HEADER_LEN, timeUs, true);
    return this.frame(Opcode.AUTO_ENGAGE_RETURN, 8);
  }

  togglePin(v: -1 | 0 | 1, timeUs: bigint = this.nowUs()): ArrayBuffer {
    this.dv.setInt8(HEADER_LEN, v);
    this.dv.setBigUint64(HEADER_LEN + 1, timeUs, true);
    return this.frame(Opcode.TOGGLE_PIN, 9);
  }

  ping(seq: bigint, timeUs: bigint = this.nowUs()): ArrayBuffer {
    this.dv.setBigUint64(HEADER_LEN, seq, true);
    this.dv.setBigUint64(HEADER_LEN + 8, timeUs, true);
    return this.frame(Opcode.PING, 16);
  }
}

export interface DecodedHeader {
  opcode: number;
  payloadLen: number;
  timestampUs: bigint;
}

export function decodeHeader(buf: ArrayBuffer): DecodedHeader | null {
  if (buf.byteLength < HEADER_LEN) return null;
  const dv = new DataView(buf);
  if (dv.getUint8(0) !== MAGIC || dv.getUint8(1) !== VERSION) return null;
  const payloadLen = dv.getUint32(4, true);
  if (payloadLen > MAX_PAYLOAD) return null;   // the 1 MiB cap (fuzz FZ-1)
  if (payloadLen !== buf.byteLength - HEADER_LEN) return null;
  return { opcode: dv.getUint16(2, true), payloadLen, timestampUs: dv.getBigUint64(8, true) };
}

/** Decodes the server-to-client messages (ACK, STATE, PONG); other opcodes come back as `{ opcode }`. */
export function decodeServer(buf: ArrayBuffer): ServerMessage | null {
  const header = decodeHeader(buf);
  if (!header) return null;
  const dv = new DataView(buf, HEADER_LEN);
  switch (header.opcode) {
    case Opcode.HANDSHAKE_ACK: {
      if (header.payloadLen !== 16) return null;
      const status = dv.getUint32(12, true);
      if (status > 3) return null;
      return { opcode: Opcode.HANDSHAKE_ACK, ack: { w: dv.getUint32(0, true), h: dv.getUint32(4, true), fps: dv.getUint32(8, true), status: status as 0 | 1 | 2 | 3 } };
    }
    case Opcode.STATE: {
      if (header.payloadLen < 20) return null;   // longer STATE frames are compatible additions
      // PROTOCOL 6.14 ranges: a value outside them is not a v1 STATE (new values are not a compatible addition,
      // PROTOCOL 10), so the frame is dropped instead of being shown as some other state (fuzz FZ-4).
      const governor = dv.getUint8(0);
      const mode = dv.getUint8(2);
      const inkSource = dv.getUint8(3);
      if (governor > 3 || mode > 3 || inkSource > 2) return null;
      const flags = dv.getUint8(1);
      const ms = dv.getUint32(8, true);
      return {
        opcode: Opcode.STATE,
        state: {
          governor: governor as 0 | 1 | 2 | 3,
          pinned: (flags & 1) !== 0,
          preWarning: (flags & 2) !== 0,
          allowed: (flags & 4) !== 0,
          activeSource: (flags & 8) !== 0,
          cameraAttached: (flags & 16) !== 0,
          sinkConnected: (flags & 32) !== 0,
          saving: (flags & 64) !== 0,
          captureIdle: (flags & 128) !== 0,
          mode: mode as 0 | 1 | 2 | 3,
          inkSource: inkSource as 0 | 1 | 2,
          progress: dv.getFloat32(4, true),
          msToReturn: ms === 0xffffffff ? null : ms,
          pageIndex: dv.getUint16(12, true),
          strokeCount: dv.getUint16(14, true),
          undoDepth: dv.getUint16(16, true),
          redoDepth: dv.getUint16(18, true),
        },
      };
    }
    case Opcode.PONG: {
      if (header.payloadLen !== 16) return null;
      return { opcode: Opcode.PONG, pong: { seq: dv.getBigUint64(0, true), t: dv.getBigUint64(8, true) } };
    }
    default:
      return { opcode: header.opcode };
  }
}

/** The header timestamp the web client sends: wall clock in microseconds. */
export function nowUs(): bigint {
  return BigInt(Math.round((performance.timeOrigin + performance.now()) * 1000));
}
