// SPEC 16 D3: a CDP pen stroke with forces 0.3, 0.6, 0.9 yields a 31-byte STROKE_START (pointer 0,
// phase 1, pressure 0.3), chunks in canvas units with monotonic delta_ms from the first point, and a
// COMMIT; a finger tap yields nothing; a pen mousePressed with force 0 yields nothing; hover yields
// nothing; pointercancel after >= 2 points and > 80 ms yields COMMIT, otherwise CANCEL.
import { test, expect } from "@playwright/test";
import { FakeMac, type FakeFrame, debugValue, fingerDrag, fingerTap, inkAlphaAt, openWhiteboard, paperBox, penCancel, penHover, penMove, penRelease, penStroke, penZeroPressureTap, recordPenPointerId, toPage, waitForFrames } from "./pen.js";

const STROKE_START_PAYLOAD = 31;
const HEADER = 16;

test.beforeEach(async ({ request }) => {
  await new FakeMac(request).reset();
});

function inkFrames(frames: FakeFrame[]): FakeFrame[] {
  return frames.filter((f) => f.name.startsWith("STROKE_") || f.name === "ERASE_STROKES");
}

test("pen stroke with forces 0.3, 0.6, 0.9: 31-byte START, canvas-unit chunk, monotonic delta_ms, COMMIT", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const box = await paperBox(page);
  const a = toPage(box, 100, 100);
  const b = toPage(box, 160, 130);
  const c = toPage(box, 220, 170);
  await penStroke(page, [{ ...a, p: 0.3 }, { ...b, p: 0.6 }, { ...c, p: 0.9 }]);

  const commits = await waitForFrames(fake, "STROKE_COMMIT");
  const frames = inkFrames(await fake.frames());
  expect(frames.map((f) => f.name)[0]).toBe("STROKE_START");
  expect(frames[frames.length - 1]!.name).toBe("STROKE_COMMIT");

  const start = frames[0]!;
  expect(start.payloadLen).toBe(STROKE_START_PAYLOAD);
  expect(start.len).toBe(HEADER + STROKE_START_PAYLOAD);
  expect(start.tool).toBe(0);
  expect(start.color).toBe(0xff111111);
  expect(start.baseWidth as number).toBeCloseTo(3.2, 5);
  expect(start.pointerType).toBe(0);
  expect(start.phase).toBe(1);
  expect(start.pressure as number).toBeCloseTo(0.3, 5);

  const chunks = frames.filter((f) => f.name === "STROKE_CHUNK");
  expect(chunks.length).toBeGreaterThanOrEqual(1);
  for (const ch of chunks) expect(ch.strokeId).toBe(start.strokeId);
  const points = chunks.flatMap((ch) => ch.points as { x32: number; y32: number; pressure: number; deltaMs: number }[]);
  expect(points.length).toBe(3);
  // Canvas units: x32 / 32 lands on the canvas-unit coordinate we aimed at (viewport 1200x1600 at DPR 1).
  const expected = [[100, 100, 77], [160, 130, 153], [220, 170, 230]];
  points.forEach((p, i) => {
    expect(Math.abs(p.x32 / 32 - expected[i]![0]!)).toBeLessThan(1.5);
    expect(Math.abs(p.y32 / 32 - expected[i]![1]!)).toBeLessThan(1.5);
    // Chromium hands the force over as a float32 (0.9 arrives as 0.89999998), so allow the one-step rounding difference.
    expect(Math.abs(p.pressure - expected[i]![2]!)).toBeLessThanOrEqual(1);
  });
  expect(points[0]!.deltaMs).toBe(0);
  for (let i = 1; i < points.length; i++) expect(points[i]!.deltaMs).toBeGreaterThanOrEqual(points[i - 1]!.deltaMs);
  expect(points[2]!.deltaMs).toBeLessThan(65535);

  expect(commits[0]!.strokeId).toBe(start.strokeId);
  expect(commits[0]!.pointCount).toBe(3);
  expect(commits[0]!.payloadLen).toBe(20);

  const stats = await debugValue<{ strokes: number; points: number; committed: number }>(page, "ink");
  expect(stats.strokes).toBe(1);
  expect(stats.points).toBe(3);
  expect(stats.committed).toBe(1);
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(1);
});

test("a finger tap and a palm drag yield nothing", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const box = await paperBox(page);
  await fingerTap(page, box.x + 600, box.y + 800);
  await fingerDrag(page, [{ x: box.x + 300, y: box.y + 300 }, { x: box.x + 400, y: box.y + 420 }, { x: box.x + 500, y: box.y + 560 }]);
  await page.waitForTimeout(300);
  expect(inkFrames(await fake.frames())).toEqual([]);
  const stats = await debugValue<{ strokes: number; ignored: number }>(page, "ink");
  expect(stats.strokes).toBe(0);
  expect(stats.ignored).toBeGreaterThanOrEqual(2);
});

