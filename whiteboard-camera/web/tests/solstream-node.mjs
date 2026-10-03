// SolStream-v1 for the fake Mac (Node): decodes every client-to-server message into fields and
// encodes the three server-to-client messages. Mirrors docs/PROTOCOL.md; little-endian everywhere.
// Kept separate from src/protocol.ts on purpose: the fake Mac must not share code with the page it tests.

export const HEADER_LEN = 16;
export const POINT_LEN = 11;

export const OPCODE_NAMES = {
  0x0001: "HANDSHAKE",
  0x0002: "HANDSHAKE_ACK",
  0x0010: "STROKE_START",
  0x0011: "STROKE_CHUNK",
  0x0012: "STROKE_COMMIT",
  0x0013: "STROKE_CANCEL",
  0x0014: "UNDO",
  0x0015: "REDO",
  0x0020: "ERASE_STROKES",
  0x0030: "LASER_POINT",
  0x0040: "CLEAR_CANVAS",
  0x0050: "PAGE_CHANGE",
  0x0060: "AUTO_ENGAGE_RETURN",
  0x0061: "TOGGLE_PIN",
  0x0070: "STATE",
  0x00fe: "PING",
  0x00ff: "PONG",
};

export function toHex(u8) {
  let s = "";
  for (const b of u8) s += b.toString(16).padStart(2, "0");
  return s;
}

