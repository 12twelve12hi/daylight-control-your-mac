// SPEC 16 D2: the encoder reproduces every c2s golden hex INSIDE the browser context, and decodeServer
// parses every s2c case (ACK, STATE, PONG). The manifest is the generated copy in tests/golden.
import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

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
  websocket: { accept: string; key: string };
  cases: GoldenCase[];
}

const manifest = JSON.parse(readFileSync(resolve("tests/golden/solstream-v1.json"), "utf8")) as Manifest;

test("manifest is version 1 with the 26 cases", () => {
  expect(manifest.version).toBe(1);
  expect(manifest.cases.length).toBe(26);
  expect(manifest.websocket.accept).toBe("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
});

test("every c2s golden case encodes byte for byte in the browser", async ({ page }) => {
  await page.goto("/");
  const c2s = manifest.cases.filter((c) => c.direction === "c2s" && !c.decode_only);
  expect(c2s.length).toBeGreaterThanOrEqual(18);
  const results = await page.evaluate(
    ({ cases, ts, strokeId, pageId }) => {
      type Enc = {
        handshake(w: number, h: number, dpi: number, name: string): ArrayBuffer;
        strokeStart(id: Uint8Array, tool: 0 | 1 | 2 | 3, color: number, width: number, pressure: number): ArrayBuffer;
        strokeChunk(id: Uint8Array, pts: { x: number; y: number; pressure: number; deltaMs: number }[]): ArrayBuffer;
        strokeCommit(id: Uint8Array, count: number): ArrayBuffer;
        strokeCancel(id: Uint8Array): ArrayBuffer;
        undo(pageId: Uint8Array | null, t: bigint): ArrayBuffer;
        redo(pageId: Uint8Array | null, t: bigint): ArrayBuffer;
        clear(pageId: Uint8Array | null, t: bigint): ArrayBuffer;
        erase(x1: number, y1: number, x2: number, y2: number, r: number, ids: Uint8Array[]): ArrayBuffer;
        laserPoint(x: number, y: number, i: number, d: number): ArrayBuffer;
        pageChange(pageId: Uint8Array, w: number, h: number, index: number): ArrayBuffer;
        returnNow(t: bigint): ArrayBuffer;
        togglePin(v: -1 | 0 | 1, t: bigint): ArrayBuffer;
        ping(seq: bigint, t: bigint): ArrayBuffer;
      };
      const d = (window as unknown as { __daylight: { protocol: { Encoder: new (now: () => bigint) => Enc; uuidFromString(s: string): Uint8Array; toHex(b: ArrayBuffer): string } } }).__daylight;
      const P = d.protocol;
      const t = BigInt(ts);
      const enc = new P.Encoder(() => t);
      const sid = P.uuidFromString(strokeId);
      const pid = P.uuidFromString(pageId);
      const out: { name: string; hex: string | null }[] = [];
      for (const c of cases) {
        const f = c.fields as Record<string, number>;
        let buf: ArrayBuffer | null = null;
        switch (c.name) {
          case "handshake": buf = enc.handshake(f.canvas_width!, f.canvas_height!, f.dpi!, c.fields.name as string); break;
          case "stroke_start":
          case "stroke_start_highlighter": buf = enc.strokeStart(sid, f.tool as 0 | 1 | 2 | 3, f.color!, f.base_width!, f.pressure!); break;
          case "stroke_chunk_3pts": buf = enc.strokeChunk(sid, (c.fields.points as { x: number; y: number; pressure: number; delta_ms: number }[]).map((p) => ({ x: p.x, y: p.y, pressure: p.pressure, deltaMs: p.delta_ms }))); break;
          case "stroke_commit": buf = enc.strokeCommit(sid, f.point_count!); break;
          case "stroke_cancel": buf = enc.strokeCancel(sid); break;
          case "undo": buf = enc.undo(pid, t); break;
          case "redo": buf = enc.redo(pid, t); break;
          case "undo_current_page": buf = enc.undo(null, t); break;
          case "erase_strokes": buf = enc.erase(f.x1!, f.y1!, f.x2!, f.y2!, f.radius!, (c.fields.ids as string[]).map((s) => P.uuidFromString(s))); break;
          case "laser_point": buf = enc.laserPoint(f.x!, f.y!, f.intensity!, f.decay_s!); break;
          case "clear_canvas": buf = enc.clear(pid, t); break;
          case "page_change": buf = enc.pageChange(pid, f.width!, f.height!, f.page_index!); break;
          case "auto_engage_return": buf = enc.returnNow(t); break;
          case "toggle_pin_toggle": case "toggle_pin_on": case "toggle_pin_off": buf = enc.togglePin(f.value as -1 | 0 | 1, t); break;
          case "ping": buf = enc.ping(BigInt(f.sequence!), t); break;
        }
        out.push({ name: c.name, hex: buf ? P.toHex(buf) : null });
      }
      return out;
    },
    { cases: c2s, ts: String(manifest.timestamp_us), strokeId: manifest.stroke_id, pageId: manifest.page_id },
  );
  for (const c of c2s) {
    const r = results.find((x) => x.name === c.name);
    expect(r, `no encoder mapping for ${c.name}`).toBeTruthy();
    expect(r!.hex, c.name).toBe(c.hex);
  }
});

test("decodeServer parses every s2c case in the browser", async ({ page }) => {
  await page.goto("/");
  const s2c = manifest.cases.filter((c) => c.direction === "s2c");
  expect(s2c.length).toBe(6);
  const decoded = await page.evaluate((cases) => {
    const d = (window as unknown as { __daylight: { protocol: { decodeServer(b: ArrayBuffer): unknown; fromHex(h: string): Uint8Array } } }).__daylight;
    return cases.map((c) => {
      const u8 = d.protocol.fromHex(c.hex);
      const msg = d.protocol.decodeServer(u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength) as ArrayBuffer) as Record<string, unknown> | null;
      return { name: c.name, msg: JSON.parse(JSON.stringify(msg, (_k, v) => (typeof v === "bigint" ? v.toString() : v))) as Record<string, unknown> | null };
    });
  }, s2c);
  for (const c of s2c) {
    const r = decoded.find((x) => x.name === c.name)!;
    expect(r.msg, c.name).toBeTruthy();
    const f = c.fields as Record<string, number>;
    expect(r.msg!.opcode).toBe(c.opcode);
    if (c.opcode === 2) {
      expect(r.msg!.ack).toEqual({ w: f.target_width, h: f.target_height, fps: f.target_fps, status: f.status });
    }
    if (c.opcode === 0x70) {
      const s = r.msg!.state as Record<string, unknown>;
      expect(s.governor).toBe(f.governor);
      expect(s.pinned).toBe((f.flags! & 1) !== 0);
      expect(s.preWarning).toBe((f.flags! & 2) !== 0);
      expect(s.allowed).toBe((f.flags! & 4) !== 0);
      expect(s.activeSource).toBe((f.flags! & 8) !== 0);
      expect(s.cameraAttached).toBe((f.flags! & 16) !== 0);
      expect(s.sinkConnected).toBe((f.flags! & 32) !== 0);
      expect(s.captureIdle).toBe((f.flags! & 128) !== 0);
      expect(s.mode).toBe(f.mode);
      expect(s.inkSource).toBe(f.ink_source);
      expect(s.msToReturn).toBe(f.ms_to_return === 0xffffffff ? null : f.ms_to_return);
      expect(s.pageIndex).toBe(f.page_index);
      expect(s.strokeCount).toBe(f.stroke_count);
      expect(s.undoDepth).toBe(f.undo_depth);
      expect(s.redoDepth).toBe(f.redo_depth);
      expect(Math.abs((s.progress as number) - f.progress!)).toBeLessThan(1e-6);
    }
    if (c.opcode === 0xff) {
      expect((r.msg!.pong as Record<string, string>).seq).toBe(String(f.sequence));
      expect((r.msg!.pong as Record<string, string>).t).toBe(String(manifest.timestamp_us));
    }
  }
});