test("a pen press with force 0 (side button in the air) yields nothing", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const box = await paperBox(page);
  await penZeroPressureTap(page, box.x + 300, box.y + 300);
  await page.waitForTimeout(300);
  expect(inkFrames(await fake.frames())).toEqual([]);
  const stats = await debugValue<{ strokes: number; ignored: number }>(page, "ink");
  expect(stats.strokes).toBe(0);
  expect(stats.ignored).toBe(1);
});

test("hover yields nothing", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const box = await paperBox(page);
  await penHover(page, [{ x: box.x + 100, y: box.y + 100 }, { x: box.x + 200, y: box.y + 220 }, { x: box.x + 300, y: box.y + 330 }]);
  await page.waitForTimeout(300);
  expect(inkFrames(await fake.frames())).toEqual([]);
  expect((await debugValue<{ strokes: number }>(page, "ink")).strokes).toBe(0);
});

test("pointercancel after >= 2 points and > 80 ms commits; a young cancel sends STROKE_CANCEL", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  await recordPenPointerId(page);
  const box = await paperBox(page);

  // Old enough and long enough: COMMIT.
  const a = toPage(box, 200, 200);
  const b = toPage(box, 260, 240);
  const c = toPage(box, 320, 300);
  await penStroke(page, [{ ...a, p: 0.5 }, { ...b, p: 0.6 }, { ...c, p: 0.7 }], { release: false });
  await page.waitForTimeout(150);
  await penCancel(page);
  const commits = await waitForFrames(fake, "STROKE_COMMIT");
  expect(commits[0]!.pointCount).toBe(3);
  await penRelease(page, c.x, c.y);
  await page.waitForTimeout(100);
  expect((await fake.framesNamed("STROKE_CANCEL")).length).toBe(0);

  // One point, cancelled at once: STROKE_CANCEL, no COMMIT for it, and the wet dot leaves the ink layer.
  await fake.reset();
  const d = toPage(box, 500, 500);
  await penStroke(page, [{ ...d, p: 0.5 }], { release: false, hoverFirst: false });
  expect(await inkAlphaAt(page, 500, 500)).toBeGreaterThan(0);
  await penCancel(page);
  expect(await inkAlphaAt(page, 500, 500)).toBe(0);
  expect(await inkAlphaAt(page, 260, 240)).toBeGreaterThan(0);   // the committed stroke above survived the redraw
  const cancels = await waitForFrames(fake, "STROKE_CANCEL");
  const starts = await fake.framesNamed("STROKE_START");
  expect(starts.length).toBe(1);
  expect(cancels[0]!.strokeId).toBe(starts[0]!.strokeId);
  expect(cancels[0]!.payloadLen).toBe(16);
  await penRelease(page, d.x, d.y);
  await page.waitForTimeout(100);
  expect((await fake.framesNamed("STROKE_COMMIT")).length).toBe(0);
  const stats = await debugValue<{ cancelled: number; committed: number }>(page, "ink");
  expect(stats.cancelled).toBe(1);
  expect(stats.committed).toBe(1);
});

test("a dot (press and release without moving) commits a one-point stroke", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const box = await paperBox(page);
  const a = toPage(box, 600, 800);
  await penStroke(page, [{ ...a, p: 0.8 }]);
  const commits = await waitForFrames(fake, "STROKE_COMMIT");
  expect(commits[0]!.pointCount).toBe(1);
  const chunks = await fake.framesNamed("STROKE_CHUNK");
  expect(chunks.length).toBe(1);
  expect((chunks[0]!.points as unknown[]).length).toBe(1);
});

test("pressure above 1 is clamped before quantising (never wraps the u8)", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  await page.evaluate(() => {
    // Force the page to see pressure 1.4 (research F3: Android pressure can exceed 1.0 by calibration).
    Object.defineProperty(PointerEvent.prototype, "pressure", { get: () => 1.4, configurable: true });
  });
  const box = await paperBox(page);
  await penStroke(page, [{ ...toPage(box, 100, 1000), p: 0.5 }, { ...toPage(box, 200, 1100), p: 0.5 }]);
  const start = (await waitForFrames(fake, "STROKE_START"))[0]!;
  expect(start.pressure).toBe(1);
  const chunk = (await waitForFrames(fake, "STROKE_CHUNK"))[0]!;
  for (const p of chunk.points as { pressure: number }[]) expect(p.pressure).toBe(255);
});

