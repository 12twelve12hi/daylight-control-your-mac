// SPEC 16 D4: chip texts and classes for scripted STATE sequences (SPEC 10), tap sends TOGGLE_PIN -1,
// long press sends AUTO_ENGAGE_RETURN, undo/redo buttons follow depths, "Ink source is ... on the Mac"
// when bit3 is clear.
import { test, expect } from "@playwright/test";
import { FakeMac, debugValue, inkAlphaAt, openWhiteboard, paperBox, penStroke, toPage, waitForFrames } from "./pen.js";

test.beforeEach(async ({ request }) => {
  await new FakeMac(request).reset();
});

const allowed = { allowed: true, activeSource: true, cameraAttached: true, sinkConnected: true };

test("chip follows the STATE sequence camera -> LIVE -> pinned -> pre-warning -> returning -> camera", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const chip = page.locator("#chip");
  await expect(chip).toHaveText("Camera");
  await expect(chip).toHaveAttribute("data-state", "camera");

  await fake.state({ governor: 1, flags: allowed, progress: 0.3 });
  await expect(chip).toHaveText("LIVE");
  await expect(chip).toHaveAttribute("data-state", "live");
  await expect(chip.locator(".dot")).toBeVisible();

  await fake.state({ governor: 2, flags: allowed, progress: 1, msToReturn: 60000 });
  await expect(chip).toHaveText("LIVE");

  await fake.state({ governor: 2, flags: { ...allowed, pinned: true }, progress: 1 });
  await expect(chip).toHaveText("KEEP WHITEBOARD");
  await expect(chip).toHaveAttribute("data-state", "pinned");

  await fake.state({ governor: 2, flags: { ...allowed, preWarning: true }, progress: 1, msToReturn: 4200 });
  await expect(chip).toHaveText("Returning in 5");
  await expect(chip).toHaveAttribute("data-state", "prewarn");
  // Counts down locally between STATE messages.
  await expect(chip).toHaveText("Returning in 4", { timeout: 2500 });
  const chipDbg = await debugValue<{ breathing: boolean; breath: number }>(page, "chip");
  expect(chipDbg.breathing).toBe(true);
  expect(chipDbg.breath).toBeGreaterThanOrEqual(0);
  expect(chipDbg.breath).toBeLessThanOrEqual(1);

  await fake.state({ governor: 3, flags: allowed, progress: 0.5, msToReturn: 0 });
  await expect(chip).toHaveText("Returning");
  await expect(chip).toHaveAttribute("data-state", "returning");

  await fake.state({ governor: 0, flags: allowed, progress: 0 });
  await expect(chip).toHaveText("Camera");
});

test("pinned wins during RETURNING too (keep it)", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  await fake.state({ governor: 3, flags: { ...allowed, pinned: true }, progress: 0.4 });
  await expect(page.locator("#chip")).toHaveText("KEEP WHITEBOARD");
});

test("bit3 clear: Ink source is <native|mirror|web> on the Mac, tap explains", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const chip = page.locator("#chip");
  await fake.state({ governor: 0, flags: { ...allowed, activeSource: false }, inkSource: 1 });
  await expect(chip).toHaveText("Ink source is Daylight Ink on the Mac");
  await expect(chip).toHaveAttribute("data-state", "inactive");
  await fake.state({ governor: 0, flags: { ...allowed, activeSource: false }, inkSource: 2 });
  await expect(chip).toHaveText("Ink source is mirror on the Mac");
  await fake.state({ governor: 2, flags: { ...allowed, activeSource: false }, inkSource: 0 });
  await expect(chip).toHaveText("Ink source is web on the Mac");
  await chip.click();
  const card = page.locator("#card");
  await expect(card).toBeVisible();
  await expect(card).toContainText("Ink source is web on the Mac");
  await expect(card).toContainText("Ink source > Web");
  await page.waitForTimeout(200);
  expect((await fake.framesNamed("TOGGLE_PIN")).length).toBe(0);
  await fake.state({ governor: 2, flags: allowed });
  await expect(chip).toHaveText("LIVE");
});

test("bit2 clear in STATE shows Look at your Mac", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  await fake.state({ governor: 0, flags: { allowed: false, activeSource: false } });
  await expect(page.locator("#chip")).toHaveText("Look at your Mac");
  await expect(page.locator("#chip")).toHaveAttribute("data-state", "pending");
});

test("tap sends TOGGLE_PIN -1; long press 600 ms sends AUTO_ENGAGE_RETURN", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  await fake.state({ governor: 2, flags: allowed, msToReturn: 60000 });
  const chip = page.locator("#chip");
  await expect(chip).toHaveText("LIVE");
  await chip.tap();
  const pin = (await waitForFrames(fake, "TOGGLE_PIN"))[0]!;
  expect(pin.value).toBe(-1);
  expect(pin.payloadLen).toBe(9);

  const box = (await chip.boundingBox())!;
  const cx = box.x + box.width / 2;
  const cy = box.y + box.height / 2;
  await page.mouse.move(cx, cy);
  await page.mouse.down();
  await page.waitForTimeout(750);
  await page.mouse.up();
  const ret = (await waitForFrames(fake, "AUTO_ENGAGE_RETURN"))[0]!;
  expect(ret.payloadLen).toBe(8);
  // The long press did not also count as a tap.
  await page.waitForTimeout(200);
  expect((await fake.framesNamed("TOGGLE_PIN")).length).toBe(1);
  const dbg = await debugValue<{ taps: number; longPresses: number }>(page, "chip");
  expect(dbg.taps).toBe(1);
  expect(dbg.longPresses).toBe(1);
});

