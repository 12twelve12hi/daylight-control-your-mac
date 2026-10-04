// "Send facts to Mac" in the "?" card (PROTOCOL 15): one POST /api/facts on the page's origin with the
// web key set, and the result line under the button for a current Mac (200) and an old one (404).
import { test, expect, type APIRequestContext } from "@playwright/test";
import { FakeMac, debugValue, openWhiteboard, paperBox, penStroke, toPage } from "./pen.js";

// PROTOCOL 15.1, typed from the document so the spec does not trust the page's own list.
const WEB_KEYS = [
  "chromeVersion", "userAgent", "devicePixelRatio", "viewport", "displayMode", "secureContext", "wakeLockSupported",
  "wakeLockState", "fullscreenState", "coalescedEvents", "rawUpdate", "predictedEvents", "firstPenPointerdown",
  "pressureMin", "pressureMax", "pressureSamples", "rttMs", "macBuild",
];

interface FactsRecord {
  contentType: string;
  status: number;
  body: { schema: string; source: string; clientId?: string; sentAt: string; facts: Record<string, unknown> } | null;
}

async function factsPosts(request: APIRequestContext): Promise<FactsRecord[]> {
  const res = await request.get("http://127.0.0.1:4173/__facts");
  expect(res.ok()).toBeTruthy();
  return (await res.json()) as FactsRecord[];
}

test.beforeEach(async ({ request }) => {
  await new FakeMac(request).reset();
});

test("Send facts to Mac posts the PROTOCOL 15 web facts as JSON and shows Sent to your Mac.", async ({ page, request }) => {
  await openWhiteboard(page);
  const box = await paperBox(page);
  await penStroke(page, [{ ...toPage(box, 100, 100), p: 0.3 }, { ...toPage(box, 160, 130), p: 0.6 }, { ...toPage(box, 220, 170), p: 0.9 }]);
  await page.locator("#info").click();
  const card = page.locator("#card");
  await expect(card).toBeVisible();
  // STATE re-renders the card while it is open; the button must still work after that.
  await new FakeMac(request).state({ undoDepth: 1 });
  await card.locator("#facts-send").click();
  await expect(card.locator("#facts-status")).toHaveText("Sent to your Mac.");
  expect((await debugValue<{ outcome: string; status: number }>(page, "facts")).status).toBe(200);

  const posts = await factsPosts(request);
  expect(posts.length).toBe(1);
  const post = posts[0]!;
  expect(post.contentType).toMatch(/^application\/json/);
  expect(post.status).toBe(200);
  const body = post.body!;
  expect(body.schema).toBe("daylight-tablet-facts/1");
  expect(body.source).toBe("web");
  expect(body.sentAt).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  expect(body.clientId).toMatch(/^[0-9a-f-]{36}$/);
  expect(Object.keys(body.facts).sort()).toEqual([...WEB_KEYS].sort());
  const f = body.facts;
  expect(f.chromeVersion).toMatch(/^\d+(\.\d+)*$/);
  expect(f.viewport).toBe("1200x1600");
  expect(f.pressureSamples as number).toBeGreaterThanOrEqual(3);
  expect(f.pressureMin as number).toBeGreaterThan(0);
  expect(f.pressureMax as number).toBeGreaterThanOrEqual(f.pressureMin as number);
  expect(f.firstPenPointerdown).toMatch(/^daylight-web first pen pointerdown /);
  expect(f.macBuild).toBe(0);
  expect(["held", "refused", "released", "not requested"]).toContain(f.wakeLockState);
  expect(["on", "refused", "not requested"]).toContain(f.fullscreenState);
  // The ink path is untouched: the stroke still reached the canvas once.
  expect((await debugValue<{ strokes: number }>(page, "ink")).strokes).toBe(1);
});

test("an old Mac without the route (404) shows the update line", async ({ page, request }) => {
  await new FakeMac(request).scenario({ factsStatus: 404 });
  await openWhiteboard(page);
  await page.locator("#info").click();
  await page.locator("#facts-send").click();
  await expect(page.locator("#facts-status")).toHaveText("Your Mac did not accept the facts (404). Update Daylight on your Mac.");
  const posts = await factsPosts(request);
  expect(posts.length).toBe(1);
  expect(posts[0]!.status).toBe(404);
  expect((await debugValue<{ outcome: string }>(page, "facts")).outcome).toBe("old-mac");
});

test("a second tap clears the previous result line while its POST is in flight (finder WF-1)", async ({ page, request }) => {
  await openWhiteboard(page);
  await page.locator("#info").click();
  await page.locator("#facts-send").click();
  await expect(page.locator("#facts-status")).toHaveText("Sent to your Mac.");
  // Hold the second POST; the first tap's "Sent to your Mac." must not stand for it.
  let release: () => void = () => {};
  const held = new Promise<void>((resolve) => { release = resolve; });
  await page.route("**/api/facts", async (route) => { await held; await route.continue(); });
  await page.locator("#facts-send").click();
  await expect(page.locator("#facts-send")).toBeDisabled();
  await expect(page.locator("#facts-status")).toHaveText("");
  release();
  await expect(page.locator("#facts-status")).toHaveText("Sent to your Mac.");
  expect((await factsPosts(request)).length).toBe(2);
});
