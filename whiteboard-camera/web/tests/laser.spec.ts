// LOOSE_ENDS F3: with the Laser tool selected, pen hover and contact send LASER_POINT (0x0030) in canvas units
// (hover 0.5, contact 1.0, decay 0.5 s) and never a stroke; nothing reaches the ink layer; Pen draws again after.
import { test, expect } from "@playwright/test";
import { FakeMac, debugValue, inkAlphaAt, openWhiteboard, paperBox, penHover, penMove, penRelease, penStroke, toPage, waitForFrames } from "./pen.js";

test.beforeEach(async ({ request }) => {
  await new FakeMac(request).reset();
});

test("Laser: hover and contact send LASER_POINT, no stroke, nothing drawn; Pen strokes again", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  await page.locator("#tool-laser").click();
  await expect(page.locator("#tool-laser")).toHaveAttribute("aria-pressed", "true");
  await expect(page.locator("#tool-laser")).toHaveText("Laser");
  await expect(page.locator("#tool-pen")).toHaveAttribute("aria-pressed", "false");

  const box = await paperBox(page);
  const hover = toPage(box, 300, 400);
  const a = toPage(box, 600, 800);
  const b = toPage(box, 660, 860);
  await penHover(page, [hover]);
  await page.waitForTimeout(100);
  await penStroke(page, [{ ...a, p: 0.6 }], { release: false, hoverFirst: false });
  await penMove(page, [{ ...b, p: 0.7 }]);
  await page.waitForTimeout(100);
  await penRelease(page, b.x, b.y);
  await page.waitForTimeout(150);

  const lasers = await waitForFrames(fake, "LASER_POINT", 2);
  for (const l of lasers) {
    expect(l.opcode).toBe(0x0030);
    expect(l.payloadLen).toBe(16);
    expect(l.decayS as number).toBeCloseTo(0.5, 5);
  }
  const hovered = lasers.find((l) => l.intensity === 0.5);
  expect(hovered).toBeTruthy();
  expect(Math.abs((hovered!.x as number) - 300)).toBeLessThan(1.5);
  expect(Math.abs((hovered!.y as number) - 400)).toBeLessThan(1.5);
  const touched = lasers.filter((l) => l.intensity === 1);
  expect(touched.length).toBeGreaterThanOrEqual(1);
  const last = touched[touched.length - 1]!;
  expect(Math.abs((last.x as number) - 660)).toBeLessThan(1.5);
  expect(Math.abs((last.y as number) - 860)).toBeLessThan(1.5);

  const frames = await fake.frames();
  expect(frames.filter((f) => f.name.startsWith("STROKE_") || f.name === "ERASE_STROKES" || f.name === "UNDO")).toEqual([]);
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(0);
  expect(await inkAlphaAt(page, 600, 800)).toBe(0);
  expect(await inkAlphaAt(page, 630, 830)).toBe(0);
  const stats = await debugValue<{ strokes: number; laserPoints: number }>(page, "ink");
  expect(stats.strokes).toBe(0);
  expect(stats.laserPoints).toBe(lasers.length);

  // Back to Pen: a stroke goes out as usual and no more laser points follow.
  await page.locator("#tool-pen").click();
  const before = lasers.length;
  const c = toPage(box, 100, 100);
  const d = toPage(box, 160, 140);
  await penStroke(page, [{ ...c, p: 0.5 }, { ...d, p: 0.5 }]);
  await waitForFrames(fake, "STROKE_COMMIT");
  expect((await fake.framesNamed("LASER_POINT")).length).toBe(before);
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(1);
});
