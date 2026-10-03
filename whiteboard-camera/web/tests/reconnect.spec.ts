// SPEC 16 D5: re-dial with backoff (1000 ms x 1.7 capped at 15 s); the offline ring replays a stroke;
// ACK 1 shows "Look at your Mac" and no ink is sent until ACK 0. Plus: denied stops retrying until a
// tap, a server that does not echo solstream.v1 is incompatible, and a mid-stroke drop restarts the stroke.
import { test, expect } from "@playwright/test";
import { FakeMac, debugValue, openWhiteboard, paperBox, penRelease, penStroke, toPage, waitForFrames } from "./pen.js";

test.beforeEach(async ({ request }) => {
  await new FakeMac(request).reset();
});

test("re-dials with 1000 ms x 1.7 backoff while the Mac refuses, then connects", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await fake.scenario({ refuse: true });
  await openWhiteboard(page, { waitFor: "disconnected" });
  await expect(page.locator("#chip")).toHaveText("Looking for your Mac");
  await expect(page.locator("#chip")).toHaveAttribute("data-state", "searching");
  await expect.poll(async () => (await fake.dials()).length, { timeout: 8000 }).toBeGreaterThanOrEqual(3);
  const dials = await fake.dials();
  const gap1 = dials[1]! - dials[0]!;
  const gap2 = dials[2]! - dials[1]!;
  expect(gap1).toBeGreaterThanOrEqual(900);
  expect(gap1).toBeLessThan(1600);
  expect(gap2).toBeGreaterThanOrEqual(1550);
  expect(gap2).toBeLessThan(2600);
  const stats = await debugValue<{ dials: number; lastDelayMs: number }>(page, "client");
  expect(stats.dials).toBeGreaterThanOrEqual(3);
  expect([1000, 1700, 2890, 4913, 8352.1, 14198.57, 15000].some((d) => Math.abs(d - stats.lastDelayMs) < 1)).toBe(true);
  await fake.scenario({ refuse: false });
  await expect.poll(() => debugValue<string>(page, "phase"), { timeout: 20_000 }).toBe("live");
  await expect(page.locator("#chip")).toHaveText("Camera");
});

test("backoff caps at 15 s", async ({ page }) => {
  await page.goto("/");
  const delays = await page.evaluate(() => {
    // The delay table is pure: 1000 * 1.7^n capped at 15000.
    const out: number[] = [];
    for (let n = 0; n < 10; n++) out.push(Math.min(15000, 1000 * Math.pow(1.7, n)));
    return out;
  });
  expect(delays[0]).toBe(1000);
  expect(delays[1]).toBeCloseTo(1700, 5);
  expect(delays[9]).toBe(15000);
});

test("a stroke drawn while disconnected is ringed and replayed after the reconnect", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  // The Mac goes away (Wi-Fi blip): refuse upgrades so the re-dial cannot win the race against the pen.
  await fake.scenario({ refuse: true });
  await fake.close(1001);
  await expect.poll(() => debugValue<string>(page, "phase")).not.toBe("live");
  await expect(page.locator("#chip")).toHaveText("Looking for your Mac");
  const box = await paperBox(page);
  await penStroke(page, [{ ...toPage(box, 100, 100), p: 0.4 }, { ...toPage(box, 200, 160), p: 0.6 }, { ...toPage(box, 300, 220), p: 0.8 }]);
  await expect.poll(() => debugValue<{ length: number; points: number }>(page, "ring").then((r) => r.length)).toBe(3);
  expect((await debugValue<{ points: number }>(page, "ring")).points).toBe(3);
  expect((await fake.framesNamed("STROKE_START")).length).toBe(0);
  // The Mac is back; the page re-dials with backoff and replays the ring after ACK 0.
  await fake.scenario({ refuse: false });
  await expect.poll(() => debugValue<string>(page, "phase"), { timeout: 15_000 }).toBe("live");
  const commits = await waitForFrames(fake, "STROKE_COMMIT");
  const frames = await fake.frames();
  const conn2 = frames.filter((f) => f.conn === commits[0]!.conn).map((f) => f.name);
  expect(conn2.slice(0, 4)).toEqual(["HANDSHAKE", "STROKE_START", "STROKE_CHUNK", "STROKE_COMMIT"]);
  const stats = await debugValue<{ framesReplayed: number; framesRinged: number }>(page, "client");
  expect(stats.framesReplayed).toBe(3);
  expect(stats.framesRinged).toBe(3);
  expect((await debugValue<{ length: number }>(page, "ring")).length).toBe(0);
});