test("a short press under 600 ms is a tap, not a return", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  await fake.state({ governor: 2, flags: allowed });
  const chip = page.locator("#chip");
  const box = (await chip.boundingBox())!;
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.waitForTimeout(300);
  await page.mouse.up();
  await waitForFrames(fake, "TOGGLE_PIN");
  await page.waitForTimeout(500);
  expect((await fake.framesNamed("AUTO_ENGAGE_RETURN")).length).toBe(0);
});

test("during the pre-warning a tap is keep it (TOGGLE_PIN -1) and the chip has an amber dot", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  await fake.state({ governor: 2, flags: { ...allowed, preWarning: true }, msToReturn: 3000 });
  const chip = page.locator("#chip");
  await expect(chip).toHaveAttribute("data-state", "prewarn");
  await expect(chip.locator(".dot")).toBeVisible();
  await chip.tap();
  expect((await waitForFrames(fake, "TOGGLE_PIN"))[0]!.value).toBe(-1);
});

test("undo and redo buttons follow the depths in STATE", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const undo = page.locator("#undo");
  const redo = page.locator("#redo");
  await expect(undo).toBeDisabled();
  await expect(redo).toBeDisabled();
  await fake.state({ governor: 2, flags: allowed, undoDepth: 3, redoDepth: 0 });
  await expect(undo).toBeEnabled();
  await expect(redo).toBeDisabled();
  await fake.state({ governor: 2, flags: allowed, undoDepth: 12, redoDepth: 2 });
  await expect(undo).toBeEnabled();
  await expect(redo).toBeEnabled();
  await fake.state({ governor: 0, flags: allowed, undoDepth: 0, redoDepth: 0 });
  await expect(undo).toBeDisabled();
  await expect(redo).toBeDisabled();
});

test("the golden STATE vectors drive the chip", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const chip = page.locator("#chip");
  // state_live_pinned: LIVE, flags 0x0D (pinned, allowed, active), native.
  await fake.state({ governor: 2, flags: 0x0d, inkSource: 1, progress: 1, undoDepth: 3, strokeCount: 3 });
  await expect(chip).toHaveText("KEEP WHITEBOARD");
  // state_returning_prewarn: RETURNING, flags 0x36 (pre_warning, allowed, camera, sink), 4200 ms. bit3 clear -> not the active source.
  await fake.state({ governor: 3, flags: 0x36, inkSource: 0, progress: 0.5, msToReturn: 4200, pageIndex: 1, strokeCount: 12, undoDepth: 12, redoDepth: 2 });
  await expect(chip).toHaveText("Ink source is web on the Mac");
  // state_passthrough_idle: PASSTHROUGH, flags 0xB4, mirror, bit3 clear.
  await fake.state({ governor: 0, flags: 0xb4, inkSource: 2 });
  await expect(chip).toHaveText("Ink source is mirror on the Mac");
});

test("a STATE older than our COMMIT does not hide the stroke we just drew; a Mac-side Clear still lands", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const box = await paperBox(page);
  await penStroke(page, [{ ...toPage(box, 100, 500), p: 0.5 }, { ...toPage(box, 300, 500), p: 0.5 }, { ...toPage(box, 500, 500), p: 0.5 }]);
  await waitForFrames(fake, "STROKE_COMMIT");
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(1);
  expect(await inkAlphaAt(page, 300, 500)).toBeGreaterThan(0);
  // The Mac's periodic STATE generated before it processed the COMMIT: depths 0 / 0.
  await fake.state({ governor: 2, flags: allowed, undoDepth: 0, redoDepth: 0, strokeCount: 0 });
  await page.waitForTimeout(150);
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(1);
  expect(await inkAlphaAt(page, 300, 500)).toBeGreaterThan(0);
  expect((await debugValue<{ staleStates: number }>(page, "ink")).staleStates).toBe(1);
  // The STATE that carries the commit.
  await fake.state({ governor: 2, flags: allowed, undoDepth: 1, redoDepth: 0, strokeCount: 1 });
  await page.waitForTimeout(150);
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(1);
  // From here the depths rule as before: an undo hides it, a redo brings it back.
  await fake.state({ governor: 2, flags: allowed, undoDepth: 0, redoDepth: 1 });
  await expect.poll(() => debugValue<number>(page, "visibleStrokes")).toBe(0);
  await fake.state({ governor: 2, flags: allowed, undoDepth: 1, redoDepth: 0 });
  await expect.poll(() => debugValue<number>(page, "visibleStrokes")).toBe(1);

  // A Mac-side Clear while a COMMIT is in flight: the total stops growing, so the third stale STATE applies.
  await penStroke(page, [{ ...toPage(box, 100, 700), p: 0.5 }, { ...toPage(box, 300, 700), p: 0.5 }]);
  await waitForFrames(fake, "STROKE_COMMIT", 2);
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(2);
  await fake.state({ governor: 0, flags: allowed, undoDepth: 0, redoDepth: 0, strokeCount: 0 });
  await fake.state({ governor: 0, flags: allowed, undoDepth: 0, redoDepth: 0, strokeCount: 0 });
  await page.waitForTimeout(150);
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(2);
  await fake.state({ governor: 0, flags: allowed, undoDepth: 0, redoDepth: 0, strokeCount: 0 });
  await expect.poll(() => debugValue<number>(page, "visibleStrokes")).toBe(0);
  expect(await inkAlphaAt(page, 300, 500)).toBe(0);
});

