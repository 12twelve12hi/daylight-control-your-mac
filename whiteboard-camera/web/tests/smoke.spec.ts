import { test, expect, type Page } from "@playwright/test";

/** One pen stroke with pressure through the Chrome DevTools Protocol (Chromium only). */
async function penStroke(page: Page, pts: { x: number; y: number; p: number }[]) {
  const cdp = await page.context().newCDPSession(page);
  const first = pts[0]!;
  await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: first.x, y: first.y, pointerType: "pen", buttons: 0, force: 0 });
  await cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", x: first.x, y: first.y, button: "left", buttons: 1, clickCount: 1, pointerType: "pen", force: first.p });
  for (const q of pts.slice(1)) {
    await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: q.x, y: q.y, button: "left", buttons: 1, pointerType: "pen", force: q.p });
  }
  const last = pts[pts.length - 1]!;
  await cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: last.x, y: last.y, button: "left", buttons: 0, clickCount: 1, pointerType: "pen", force: 0 });
  await cdp.detach();
}

/** A finger (palm) touching the canvas; the whiteboard must ignore it. */
async function fingerTap(page: Page, x: number, y: number) {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x, y, force: 0.5, id: 1 }] });
  await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
  await cdp.detach();
}

interface DebugState { strokes: number; points: number; ignored: number; connection: string; framesSent: number }

test("page loads, pen draws, fingers are ignored", async ({ page }) => {
  await page.goto("/");
  await expect(page).toHaveTitle("Daylight Whiteboard");
  const canvas = page.locator("#ink");
  await expect(canvas).toBeVisible();
  await expect(page.locator("#chip")).toContainText("Not connected");

  const box = (await canvas.boundingBox())!;
  await penStroke(page, [
    { x: box.x + 100, y: box.y + 100, p: 0.3 },
    { x: box.x + 160, y: box.y + 130, p: 0.6 },
    { x: box.x + 220, y: box.y + 170, p: 0.9 },
  ]);
  await fingerTap(page, box.x + 600, box.y + 800);
  await page.waitForTimeout(100);

  const state = await page.evaluate(() => (window as unknown as { __daylight: DebugState }).__daylight);
  expect(state.strokes).toBe(1);
  expect(state.points).toBeGreaterThanOrEqual(3);
  expect(state.ignored).toBe(1);
  expect(state.connection).toBe("disconnected");
  expect(state.framesSent).toBe(0);
});