test("a pen contact that arrives with pressure 0 starts its stroke on the first pressured sample (LOOSE_ENDS D4)", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const box = await paperBox(page);
  const a = toPage(box, 300, 900);
  const b = toPage(box, 360, 930);
  const c = toPage(box, 420, 970);
  const s = await page.context().newCDPSession(page);
  await s.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: a.x, y: a.y, pointerType: "pen", buttons: 0, force: 0 });
  await s.send("Input.dispatchMouseEvent", { type: "mousePressed", x: a.x, y: a.y, button: "left", buttons: 1, clickCount: 1, pointerType: "pen", force: 0 });
  await s.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: b.x, y: b.y, button: "left", buttons: 1, pointerType: "pen", force: 0.6 });
  await s.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: c.x, y: c.y, button: "left", buttons: 1, pointerType: "pen", force: 0.7 });
  await s.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: c.x, y: c.y, button: "left", buttons: 0, clickCount: 1, pointerType: "pen", force: 0 });
  await s.detach();
  const commits = await waitForFrames(fake, "STROKE_COMMIT");
  const starts = await fake.framesNamed("STROKE_START");
  expect(starts.length).toBe(1);
  expect(starts[0]!.pressure as number).toBeCloseTo(0.6, 5);
  const points = (await fake.framesNamed("STROKE_CHUNK")).flatMap((ch) => ch.points as { x32: number; pressure: number; deltaMs: number }[]);
  expect(points.length).toBe(2);
  expect(Math.abs(points[0]!.x32 / 32 - 360)).toBeLessThan(1.5);
  expect(points[0]!.deltaMs).toBe(0);
  expect(commits[0]!.pointCount).toBe(2);
  const stats = await debugValue<{ strokes: number; ignored: number; armedStarts: number; points: number }>(page, "ink");
  expect(stats.strokes).toBe(1);
  expect(stats.ignored).toBe(1);        // the pressure-0 pointerdown still counts for the D4 console fact
  expect(stats.armedStarts).toBe(1);
  expect(stats.points).toBe(2);
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(1);
});

test("the stroke tail goes out before COMMIT even while the socket asks to hold (COMMIT point_count is exact)", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await page.addInitScript(() => {
    // bufferedAmount above HOLD_BYTES (64 KiB) and below THIN_BYTES: the chunk flush would wait for the next frame.
    const w = window as unknown as { __ba: number };
    w.__ba = 0;
    Object.defineProperty(WebSocket.prototype, "bufferedAmount", { get: () => w.__ba, configurable: true });
  });
  await openWhiteboard(page);
  const box = await paperBox(page);
  // Whole stroke under hold: nothing left on the floor.
  await page.evaluate(() => { (window as unknown as { __ba: number }).__ba = 70_000; });
  await penStroke(page, [{ ...toPage(box, 100, 100), p: 0.4 }, { ...toPage(box, 160, 130), p: 0.6 }, { ...toPage(box, 220, 170), p: 0.8 }]);
  let commits = await waitForFrames(fake, "STROKE_COMMIT");
  let chunkPoints = (await fake.framesNamed("STROKE_CHUNK")).reduce((n, ch) => n + (ch.points as unknown[]).length, 0);
  expect(commits[0]!.pointCount).toBe(3);
  expect(chunkPoints).toBe(3);
  expect((await debugValue<{ points: number }>(page, "ink")).points).toBe(3);
  // Partial: two points went out, then the hold starts, two more points, release: the held tail follows, then COMMIT 4.
  await fake.reset();
  await page.evaluate(() => { (window as unknown as { __ba: number }).__ba = 0; });
  const a = toPage(box, 100, 600);
  const b = toPage(box, 160, 630);
  await penStroke(page, [{ ...a, p: 0.5 }, { ...b, p: 0.5 }], { release: false });
  await waitForFrames(fake, "STROKE_CHUNK");
  await page.evaluate(() => { (window as unknown as { __ba: number }).__ba = 70_000; });
  const c = toPage(box, 220, 660);
  const d = toPage(box, 280, 700);
  await penMove(page, [{ ...c, p: 0.5 }, { ...d, p: 0.5 }]);
  await page.waitForTimeout(100);
  expect((await fake.framesNamed("STROKE_CHUNK")).reduce((n, ch) => n + (ch.points as unknown[]).length, 0)).toBe(2);   // held
  await penRelease(page, d.x, d.y);
  commits = await waitForFrames(fake, "STROKE_COMMIT");
  chunkPoints = (await fake.framesNamed("STROKE_CHUNK")).reduce((n, ch) => n + (ch.points as unknown[]).length, 0);
  expect(commits[0]!.pointCount).toBe(4);
  expect(chunkPoints).toBe(4);
  const names = (await fake.frames()).map((f) => f.name).filter((n) => n.startsWith("STROKE_"));
  expect(names[names.length - 1]).toBe("STROKE_COMMIT");
});
