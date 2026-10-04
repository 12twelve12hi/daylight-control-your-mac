// Cross-language fuzz parity (protocol/fuzz/README.md): every case of tests/fuzz/corpus.json through web/src/protocol.ts.
// The page encodes the client-to-server SolStream v1 messages and decodes HANDSHAKE_ACK, STATE and PONG; every other
// opcode is one it ignores (PROTOCOL 5 and 10), so for those the expected decision is "ignore" unless the header
// itself is bad.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { Encoder, Opcode, decodeServer, fromHex, toHex, uuidFromString, type WirePoint } from "../../src/protocol.js";

type Decision = "accept" | "reject" | "ignore" | "encode_reject";

interface FuzzCase {
  name: string;
  kind: string;
  opcode: number;
  direction: "c2s" | "s2c";
  hex?: string;
  pad?: number;
  expect: Decision;
  layer?: "header" | "payload";
  canonical?: string;
  canonical_pad?: number;
  timestamp_us: string;
  fields?: Record<string, unknown>;
  encodable?: boolean;
  finding?: string;
}

interface Corpus {
  version: number;
  generator: string;
  opcodes: number[];
  cases: FuzzCase[];
}

const corpus = JSON.parse(readFileSync(resolve("tests/fuzz/corpus.json"), "utf8")) as Corpus;

/** Opcodes web/src/protocol.ts decodes (decodeServer) and encodes (Encoder). */
const DECODES = new Set<number>([Opcode.HANDSHAKE_ACK, Opcode.STATE, Opcode.PONG]);
const ENCODES = new Set<number>([
  Opcode.HANDSHAKE, Opcode.STROKE_START, Opcode.STROKE_CHUNK, Opcode.STROKE_COMMIT, Opcode.STROKE_CANCEL, Opcode.UNDO,
  Opcode.REDO, Opcode.ERASE_STROKES, Opcode.LASER_POINT, Opcode.CLEAR_CANVAS, Opcode.PAGE_CHANGE,
  Opcode.AUTO_ENGAGE_RETURN, Opcode.TOGGLE_PIN, Opcode.PING,
]);

/** Cases this codec is known to get wrong, each naming its finding; the test fails if one of them starts to pass. */
const KNOWN_DIVERGENT = new Map<string, string>();

function frameBytes(hex: string, pad = 0): Uint8Array {
  const head = fromHex(hex);
  const out = new Uint8Array(head.length + pad);
  out.set(head);
  return out;
}

function expected(c: FuzzCase, implemented: boolean): Decision {
  if (implemented) return c.expect;
  return c.expect === "reject" && c.layer === "header" ? "reject" : "ignore";
}

const num = (f: Record<string, unknown>, k: string): number => {
  const v = f[k];
  if (typeof v !== "number") throw new Error(`field ${k} is not a number`);
  return v;
};
const str = (f: Record<string, unknown>, k: string): string => {
  const v = f[k];
  if (typeof v !== "string") throw new Error(`field ${k} is not a string`);
  return v;
};
const big = (f: Record<string, unknown>, k: string): bigint => BigInt(str(f, k));

function points(f: Record<string, unknown>): WirePoint[] {
  const raw = f.points as [number, number, number, number][];
  const repeat = typeof f.points_repeat === "number" ? f.points_repeat : 1;
  const out: WirePoint[] = [];
  for (let i = 0; i < repeat; i++) for (const [x, y, pressure, deltaMs] of raw) out.push({ x, y, pressure, deltaMs });
  return out;
}

function ids(f: Record<string, unknown>): Uint8Array[] {
  const raw = (f.ids as string[]).map(uuidFromString);
  const repeat = typeof f.ids_repeat === "number" ? f.ids_repeat : 1;
  const out: Uint8Array[] = [];
  for (let i = 0; i < repeat; i++) out.push(...raw);
  return out;
}

/** Encodes a client-to-server case from its fields with the case's header timestamp. */
function encode(c: FuzzCase): ArrayBuffer {
  const f = c.fields ?? {};
  const enc = new Encoder(() => BigInt(c.timestamp_us));
  switch (c.opcode) {
    case Opcode.HANDSHAKE: return enc.handshake(num(f, "canvas_width"), num(f, "canvas_height"), num(f, "dpi"), str(f, "name"));
    case Opcode.STROKE_START:
      return enc.strokeStart(uuidFromString(str(f, "stroke_id")), num(f, "tool") as 0 | 1 | 2 | 3, num(f, "color"), num(f, "base_width"), num(f, "pressure"));
    case Opcode.STROKE_CHUNK: return enc.strokeChunk(uuidFromString(str(f, "stroke_id")), points(f));
    case Opcode.STROKE_COMMIT: return enc.strokeCommit(uuidFromString(str(f, "stroke_id")), num(f, "point_count"));
    case Opcode.STROKE_CANCEL: return enc.strokeCancel(uuidFromString(str(f, "stroke_id")));
    case Opcode.UNDO: return enc.undo(uuidFromString(str(f, "page_id")), big(f, "client_time_us"));
    case Opcode.REDO: return enc.redo(uuidFromString(str(f, "page_id")), big(f, "client_time_us"));
    case Opcode.CLEAR_CANVAS: return enc.clear(uuidFromString(str(f, "page_id")), big(f, "client_time_us"));
    case Opcode.ERASE_STROKES: return enc.erase(num(f, "x1"), num(f, "y1"), num(f, "x2"), num(f, "y2"), num(f, "radius"), ids(f));
    case Opcode.LASER_POINT: return enc.laserPoint(num(f, "x"), num(f, "y"), num(f, "intensity"), num(f, "decay_s"));
    case Opcode.PAGE_CHANGE: return enc.pageChange(uuidFromString(str(f, "page_id")), num(f, "width"), num(f, "height"), num(f, "page_index"));
    case Opcode.AUTO_ENGAGE_RETURN: return enc.returnNow(big(f, "client_time_us"));
    case Opcode.TOGGLE_PIN: return enc.togglePin(num(f, "value") as -1 | 0 | 1, big(f, "client_time_us"));
    case Opcode.PING: return enc.ping(big(f, "sequence"), big(f, "client_time_us"));
    default: throw new Error(`no encoder for opcode ${c.opcode}`);
  }
}

