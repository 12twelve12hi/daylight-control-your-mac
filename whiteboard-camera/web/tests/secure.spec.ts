// SPEC 16 D6: touch-action none in CSS; binaryType arraybuffer; the manifest is served as
// application/manifest+json; the page requests fullscreen and the wake lock on the Start tap when
// available and shows the flag string from /api/info on a non-secure origin.
import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { FakeMac, debugValue, openWhiteboard } from "./pen.js";

test.beforeEach(async ({ request }) => {
  await new FakeMac(request).reset();
});

test("touch-action: none is set in CSS on the paper and every layer", async ({ page }) => {
  const css = readFileSync(resolve("src/styles.css"), "utf8");
  expect(css).toMatch(/touch-action:\s*none/);
  await openWhiteboard(page);
  const ta = await page.evaluate(() => ({
    paper: getComputedStyle(document.getElementById("paper")!).touchAction,
    wet: getComputedStyle(document.querySelector("#paper .wet")!).touchAction,
    chip: getComputedStyle(document.getElementById("chip")!).touchAction,
  }));
  expect(ta.paper).toBe("none");
  expect(ta.wet).toBe("none");
  expect(ta.chip).toBe("none");
});

test("the socket uses binaryType arraybuffer and offers the solstream.v1 subprotocol", async ({ page }) => {
  await page.addInitScript(() => {
    const w = window as unknown as { __ws: { protocols: unknown; binaryTypeAtFirstSend: string | null; url: string }[] };
    w.__ws = [];
    const Orig = window.WebSocket;
    class Spy extends Orig {
      private rec: { protocols: unknown; binaryTypeAtFirstSend: string | null; url: string };
      constructor(url: string | URL, protocols?: string | string[]) {
        super(url, protocols);
        this.rec = { protocols, binaryTypeAtFirstSend: null, url: String(url) };
        w.__ws.push(this.rec);
      }
      override send(data: string | ArrayBufferLike | Blob | ArrayBufferView): void {
        if (this.rec.binaryTypeAtFirstSend === null) this.rec.binaryTypeAtFirstSend = this.binaryType;
        super.send(data);
      }
    }
    window.WebSocket = Spy as unknown as typeof WebSocket;
  });
  await openWhiteboard(page);
  const recs = await page.evaluate(() => (window as unknown as { __ws: unknown[] }).__ws);
  expect(recs.length).toBeGreaterThanOrEqual(1);
  const r = recs[0] as { protocols: string[]; binaryTypeAtFirstSend: string; url: string };
  expect(r.protocols).toEqual(["solstream.v1"]);
  expect(r.binaryTypeAtFirstSend).toBe("arraybuffer");
  expect(r.url).toBe("ws://127.0.0.1:4173/ink");
});

test("the manifest is served as application/manifest+json with fullscreen and portrait", async ({ request }) => {
  const res = await request.get("/manifest.webmanifest");
  expect(res.ok()).toBeTruthy();
  expect(res.headers()["content-type"]).toBe("application/manifest+json");
  const m = (await res.json()) as { display: string; orientation: string; icons: { src: string }[]; name: string };
  expect(m.display).toBe("fullscreen");
  expect(m.orientation).toBe("portrait");
  expect(m.name).toBe("Daylight Whiteboard");
  expect(m.icons.length).toBe(3);
  for (const icon of m.icons) expect((await request.get(`/${icon.src.replace(/^\.\//, "")}`)).ok()).toBeTruthy();
});

