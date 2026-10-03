// The page: Start overlay, tools, toolbar actions and the opcodes they produce at the fake Mac
// (folds the M0 smoke test in). SPEC 7 (Pin, Clear, New page) and PROTOCOL 6.3 to 6.11.
import { test, expect } from "@playwright/test";
import { FakeMac, debugValue, fingerTap, openWhiteboard, paperBox, penStroke, toPage, waitForFrames } from "./pen.js";

test.beforeEach(async ({ request }) => {
  await new FakeMac(request).reset();
});

test("page loads with the Start overlay; the tap hides it and requests fullscreen", async ({ page }) => {
  await page.goto("/");
  await expect(page).toHaveTitle("Daylight Whiteboard");
  const start = page.locator("#start");
  await expect(start).toBeVisible();
  await expect(start).toContainText("Tap to start");
  await start.click();
  await expect(start).toBeHidden();
  await expect.poll(() => debugValue<{ fullscreenRequested: boolean } | null>(page, "start")).not.toBeNull();
  const r = await debugValue<{ fullscreenRequested: boolean; wakeLockRequested: boolean }>(page, "start");
  expect(r.fullscreenRequested).toBe(true);
  await expect(page.locator("#paper")).toBeVisible();
  await expect(page.locator("#chip")).toBeVisible();
});

test("handshake name is web;<uuid>;<label> with a 3:4 canvas, and the client id survives a reload", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const hs = (await waitForFrames(fake, "HANDSHAKE"))[0]!;
  expect(hs.canvasWidth).toBe(1200);
  expect(hs.canvasHeight).toBe(1600);
  expect(hs.dpi).toBe(200);
  const parts = (hs.clientName as string).split(";");
  expect(parts.length).toBe(3);
  expect(parts[0]).toBe("web");
  expect(parts[1]).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  expect(parts[2]).toBe("Chrome on Daylight");
  await fake.reset();
  await page.reload();
  const again = (await waitForFrames(fake, "HANDSHAKE"))[0]!;
  expect((again.clientName as string).split(";")[1]).toBe(parts[1]);
});

test("fingers never draw; pen draws; the smoke counters agree", async ({ page }) => {
  await openWhiteboard(page);
  const box = await paperBox(page);
  await penStroke(page, [{ ...toPage(box, 100, 100), p: 0.3 }, { ...toPage(box, 160, 130), p: 0.6 }, { ...toPage(box, 220, 170), p: 0.9 }]);
  await fingerTap(page, box.x + 600, box.y + 800);
  await page.waitForTimeout(100);
  const ink = await debugValue<{ strokes: number; points: number; ignored: number }>(page, "ink");
  expect(ink.strokes).toBe(1);
  expect(ink.points).toBeGreaterThanOrEqual(3);
  expect(ink.ignored).toBe(1);
  expect(await debugValue<string>(page, "phase")).toBe("live");
});

test("highlighter: tool 1, Amber at 50 percent, width 12, drawn on the layer under the ink", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  await page.locator("#tool-highlighter").click();
  await expect(page.locator("#tool-highlighter")).toHaveAttribute("aria-pressed", "true");
  await expect(page.locator("#tool-pen")).toHaveAttribute("aria-pressed", "false");
  expect(await debugValue<string>(page, "tool")).toBe("highlighter");
  const box = await paperBox(page);
  await penStroke(page, [{ ...toPage(box, 100, 400), p: 0.5 }, { ...toPage(box, 400, 400), p: 0.5 }, { ...toPage(box, 700, 400), p: 0.5 }]);
  const start = (await waitForFrames(fake, "STROKE_START"))[0]!;
  expect(start.tool).toBe(1);
  expect(start.color).toBe(0x80d97706);
  expect(start.baseWidth as number).toBeCloseTo(12, 5);
  await waitForFrames(fake, "STROKE_COMMIT");
  // Layer order: highlight below ink below the wet layer.
  const order = await page.evaluate(() => [...document.querySelectorAll("#paper canvas")].map((c) => c.className));
  expect(order).toEqual(["layer highlight", "layer ink", "layer wet"]);
  // The highlight layer has amber pixels where the stroke went; the ink layer is still empty there.
  const px = await page.evaluate(() => {
    const read = (cls: string) => {
      const c = document.querySelector<HTMLCanvasElement>(`#paper .${cls}`)!;
      const ctx = c.getContext("2d")!;
      const x = Math.round((400 / 1200) * c.width);
      const y = Math.round((400 / 1600) * c.height);
      return [...ctx.getImageData(x, y, 1, 1).data];
    };
    return { highlight: read("highlight"), ink: read("ink") };
  });
  expect(px.highlight[3]).toBeGreaterThan(100);
  expect(px.highlight[0]).toBeGreaterThan(px.highlight[2]!);  // amber: red above blue
  expect(px.ink[3]).toBe(0);
});

