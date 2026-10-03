import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { Encoder, Opcode, decodeServer, fromHex, toHex, uuidFromString, uuidToString, type WirePoint } from "../../src/protocol.js";

interface GoldenCase {
  name: string;
  opcode: number;
  direction: "c2s" | "s2c";
  decode_only: boolean;
  hex: string;
  fields: Record<string, unknown>;
}

interface Manifest {
  version: number;
  timestamp_us: number;
  stroke_id: string;
  page_id: string;
  cases: GoldenCase[];
}

const manifest = JSON.parse(readFileSync(resolve("tests/golden/solstream-v1.json"), "utf8")) as Manifest;
const ts = BigInt(manifest.timestamp_us);
const enc = new Encoder(() => ts);
const strokeId = uuidFromString(manifest.stroke_id);
const pageId = uuidFromString(manifest.page_id);
const f = (c: GoldenCase) => c.fields as Record<string, number>;

/** Encodes a client-to-server golden case from its fields. */
function encodeCase(c: GoldenCase): ArrayBuffer | null {
  const fields = c.fields;
  switch (c.name) {
    case "handshake":
      return enc.handshake(f(c).canvas_width!, f(c).canvas_height!, f(c).dpi!, fields.name as string);
    case "stroke_start":
    case "stroke_start_highlighter":
      return enc.strokeStart(strokeId, f(c).tool as 0 | 1 | 2 | 3, f(c).color!, f(c).base_width!, f(c).pressure!);
    case "stroke_chunk_3pts": {
      const pts = (fields.points as { x: number; y: number; pressure: number; delta_ms: number }[]).map<WirePoint>((p) => ({ x: p.x, y: p.y, pressure: p.pressure, deltaMs: p.delta_ms }));
      return enc.strokeChunk(strokeId, pts);
    }
    case "stroke_commit": return enc.strokeCommit(strokeId, f(c).point_count!);
    case "stroke_cancel": return enc.strokeCancel(strokeId);
    case "undo": return enc.undo(pageId, ts);
    case "redo": return enc.redo(pageId, ts);
    case "undo_current_page": return enc.undo(null, ts);
    case "erase_strokes": return enc.erase(f(c).x1!, f(c).y1!, f(c).x2!, f(c).y2!, f(c).radius!, (fields.ids as string[]).map(uuidFromString));
    case "laser_point": return enc.laserPoint(f(c).x!, f(c).y!, f(c).intensity!, f(c).decay_s!);
    case "clear_canvas": return enc.clear(pageId, ts);
    case "page_change": return enc.pageChange(pageId, f(c).width!, f(c).height!, f(c).page_index!);
    case "auto_engage_return": return enc.returnNow(ts);
    case "toggle_pin_toggle": case "toggle_pin_on": case "toggle_pin_off": return enc.togglePin(f(c).value as -1 | 0 | 1, ts);
    case "ping": return enc.ping(BigInt(f(c).sequence!), ts);
    default: return null;
  }
}

test("manifest is version 1 with 26 cases", () => {
  assert.equal(manifest.version, 1);
  assert.equal(manifest.cases.length, 26);
});

test("every c2s case encodes byte for byte", () => {
  const c2s = manifest.cases.filter((c) => c.direction === "c2s" && !c.decode_only);
  assert.ok(c2s.length >= 18);
  for (const c of c2s) {
    const buf = encodeCase(c);
    assert.ok(buf, `no encoder mapping for ${c.name}`);
    assert.equal(toHex(buf), c.hex, c.name);
  }
});

test("every s2c case decodes", () => {
  for (const c of manifest.cases.filter((c) => c.direction === "s2c")) {
    const msg = decodeServer(fromHex(c.hex).buffer as ArrayBuffer);
    assert.ok(msg, c.name);
    assert.equal(msg.opcode, c.opcode, c.name);
    if ("ack" in msg) {
      assert.deepEqual(msg.ack, { w: f(c).target_width, h: f(c).target_height, fps: f(c).target_fps, status: f(c).status });
    }
    if ("state" in msg) {
      assert.equal(msg.state.governor, f(c).governor, c.name);
      assert.equal(msg.state.pinned, (f(c).flags! & 1) !== 0);
      assert.equal(msg.state.preWarning, (f(c).flags! & 2) !== 0);
      assert.equal(msg.state.activeSource, (f(c).flags! & 8) !== 0);
      assert.equal(msg.state.inkSource, f(c).ink_source);
      assert.equal(msg.state.msToReturn, f(c).ms_to_return === 0xffffffff ? null : f(c).ms_to_return);
      assert.equal(msg.state.undoDepth, f(c).undo_depth);
      assert.equal(msg.state.redoDepth, f(c).redo_depth);
      assert.ok(Math.abs(msg.state.progress - f(c).progress!) < 1e-6);
    }
    if ("pong" in msg) {
      assert.equal(msg.pong.seq, BigInt(f(c).sequence!));
      assert.equal(msg.pong.t, ts);
    }
  }
});

test("uuid round trip and bad frames", () => {
  assert.equal(uuidToString(strokeId), manifest.stroke_id);
  assert.equal(decodeServer(new ArrayBuffer(3)), null);
  const bad = fromHex(manifest.cases[0]!.hex);
  bad[0] = 0;
  assert.equal(decodeServer(bad.buffer as ArrayBuffer), null);
});