/** Runs one case; returns a description of every way the codec disagrees with the corpus (empty when it agrees). */
function check(c: FuzzCase): string[] {
  const problems: string[] = [];
  if (c.expect === "encode_reject") {
    if (!ENCODES.has(c.opcode)) return problems;
    let threw = false;
    try { encode(c); } catch { threw = true; }
    if (!threw) problems.push("encoder accepted fields it must refuse");
    return problems;
  }
  const buf = frameBytes(c.hex!, c.pad ?? 0);
  const msg = decodeServer(buf.buffer as ArrayBuffer);
  const got: Decision = msg === null ? "reject" : "ack" in msg || "state" in msg || "pong" in msg ? "accept" : "ignore";
  const want = expected(c, DECODES.has(c.opcode));
  if (got !== want) problems.push(`decode: expected ${want}, got ${got}`);
  if (want === "accept" && msg !== null && c.fields) {
    const f = c.fields;
    if ("ack" in msg) {
      const a = { w: num(f, "target_width"), h: num(f, "target_height"), fps: num(f, "target_fps"), status: num(f, "status") };
      if (JSON.stringify(msg.ack) !== JSON.stringify(a)) problems.push(`ack fields ${JSON.stringify(msg.ack)} != ${JSON.stringify(a)}`);
    } else if ("state" in msg) {
      const s = msg.state;
      const flags = (s.pinned ? 1 : 0) | (s.preWarning ? 2 : 0) | (s.allowed ? 4 : 0) | (s.activeSource ? 8 : 0)
        | (s.cameraAttached ? 16 : 0) | (s.sinkConnected ? 32 : 0) | (s.saving ? 64 : 0) | (s.captureIdle ? 128 : 0);
      const got = [s.governor, flags, s.mode, s.inkSource, s.progress, s.msToReturn ?? 0xffffffff, s.pageIndex, s.strokeCount, s.undoDepth, s.redoDepth];
      const want = ["governor", "flags", "mode", "ink_source", "progress", "ms_to_return", "page_index", "stroke_count", "undo_depth", "redo_depth"].map((k) => num(f, k));
      if (!Object.is(JSON.stringify(got), JSON.stringify(want)) || !Object.is(s.progress, num(f, "progress"))) problems.push(`state fields ${JSON.stringify(got)} != ${JSON.stringify(want)}`);
    } else if ("pong" in msg) {
      if (msg.pong.seq !== big(f, "sequence") || msg.pong.t !== big(f, "client_time_us")) problems.push("pong fields differ");
    }
  }
  if (c.expect === "accept" && c.direction === "c2s" && c.encodable && ENCODES.has(c.opcode)) {
    const want = toHex(frameBytes(c.canonical!, c.canonical_pad ?? c.pad ?? 0));
    let got: string;
    try { got = toHex(encode(c)); } catch (e) { got = `threw ${(e as Error).message}`; }
    if (got !== want) problems.push(`encode: ${got.slice(0, 120)} != canonical ${want.slice(0, 120)}`);
  }
  return problems;
}

test("fuzz corpus is version 1 and covers every opcode", () => {
  assert.equal(corpus.version, 1);
  assert.equal(corpus.generator, "gen_fuzz.py");
  assert.ok(corpus.cases.length >= 500, `only ${corpus.cases.length} cases`);
  for (const op of corpus.opcodes) assert.ok(corpus.cases.some((c) => c.opcode === op && c.expect === "accept"), `no valid case for 0x${op.toString(16)}`);
});

test("web codec agrees with the fuzz corpus on every case (decisions, decoded fields, byte-exact encodes)", () => {
  const failures: string[] = [];
  for (const c of corpus.cases) {
    const problems = check(c);
    const known = KNOWN_DIVERGENT.get(c.name);
    if (known) {
      if (problems.length === 0) failures.push(`${c.name}: listed as divergent (${known}) but now agrees; remove it from KNOWN_DIVERGENT`);
    } else if (problems.length > 0) {
      failures.push(`${c.name}${c.finding ? ` [${c.finding}]` : ""}: ${problems.join("; ")}`);
    }
  }
  assert.deepEqual(failures, []);
});
