// Shared Playwright helpers: pen input with pressure through the Chrome DevTools Protocol (Chromium
// only; research-web-server section 4), finger touches, the fake Mac's control surface and the debug
// surface the page exposes at window.__daylight.
import { expect, type APIRequestContext, type Page } from "@playwright/test";

export interface PenPoint {
  x: number;
  y: number;
  p: number;
}

async function cdp(page: Page) {
  return page.context().newCDPSession(page);
}

/** Hover in, press with `pts[0].p`, move through the rest, release. */
export async function penStroke(page: Page, pts: PenPoint[], opts: { release?: boolean; hoverFirst?: boolean } = {}): Promise<void> {
  const s = await cdp(page);
  const first = pts[0]!;
  if (opts.hoverFirst !== false) {
    await s.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: first.x, y: first.y, pointerType: "pen", buttons: 0, force: 0 });
  }
  await s.send("Input.dispatchMouseEvent", { type: "mousePressed", x: first.x, y: first.y, button: "left", buttons: 1, clickCount: 1, pointerType: "pen", force: first.p });
  for (const q of pts.slice(1)) {
    await s.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: q.x, y: q.y, button: "left", buttons: 1, pointerType: "pen", force: q.p });
  }
  if (opts.release !== false) {
    const last = pts[pts.length - 1]!;
    await s.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: last.x, y: last.y, button: "left", buttons: 0, clickCount: 1, pointerType: "pen", force: 0 });
  }
  await s.detach();
}

/** More pen samples while pressed (for strokes started with release: false). */
export async function penMove(page: Page, pts: PenPoint[]): Promise<void> {
  const s = await cdp(page);
  for (const q of pts) {
    await s.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: q.x, y: q.y, button: "left", buttons: 1, pointerType: "pen", force: q.p });
  }
  await s.detach();
}

/** The alpha of the ink layer at a canvas-unit coordinate (0 = nothing drawn there). */
export async function inkAlphaAt(page: Page, cx: number, cy: number, layer = "ink"): Promise<number> {
  return page.evaluate(([x, y, cls]) => {
    const c = document.querySelector<HTMLCanvasElement>(`#paper .${cls}`)!;
    const ctx = c.getContext("2d")!;
    const px = Math.round(((x as number) / 1200) * c.width);
    const py = Math.round(((y as number) / 1600) * c.height);
    return ctx.getImageData(px, py, 1, 1).data[3]!;
  }, [cx, cy, layer] as const);
}

/** Pen release at a point (for strokes started with release: false). */
export async function penRelease(page: Page, x: number, y: number): Promise<void> {
  const s = await cdp(page);
  await s.send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", buttons: 0, clickCount: 1, pointerType: "pen", force: 0 });
  await s.detach();
}

/** Pen hovering (buttons 0, pressure 0) across the given points. */
export async function penHover(page: Page, pts: { x: number; y: number }[]): Promise<void> {
  const s = await cdp(page);
  for (const q of pts) await s.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: q.x, y: q.y, pointerType: "pen", buttons: 0, force: 0 });
  await s.detach();
}

/** A finger (or palm) tap. The whiteboard must ignore it. */
export async function fingerTap(page: Page, x: number, y: number): Promise<void> {
  const s = await cdp(page);
  await s.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x, y, force: 0.5, id: 1 }] });
  await s.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
  await s.detach();
}

/** A finger drag (palm sliding) across the canvas. */
export async function fingerDrag(page: Page, pts: { x: number; y: number }[]): Promise<void> {
  const s = await cdp(page);
  const first = pts[0]!;
  await s.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: first.x, y: first.y, force: 0.5, id: 1 }] });
  for (const q of pts.slice(1)) await s.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x: q.x, y: q.y, force: 0.5, id: 1 }] });
  await s.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
  await s.detach();
}

/** Pen press and release with pressure 0 at the same spot: a side-button press in the air on the DC-1. */
export async function penZeroPressureTap(page: Page, x: number, y: number): Promise<void> {
  const s = await cdp(page);
  await s.send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y, pointerType: "pen", buttons: 0, force: 0 });
  await s.send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", buttons: 1, clickCount: 1, pointerType: "pen", force: 0 });
  await s.send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", buttons: 0, clickCount: 1, pointerType: "pen", force: 0 });
  await s.detach();
}