test("eraser sends ERASE_STROKES with radius 12 and the ids it believes it erased", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const box = await paperBox(page);
  await penStroke(page, [{ ...toPage(box, 300, 600), p: 0.5 }, { ...toPage(box, 600, 600), p: 0.5 }, { ...toPage(box, 900, 600), p: 0.5 }]);
  const start = (await waitForFrames(fake, "STROKE_START"))[0]!;
  await waitForFrames(fake, "STROKE_COMMIT");
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(1);
  await page.locator("#tool-eraser").click();
  await penStroke(page, [{ ...toPage(box, 600, 500), p: 0.5 }, { ...toPage(box, 600, 600), p: 0.5 }, { ...toPage(box, 600, 700), p: 0.5 }]);
  const erases = await waitForFrames(fake, "ERASE_STROKES");
  await page.waitForTimeout(150);
  // One frame per sample (the press and two moves): pointerrawupdate and pointermove never both carry a sample.
  expect((await fake.framesNamed("ERASE_STROKES")).length).toBe(3);
  for (const e of erases) expect(e.radius as number).toBeCloseTo(12, 5);
  const withIds = erases.filter((e) => (e.ids as string[]).length > 0);
  expect(withIds.length).toBe(1);
  expect((withIds[0]!.ids as string[])[0]).toBe(start.strokeId);
  expect(withIds[0]!.payloadLen).toBe(22 + 16);
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(0);
  // The eraser never opens a stroke on the wire.
  expect((await fake.framesNamed("STROKE_START")).length).toBe(1);
});

test("undo and redo follow STATE depths and send UNDO / REDO for the current page", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const undo = page.locator("#undo");
  const redo = page.locator("#redo");
  await expect(undo).toBeDisabled();
  await expect(redo).toBeDisabled();
  await fake.state({ governor: 2, undoDepth: 2, redoDepth: 0, strokeCount: 2 });
  await expect(undo).toBeEnabled();
  await expect(redo).toBeDisabled();
  await undo.click();
  const u = (await waitForFrames(fake, "UNDO"))[0]!;
  expect(u.payloadLen).toBe(24);
  expect(u.pageId).toBe(await debugValue<string>(page, "pageId"));
  await fake.state({ governor: 2, undoDepth: 1, redoDepth: 1, strokeCount: 1 });
  await expect(redo).toBeEnabled();
  await redo.click();
  const r = (await waitForFrames(fake, "REDO"))[0]!;
  expect(r.pageId).toBe(u.pageId);
  await fake.state({ governor: 2, undoDepth: 0, redoDepth: 2 });
  await expect(undo).toBeDisabled();
  await expect(redo).toBeEnabled();
});

test("local undo and redo redraw from the Mac's depths without touching the local stack on tap", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const box = await paperBox(page);
  await penStroke(page, [{ ...toPage(box, 100, 200), p: 0.5 }, { ...toPage(box, 300, 200), p: 0.5 }]);
  await penStroke(page, [{ ...toPage(box, 100, 300), p: 0.5 }, { ...toPage(box, 300, 300), p: 0.5 }]);
  await waitForFrames(fake, "STROKE_COMMIT", 2);
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(2);
  await fake.state({ governor: 2, undoDepth: 2, redoDepth: 0 });
  await page.locator("#undo").click();
  await waitForFrames(fake, "UNDO");
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(2);   // nothing changes until STATE says so
  await fake.state({ governor: 2, undoDepth: 1, redoDepth: 1 });
  await expect.poll(() => debugValue<number>(page, "visibleStrokes")).toBe(1);
  await fake.state({ governor: 2, undoDepth: 2, redoDepth: 0 });
  await expect.poll(() => debugValue<number>(page, "visibleStrokes")).toBe(2);
});

test("New page sends PAGE_CHANGE 1200x1600 with the next index and a fresh page id", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const before = await debugValue<string>(page, "pageId");
  await page.locator("#new-page").click();
  const pc = (await waitForFrames(fake, "PAGE_CHANGE"))[0]!;
  expect(pc.width).toBe(1200);
  expect(pc.height).toBe(1600);
  expect(pc.pageIndex).toBe(1);
  expect(pc.payloadLen).toBe(28);
  const after = await debugValue<string>(page, "pageId");
  expect(after).not.toBe(before);
  expect(pc.pageId).toBe(after);
  expect(await debugValue<number>(page, "pageIndex")).toBe(1);
});

test("Clear sends the 24-byte CLEAR_CANVAS for the current page and blanks the local canvas", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const box = await paperBox(page);
  await penStroke(page, [{ ...toPage(box, 100, 200), p: 0.5 }, { ...toPage(box, 300, 200), p: 0.5 }]);
  await waitForFrames(fake, "STROKE_COMMIT");
  await page.locator("#clear").click();
  const c = (await waitForFrames(fake, "CLEAR_CANVAS"))[0]!;
  expect(c.payloadLen).toBe(24);
  expect(c.pageId).toBe(await debugValue<string>(page, "pageId"));
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(0);
});

test("the ? button opens the card with Add to Home screen and the Daylight Ink link", async ({ page }) => {
  await openWhiteboard(page);
  const card = page.locator("#card");
  await expect(card).toBeHidden();
  await page.locator("#info").click();
  await expect(card).toBeVisible();
  await expect(card).toContainText("Add to Home screen");
  await expect(card.locator("#apk-link")).toHaveAttribute("href", "./daylight-ink.apk");
  await expect(card).toContainText("This tablet");
  await page.locator("#card-close").click();
  await expect(card).toBeHidden();
});

test("the built dist has index.html, the manifest and hashed assets", async ({ request }) => {
  const index = await request.get("/");
  expect(index.ok()).toBeTruthy();
  const html = await index.text();
  expect(html).toContain('rel="manifest"');
  const asset = /assets\/index-[A-Za-z0-9_-]+\.js/.exec(html);
  expect(asset).toBeTruthy();
  const js = await request.get(`/${asset![0]}`);
  expect(js.ok()).toBeTruthy();
  expect(js.headers()["cache-control"]).toContain("immutable");
  expect((await request.get("/icons/icon-192.png")).headers()["content-type"]).toBe("image/png");
});