test("a STATE longer than 20 bytes is accepted (compatible additions) and bad frames are rejected", async ({ page }) => {
  await page.goto("/");
  const stateCase = manifest.cases.find((c) => c.name === "state_live_pinned")!;
  const result = await page.evaluate((hex) => {
    const d = (window as unknown as { __daylight: { protocol: { decodeServer(b: ArrayBuffer): { state?: { governor: number; undoDepth: number } } | null; fromHex(h: string): Uint8Array } } }).__daylight;
    const u8 = d.protocol.fromHex(hex);
    const longer = new Uint8Array(u8.length + 4);
    longer.set(u8);
    new DataView(longer.buffer).setUint32(4, 24, true);   // payload_len grows with the appended field
    const ok = d.protocol.decodeServer(longer.buffer as ArrayBuffer);
    const badMagic = new Uint8Array(u8); badMagic[0] = 0;
    const badLen = new Uint8Array(u8); new DataView(badLen.buffer).setUint32(4, 19, true);
    return {
      longer: ok?.state ? { governor: ok.state.governor, undoDepth: ok.state.undoDepth } : null,
      badMagic: d.protocol.decodeServer(badMagic.buffer as ArrayBuffer),
      badLen: d.protocol.decodeServer(badLen.buffer as ArrayBuffer),
      short: d.protocol.decodeServer(new ArrayBuffer(3)),
    };
  }, stateCase.hex);
  expect(result.longer).toEqual({ governor: 2, undoDepth: 3 });
  expect(result.badMagic).toBeNull();
  expect(result.badLen).toBeNull();
  expect(result.short).toBeNull();
});