/** Dispatches a synthetic pointercancel for the pen pointer the page saw last (CDP has no cancel for mice or pens). */
export async function penCancel(page: Page): Promise<void> {
  await page.evaluate(() => {
    const w = window as unknown as { __lastPenPointerId?: number };
    const target = document.querySelector<HTMLCanvasElement>("#paper .wet");
    if (!target) throw new Error("no wet layer");
    target.dispatchEvent(new PointerEvent("pointercancel", { pointerId: w.__lastPenPointerId ?? 1, pointerType: "pen", bubbles: true, cancelable: false }));
  });
}

/** Installs the pointer id recorder penCancel needs. Call after goto. */
export async function recordPenPointerId(page: Page): Promise<void> {
  await page.evaluate(() => {
    const w = window as unknown as { __lastPenPointerId?: number };
    document.getElementById("paper")?.addEventListener("pointerdown", (e) => { if ((e as PointerEvent).pointerType === "pen") w.__lastPenPointerId = (e as PointerEvent).pointerId; }, true);
  });
}

export interface FakeFrame {
  conn: number;
  t: number;
  opcode?: number;
  name: string;
  payloadLen?: number;
  len?: number;
  hex?: string;
  error?: string;
  [key: string]: unknown;
}

/** The fake Mac's control surface. */
export class FakeMac {
  constructor(private readonly request: APIRequestContext, readonly base = "http://127.0.0.1:4173") {}

  async reset(): Promise<void> {
    expect((await this.request.post(`${this.base}/__reset`)).ok()).toBeTruthy();
  }

  async scenario(s: Record<string, unknown>): Promise<void> {
    expect((await this.request.post(`${this.base}/__scenario`, { data: s })).ok()).toBeTruthy();
  }

  async frames(): Promise<FakeFrame[]> {
    const res = await this.request.get(`${this.base}/__frames`);
    expect(res.ok()).toBeTruthy();
    return (await res.json()) as FakeFrame[];
  }

  async framesNamed(name: string): Promise<FakeFrame[]> {
    return (await this.frames()).filter((f) => f.name === name);
  }

  async dials(): Promise<number[]> {
    return (await (await this.request.get(`${this.base}/__dials`)).json()) as number[];
  }

  async openClients(): Promise<number> {
    return ((await (await this.request.get(`${this.base}/__clients`)).json()) as { open: number }).open;
  }

  async ack(status: number): Promise<void> {
    expect((await this.request.post(`${this.base}/__ack`, { data: { status } })).ok()).toBeTruthy();
  }

  async state(s: Record<string, unknown>): Promise<void> {
    expect((await this.request.post(`${this.base}/__state`, { data: s })).ok()).toBeTruthy();
  }

  async close(code = 1001): Promise<void> {
    expect((await this.request.post(`${this.base}/__close`, { data: { code } })).ok()).toBeTruthy();
  }
}

/** Opens the page, dismisses the Start overlay and waits for the connection phase. */
export async function openWhiteboard(page: Page, opts: { waitFor?: string; start?: boolean; query?: string } = {}): Promise<void> {
  await page.goto(`/${opts.query ?? ""}`);
  if (opts.start !== false) {
    await page.locator("#start").click();
    await expect(page.locator("#start")).toBeHidden();
  }
  const phase = opts.waitFor ?? "live";
  await expect.poll(() => debugValue<string>(page, "phase"), { timeout: 10_000 }).toBe(phase);
}

export async function debugValue<T>(page: Page, key: string): Promise<T> {
  return page.evaluate((k) => {
    const d = (window as unknown as { __daylight: Record<string, unknown> }).__daylight;
    const v = d[k];
    return JSON.parse(JSON.stringify(v ?? null)) as unknown;
  }, key) as Promise<T>;
}

export async function paperBox(page: Page): Promise<{ x: number; y: number; width: number; height: number }> {
  const box = await page.locator("#paper").boundingBox();
  if (!box) throw new Error("paper not visible");
  return box;
}

/** CSS pixel on the page for a canvas-unit coordinate. */
export function toPage(box: { x: number; y: number; width: number; height: number }, cx: number, cy: number): { x: number; y: number } {
  return { x: box.x + (cx * box.width) / 1200, y: box.y + (cy * box.height) / 1600 };
}

export async function waitForFrames(fake: FakeMac, name: string, count = 1, timeout = 5000): Promise<FakeFrame[]> {
  let found: FakeFrame[] = [];
  await expect.poll(async () => { found = await fake.framesNamed(name); return found.length; }, { timeout }).toBeGreaterThanOrEqual(count);
  return found;
}