export function fromHex(hex) {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

function uuidString(u8, offset) {
  const hex = toHex(u8.subarray(offset, offset + 16));
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** Decodes one client frame. Returns `{ error }` for malformed input instead of throwing. */
export function decodeClient(bytes) {
  const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  if (u8.length < HEADER_LEN) return { error: "short header" };
  const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
  if (dv.getUint8(0) !== 0xda || dv.getUint8(1) !== 0x01) return { error: "bad magic or version" };
  const opcode = dv.getUint16(2, true);
  const payloadLen = dv.getUint32(4, true);
  if (payloadLen !== u8.length - HEADER_LEN) return { error: `payload_len ${payloadLen} != ${u8.length - HEADER_LEN}` };
  const timestampUs = dv.getBigUint64(8, true).toString();
  const p = HEADER_LEN;
  const base = { opcode, name: OPCODE_NAMES[opcode] ?? `0x${opcode.toString(16)}`, payloadLen, timestampUs, len: u8.length, hex: toHex(u8) };
  switch (opcode) {
    case 0x0001: {
      if (payloadLen < 14) return { ...base, error: "short handshake" };
      const nameLen = dv.getUint16(p + 12, true);
      if (nameLen !== payloadLen - 14) return { ...base, error: "name_len mismatch" };
      const name = new TextDecoder().decode(u8.subarray(p + 14, p + 14 + nameLen));
      return { ...base, canvasWidth: dv.getFloat32(p, true), canvasHeight: dv.getFloat32(p + 4, true), dpi: dv.getFloat32(p + 8, true), clientName: name };
    }
    case 0x0010: {
      if (payloadLen !== 31 && payloadLen !== 25) return { ...base, error: `stroke_start size ${payloadLen}` };
      const out = {
        ...base,
        strokeId: uuidString(u8, p),
        tool: dv.getUint8(p + 16),
        color: dv.getUint32(p + 17, true),
        baseWidth: dv.getFloat32(p + 21, true),
        pointerType: 0,
        phase: 1,
        pressure: 0.5,
      };
      if (payloadLen === 31) {
        out.pointerType = dv.getUint8(p + 25);
        out.phase = dv.getUint8(p + 26);
        out.pressure = dv.getFloat32(p + 27, true);
      }
      return out;
    }
    case 0x0011: {
      if (payloadLen < 18) return { ...base, error: "short chunk" };
      const count = dv.getUint16(p + 16, true);
      if (count < 1 || count > 4096 || payloadLen !== 18 + count * POINT_LEN) return { ...base, error: `chunk count ${count} vs ${payloadLen}` };
      const points = [];
      let o = p + 18;
      for (let i = 0; i < count; i++) {
        points.push({ x32: dv.getInt32(o, true), y32: dv.getInt32(o + 4, true), pressure: dv.getUint8(o + 8), deltaMs: dv.getUint16(o + 9, true) });
        o += POINT_LEN;
      }
      return { ...base, strokeId: uuidString(u8, p), count, points };
    }
    case 0x0012:
      if (payloadLen !== 20) return { ...base, error: "commit size" };
      return { ...base, strokeId: uuidString(u8, p), pointCount: dv.getUint32(p + 16, true) };
    case 0x0013:
      if (payloadLen !== 16) return { ...base, error: "cancel size" };
      return { ...base, strokeId: uuidString(u8, p) };
    case 0x0014:
    case 0x0015:
    case 0x0040:
      if (payloadLen === 0 && opcode === 0x0040) return { ...base, pageId: null, clientTimeUs: null };
      if (payloadLen !== 24) return { ...base, error: "page+time size" };
      return { ...base, pageId: uuidString(u8, p), clientTimeUs: dv.getBigUint64(p + 16, true).toString() };
    case 0x0020: {
      if (payloadLen < 22) return { ...base, error: "short erase" };
      const count = dv.getUint16(p + 20, true);
      if (count > 1024 || payloadLen !== 22 + 16 * count) return { ...base, error: "erase count" };
      const ids = [];
      for (let i = 0; i < count; i++) ids.push(uuidString(u8, p + 22 + 16 * i));
      return {
        ...base,
        x1: dv.getFloat32(p, true),
        y1: dv.getFloat32(p + 4, true),
        x2: dv.getFloat32(p + 8, true),
        y2: dv.getFloat32(p + 12, true),
        radius: dv.getFloat32(p + 16, true),
        ids,
      };
    }
    case 0x0030:
      if (payloadLen !== 16) return { ...base, error: "laser size" };
      return { ...base, x: dv.getFloat32(p, true), y: dv.getFloat32(p + 4, true), intensity: dv.getFloat32(p + 8, true), decayS: dv.getFloat32(p + 12, true) };
    case 0x0050:
      if (payloadLen !== 28) return { ...base, error: "page_change size" };
      return { ...base, pageId: uuidString(u8, p), width: dv.getFloat32(p + 16, true), height: dv.getFloat32(p + 20, true), pageIndex: dv.getUint32(p + 24, true) };
    case 0x0060:
      if (payloadLen !== 8) return { ...base, error: "return size" };
      return { ...base, clientTimeUs: dv.getBigUint64(p, true).toString() };
    case 0x0061:
      if (payloadLen !== 9) return { ...base, error: "pin size" };
      return { ...base, value: dv.getInt8(p), clientTimeUs: dv.getBigUint64(p + 1, true).toString() };
    case 0x00fe:
      if (payloadLen !== 16) return { ...base, error: "ping size" };
      return { ...base, sequence: dv.getBigUint64(p, true).toString(), clientTimeUs: dv.getBigUint64(p + 8, true).toString() };
    default:
      return { ...base, unknown: true };
  }
}

function header(opcode, payloadLen, timestampUs) {
  const buf = new Uint8Array(HEADER_LEN + payloadLen);
  const dv = new DataView(buf.buffer);
  dv.setUint8(0, 0xda);
  dv.setUint8(1, 0x01);
  dv.setUint16(2, opcode, true);
  dv.setUint32(4, payloadLen, true);
  dv.setBigUint64(8, BigInt(timestampUs), true);
  return { buf, dv };
}

export function encodeAck(status, timestampUs = Date.now() * 1000) {
  const { buf, dv } = header(0x0002, 16, timestampUs);
  dv.setUint32(16, 1920, true);
  dv.setUint32(20, 1080, true);
  dv.setUint32(24, 30, true);
  dv.setUint32(28, status, true);
  return buf;
}

/** flags may be a number or an object of booleans {pinned, preWarning, allowed, activeSource, cameraAttached, sinkConnected, saving, captureIdle}. */
export function flagsByte(flags) {
  if (typeof flags === "number") return flags & 0xff;
  let f = 0;
  if (flags.pinned) f |= 1;
  if (flags.preWarning) f |= 2;
  if (flags.allowed) f |= 4;
  if (flags.activeSource) f |= 8;
  if (flags.cameraAttached) f |= 16;
  if (flags.sinkConnected) f |= 32;
  if (flags.saving) f |= 64;
  if (flags.captureIdle) f |= 128;
  return f;
}

export function encodeState(s, timestampUs = Date.now() * 1000) {
  const { buf, dv } = header(0x0070, 20, timestampUs);
  dv.setUint8(16, s.governor ?? 0);
  dv.setUint8(17, flagsByte(s.flags ?? { allowed: true, activeSource: true }));
  dv.setUint8(18, s.mode ?? 0);
  dv.setUint8(19, s.inkSource ?? 0);
  dv.setFloat32(20, s.progress ?? 0, true);
  dv.setUint32(24, s.msToReturn === null || s.msToReturn === undefined ? 0xffffffff : s.msToReturn, true);
  dv.setUint16(28, s.pageIndex ?? 0, true);
  dv.setUint16(30, s.strokeCount ?? 0, true);
  dv.setUint16(32, s.undoDepth ?? 0, true);
  dv.setUint16(34, s.redoDepth ?? 0, true);
  return buf;
}

/** PONG echoes the PING payload unchanged (16 bytes after the header). */
export function encodePong(pingFrame, timestampUs = Date.now() * 1000) {
  const { buf } = header(0x00ff, 16, timestampUs);
  buf.set(pingFrame.subarray(HEADER_LEN, HEADER_LEN + 16), HEADER_LEN);
  return buf;
}