test("when the Mac holds strokes this page never saw (reload mid-session) the depths align on the newest stroke", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const box = await paperBox(page);
  await penStroke(page, [{ ...toPage(box, 100, 500), p: 0.5 }, { ...toPage(box, 300, 500), p: 0.5 }]);
  await waitForFrames(fake, "STROKE_COMMIT");
  // The Mac has two older strokes from before the reload plus ours: 3 / 0.
  await fake.state({ governor: 2, flags: allowed, undoDepth: 3, redoDepth: 0, strokeCount: 3 });
  await page.waitForTimeout(150);
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(1);
  // One undo on the Mac hides the newest stroke, which is the one we know.
  await fake.state({ governor: 2, flags: allowed, undoDepth: 2, redoDepth: 1, strokeCount: 2 });
  await expect.poll(() => debugValue<number>(page, "visibleStrokes")).toBe(0);
  expect(await inkAlphaAt(page, 200, 500)).toBe(0);
  // Redo brings it back; the local list kept it as its redo tail.
  await fake.state({ governor: 2, flags: allowed, undoDepth: 3, redoDepth: 0, strokeCount: 3 });
  await expect.poll(() => debugValue<number>(page, "visibleStrokes")).toBe(1);
  expect(await inkAlphaAt(page, 200, 500)).toBeGreaterThan(0);
  // Two undos on the Mac: nothing of ours is left visible, nothing is forgotten.
  await fake.state({ governor: 2, flags: allowed, undoDepth: 1, redoDepth: 2, strokeCount: 1 });
  await expect.poll(() => debugValue<number>(page, "visibleStrokes")).toBe(0);
  await fake.state({ governor: 2, flags: allowed, undoDepth: 3, redoDepth: 0, strokeCount: 3 });
  await expect.poll(() => debugValue<number>(page, "visibleStrokes")).toBe(1);
});

test("the eraser only reaches visible strokes and keeps the redo tail", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const box = await paperBox(page);
  await penStroke(page, [{ ...toPage(box, 100, 400), p: 0.5 }, { ...toPage(box, 500, 400), p: 0.5 }]);   // A
  await penStroke(page, [{ ...toPage(box, 100, 800), p: 0.5 }, { ...toPage(box, 500, 800), p: 0.5 }]);   // B
  const starts = await waitForFrames(fake, "STROKE_START", 2);
  await waitForFrames(fake, "STROKE_COMMIT", 2);
  await fake.state({ governor: 2, flags: allowed, undoDepth: 2, redoDepth: 0 });
  await fake.state({ governor: 2, flags: allowed, undoDepth: 1, redoDepth: 1 });   // B undone
  await expect.poll(() => debugValue<number>(page, "visibleStrokes")).toBe(1);
  await page.locator("#tool-eraser").click();
  // Rub across where B was: nothing to erase there (it is in the redo tail), the frame carries no ids.
  await penStroke(page, [{ ...toPage(box, 300, 700), p: 0.5 }, { ...toPage(box, 300, 900), p: 0.5 }]);
  await waitForFrames(fake, "ERASE_STROKES", 2);
  await page.waitForTimeout(100);
  expect((await fake.framesNamed("ERASE_STROKES")).every((e) => (e.ids as string[]).length === 0)).toBe(true);
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(1);
  // Rub across A: its id goes out, the local list drops it and still carries B as the redo tail.
  await fake.reset();
  await penStroke(page, [{ ...toPage(box, 300, 300), p: 0.5 }, { ...toPage(box, 300, 500), p: 0.5 }]);
  const erases = await waitForFrames(fake, "ERASE_STROKES");
  const withIds = erases.filter((e) => (e.ids as string[]).length > 0);
  expect(withIds.length).toBe(1);
  expect(withIds[0]!.ids).toEqual([starts[0]!.strokeId]);
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(0);
  // The Mac redoes B: the page still knows it.
  await fake.state({ governor: 2, flags: allowed, undoDepth: 1, redoDepth: 0 });
  await expect.poll(() => debugValue<number>(page, "visibleStrokes")).toBe(1);
  expect(await inkAlphaAt(page, 300, 800)).toBeGreaterThan(0);
  expect(await inkAlphaAt(page, 300, 400)).toBe(0);
});