test("on a secure origin the Start tap requests fullscreen and the wake lock; the flag row is absent", async ({ page }) => {
  await page.addInitScript(() => {
    const w = window as unknown as { __fs: number; __wl: number };
    w.__fs = 0;
    w.__wl = 0;
    const origFs = Element.prototype.requestFullscreen;
    Element.prototype.requestFullscreen = function (this: Element, o?: FullscreenOptions) {
      w.__fs++;
      (w as unknown as { __fsOpts: unknown }).__fsOpts = o;
      return origFs ? origFs.call(this, o).catch(() => undefined) : Promise.resolve();
    };
    const nav = navigator as unknown as { wakeLock?: { request: (t: string) => Promise<unknown> } };
    const wl = nav.wakeLock;
    if (wl) {
      const origReq = wl.request.bind(wl);
      wl.request = (t: string) => { w.__wl++; return origReq(t).catch(() => ({ release: () => Promise.resolve() })); };
    }
  });
  await openWhiteboard(page);
  const caps = await debugValue<{ secureContext: boolean; wakeLock: boolean; fullscreen: boolean }>(page, "caps");
  expect(caps.secureContext).toBe(true);
  expect(caps.fullscreen).toBe(true);
  const counts = await page.evaluate(() => {
    const w = window as unknown as { __fs: number; __wl: number; __fsOpts: { navigationUI?: string } };
    return { fs: w.__fs, wl: w.__wl, nav: w.__fsOpts?.navigationUI };
  });
  expect(counts.fs).toBe(1);
  expect(counts.nav).toBe("hide");
  if (caps.wakeLock) expect(counts.wl).toBe(1);
  await expect.poll(() => debugValue<{ fullscreenRequested: boolean; wakeLockRequested: boolean } | null>(page, "start")).not.toBeNull();
  const r = await debugValue<{ fullscreenRequested: boolean; wakeLockRequested: boolean }>(page, "start");
  expect(r.fullscreenRequested).toBe(true);
  expect(r.wakeLockRequested).toBe(caps.wakeLock);
  await page.locator("#info").click();
  await expect(page.locator("#card")).not.toContainText("unsafely-treat-insecure-origin-as-secure");
});

test("on a non-secure origin the card shows the exact chrome://flags string and the origin from /api/info", async ({ page }) => {
  await page.addInitScript(() => {
    Object.defineProperty(window, "isSecureContext", { value: false, configurable: true });
    Object.defineProperty(navigator, "wakeLock", { value: undefined, configurable: true });
    const proto = PointerEvent.prototype as unknown as Record<string, unknown>;
    delete proto.getCoalescedEvents;
  });
  await openWhiteboard(page);
  const caps = await debugValue<{ secureContext: boolean; wakeLock: boolean; coalescedEvents: boolean }>(page, "caps");
  expect(caps.secureContext).toBe(false);
  expect(caps.wakeLock).toBe(false);
  expect(caps.coalescedEvents).toBe(false);
  await expect.poll(() => debugValue<{ app: string } | null>(page, "info")).not.toBeNull();
  await page.locator("#info").click();
  const card = page.locator("#card");
  await expect(card.locator("#flag-url")).toHaveText("chrome://flags/#unsafely-treat-insecure-origin-as-secure");
  await expect(card.locator("#flag-origin")).toHaveText("http://127.0.0.1:4173");
  await expect(card).toContainText("Better ink and the screen stays awake over Wi-Fi");
  const r = await debugValue<{ fullscreenRequested: boolean; wakeLockRequested: boolean }>(page, "start");
  expect(r.fullscreenRequested).toBe(true);   // the Fullscreen API still works without a secure context
  expect(r.wakeLockRequested).toBe(false);
  // Everything else works: the connection is live and the chip reads Camera.
  await expect(page.locator("#chip")).toHaveText("Camera");
});

test("/api/info is read: the card shows the Mac's build and ink source", async ({ page }) => {
  await openWhiteboard(page);
  await expect.poll(() => debugValue<{ app: string; inkSource: string } | null>(page, "info")).not.toBeNull();
  const info = await debugValue<{ app: string; inkSource: string; pillStripHeight: number }>(page, "info");
  expect(info.app).toBe("daylight");
  expect(info.pillStripHeight).toBe(96);
  await page.locator("#info").click();
  await expect(page.locator("#facts")).toContainText("mac daylight");
});

test("the page logs its capabilities once for the owner's checklist", async ({ page }) => {
  const lines: string[] = [];
  page.on("console", (m) => lines.push(m.text()));
  await openWhiteboard(page);
  expect(lines.some((l) => l.startsWith("daylight-web caps {"))).toBe(true);
  const facts = await debugValue<string[]>(page, "consoleFacts");
  expect(facts.length).toBeGreaterThanOrEqual(1);
});