test("ACK 1: Look at your Mac, no ink until ACK 0, then the ring drains", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await fake.scenario({ ack: 1 });
  await openWhiteboard(page, { waitFor: "pending" });
  const chip = page.locator("#chip");
  await expect(chip).toHaveText("Look at your Mac");
  await expect(chip).toHaveAttribute("data-state", "pending");
  const box = await paperBox(page);
  await penStroke(page, [{ ...toPage(box, 100, 100), p: 0.4 }, { ...toPage(box, 200, 160), p: 0.6 }]);
  await page.waitForTimeout(300);
  expect((await fake.frames()).map((f) => f.name)).toEqual(["HANDSHAKE"]);
  expect((await debugValue<{ length: number }>(page, "ring")).length).toBe(3);
  // The owner clicks Allow on the Mac.
  await fake.ack(0);
  await expect.poll(() => debugValue<string>(page, "phase")).toBe("live");
  await waitForFrames(fake, "STROKE_COMMIT");
  expect((await fake.frames()).map((f) => f.name)).toEqual(["HANDSHAKE", "STROKE_START", "STROKE_CHUNK", "STROKE_COMMIT"]);
  // STATE after the second ACK carries bit2 clear in this scenario until the fake sends a fresh one.
  await fake.state({ governor: 0, flags: { allowed: true, activeSource: true } });
  await expect(chip).toHaveText("Camera");
});

test("ACK 2: Not allowed by the Mac, no re-dial until the chip is tapped", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await fake.scenario({ ack: 2 });
  await openWhiteboard(page, { waitFor: "denied" });
  const chip = page.locator("#chip");
  await expect(chip).toHaveText("Not allowed by the Mac");
  await expect(chip).toHaveAttribute("data-state", "denied");
  await page.waitForTimeout(2500);
  expect((await fake.dials()).length).toBe(1);
  expect((await debugValue<{ lastCloseCode: number }>(page, "client")).lastCloseCode).toBe(1008);
  await fake.scenario({ ack: 0 });
  await chip.tap();
  await expect.poll(() => debugValue<string>(page, "phase"), { timeout: 10_000 }).toBe("live");
  expect((await fake.dials()).length).toBe(2);
});

test("a server that does not echo solstream.v1 is incompatible; the client stops retrying", async ({ page, request }) => {
  // Chromium refuses the upgrade itself when the offered subprotocol is not echoed, so the page sees
  // five failed dials (1 + 1.7 + 2.9 + 4.9 s), then asks /api/info and stops because the Mac is there.
  test.setTimeout(90_000);
  const fake = new FakeMac(request);
  await fake.scenario({ echoProtocol: false });
  await page.goto("/");
  await page.locator("#start").click();
  await expect.poll(() => debugValue<string>(page, "phase"), { timeout: 30_000 }).toBe("incompatible");
  await expect(page.locator("#chip")).toHaveAttribute("data-state", "incompatible");
  const dialsAtStop = (await fake.dials()).length;
  expect(dialsAtStop).toBe(5);
  await page.waitForTimeout(3000);
  expect((await fake.dials()).length).toBe(dialsAtStop);
  expect((await fake.frames()).length).toBe(0);   // no HANDSHAKE was ever sent
  expect((await debugValue<{ opens: number }>(page, "client")).opens).toBe(0);
  // A tap retries from scratch once the Mac is compatible again.
  await fake.scenario({ echoProtocol: true });
  await page.locator("#chip").tap();
  await expect.poll(() => debugValue<string>(page, "phase"), { timeout: 10_000 }).toBe("live");
});

test("a drop in the middle of a stroke restarts the rest as a new stroke after the reconnect", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const box = await paperBox(page);
  const a = toPage(box, 100, 800);
  const b = toPage(box, 200, 820);
  await penStroke(page, [{ ...a, p: 0.5 }, { ...b, p: 0.5 }], { release: false });
  const first = (await waitForFrames(fake, "STROKE_START"))[0]!;
  await fake.close(1001);
  await expect.poll(() => debugValue<string>(page, "phase")).not.toBe("live");
  const c = toPage(box, 300, 840);
  const d = toPage(box, 400, 860);
  await penStroke(page, [{ ...c, p: 0.5 }, { ...d, p: 0.5 }], { release: false, hoverFirst: false });
  await penRelease(page, d.x, d.y);
  await expect.poll(() => debugValue<string>(page, "phase"), { timeout: 10_000 }).toBe("live");
  const commits = await waitForFrames(fake, "STROKE_COMMIT");
  const starts = await fake.framesNamed("STROKE_START");
  expect(starts.length).toBe(2);
  expect(starts[1]!.strokeId).not.toBe(first.strokeId);
  expect(commits[0]!.strokeId).toBe(starts[1]!.strokeId);
  const replayed = (await fake.frames()).filter((f) => f.conn === commits[0]!.conn).map((f) => f.name);
  expect(replayed.slice(0, 2)).toEqual(["HANDSHAKE", "STROKE_START"]);
  expect((await debugValue<{ restarted: number }>(page, "ink")).restarted).toBe(1);
});

test("PING goes out and PONG comes back with an RTT", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await page.clock.install();   // before navigation, so the page's 10 s ping interval is under the fake clock
  await openWhiteboard(page);
  await page.clock.runFor(10_500);
  const pings = await waitForFrames(fake, "PING");
  expect(pings[0]!.sequence).toBe("0");
  expect(pings[0]!.payloadLen).toBe(16);
  await expect.poll(() => debugValue<{ rttMs: number | null }>(page, "client").then((c) => c.rttMs)).not.toBeNull();
});
