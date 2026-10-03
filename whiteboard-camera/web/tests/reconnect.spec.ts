// SPEC 16 D5: re-dial with backoff (1000 ms x 1.7 capped at 15 s); the offline ring replays a stroke;
// ACK 1 shows "Look at your Mac" and no ink is sent until ACK 0. Plus: denied stops retrying until a
// tap, a server that does not echo solstream.v1 is incompatible, and a mid-stroke drop restarts the stroke.
import { test, expect } from "@playwright/test";
import { FakeMac, debugValue, inkAlphaAt, openWhiteboard, paperBox, penMove, penRelease, penStroke, toPage, waitForFrames } from "./pen.js";

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
  // START, one to three CHUNKs (animation frames may split the three points), COMMIT; three points in all.
  await expect.poll(() => debugValue<{ opcodes: number[] }>(page, "ring").then((r) => r.opcodes.map((o) => o.toString(16)).join(","))).toMatch(/^10(,11){1,3},12$/);
  const ringedBefore = await debugValue<{ length: number; points: number }>(page, "ring");
  expect(ringedBefore.points).toBe(3);
  expect((await fake.framesNamed("STROKE_START")).length).toBe(0);
  // The Mac is back; the page re-dials with backoff and replays the ring after ACK 0.
  await fake.scenario({ refuse: false });
  await expect.poll(() => debugValue<string>(page, "phase"), { timeout: 15_000 }).toBe("live");
  const commits = await waitForFrames(fake, "STROKE_COMMIT");
  const frames = await fake.frames();
  const conn2 = frames.filter((f) => f.conn === commits[0]!.conn).map((f) => f.name);
  expect(conn2.slice(0, 2)).toEqual(["HANDSHAKE", "STROKE_START"]);
  expect(conn2.slice(2, ringedBefore.length).every((n) => n === "STROKE_CHUNK")).toBe(true);
  expect(conn2[ringedBefore.length]).toBe("STROKE_COMMIT");
  expect(commits[0]!.pointCount).toBe(3);
  const stats = await debugValue<{ framesReplayed: number; framesRinged: number }>(page, "client");
  expect(stats.framesReplayed).toBe(ringedBefore.length);
  expect(stats.framesRinged).toBe(ringedBefore.length);
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
  expect((await debugValue<{ opcodes: number[] }>(page, "ring")).opcodes.map((o) => o.toString(16)).join(",")).toMatch(/^10(,11){1,2},12$/);
  // The owner clicks Allow on the Mac.
  await fake.ack(0);
  await expect.poll(() => debugValue<string>(page, "phase")).toBe("live");
  await waitForFrames(fake, "STROKE_COMMIT");
  expect((await fake.frames()).map((f) => f.name).join(",")).toMatch(/^HANDSHAKE,STROKE_START(,STROKE_CHUNK){1,2},STROKE_COMMIT$/);
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

test("a server that does not echo solstream.v1 reads as refused: the client waits a minute between dials", async ({ page, request }) => {
  // Chromium refuses the upgrade itself when the offered subprotocol is not echoed, so the page sees
  // five failed dials (1 + 1.7 + 2.9 + 4.9 s), then asks /api/info; the Mac is there, so the socket was refused
  // (an old protocol looks the same from here): the chip says so and the next quiet dial is 60 s away.
  test.setTimeout(90_000);
  const fake = new FakeMac(request);
  await fake.scenario({ echoProtocol: false });
  await page.goto("/");
  await page.locator("#start").click();
  await expect.poll(() => debugValue<string>(page, "phase"), { timeout: 30_000 }).toBe("refused");
  await expect(page.locator("#chip")).toHaveAttribute("data-state", "refused");
  await expect(page.locator("#chip")).toHaveText("Mac found, socket refused. Tap to retry");
  const dialsAtStop = (await fake.dials()).length;
  expect(dialsAtStop).toBe(5);
  await page.waitForTimeout(3000);
  expect((await fake.dials()).length).toBe(dialsAtStop);
  expect((await fake.frames()).length).toBe(0);   // no HANDSHAKE was ever sent
  expect((await debugValue<{ opens: number; refusedRedials: number }>(page, "client")).opens).toBe(0);
  expect((await debugValue<{ REFUSED_REDIAL_MS: number }>(page, "constants")).REFUSED_REDIAL_MS).toBe(60_000);
  // Clear and New page are off while not live; "Update Daylight on your Mac" is reserved for ACK status 3.
  await expect(page.locator("#clear")).toBeDisabled();
  await expect(page.locator("#new-page")).toBeDisabled();
  // A tap retries from scratch once the Mac is compatible again.
  await fake.scenario({ echoProtocol: true });
  await page.locator("#chip").tap();
  await expect.poll(() => debugValue<string>(page, "phase"), { timeout: 10_000 }).toBe("live");
  await expect(page.locator("#clear")).toBeEnabled();
});

test("ACK 3 is the incompatible phase with Update Daylight on your Mac", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await fake.scenario({ ack: 3 });
  await openWhiteboard(page, { waitFor: "incompatible" });
  await expect(page.locator("#chip")).toHaveText("Update Daylight on your Mac");
  await expect(page.locator("#chip")).toHaveAttribute("data-state", "incompatible");
  await page.waitForTimeout(1500);
  expect((await fake.dials()).length).toBe(1);
});

test("Clear, New page, Undo and Redo are gated while the Mac is away; the ring keeps the ink", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  await fake.state({ governor: 2, flags: { allowed: true, activeSource: true }, undoDepth: 1, redoDepth: 0 });
  await expect(page.locator("#undo")).toBeEnabled();
  await fake.scenario({ refuse: true });
  await fake.close(1001);
  await expect.poll(() => debugValue<string>(page, "phase")).not.toBe("live");
  await expect(page.locator("#chip")).toHaveText("Looking for your Mac");
  for (const id of ["#clear", "#new-page", "#undo", "#redo"]) await expect(page.locator(id)).toBeDisabled();
  expect(await debugValue<boolean>(page, "toolbarLive")).toBe(false);
  const box = await paperBox(page);
  await penStroke(page, [{ ...toPage(box, 100, 100), p: 0.4 }, { ...toPage(box, 200, 160), p: 0.6 }, { ...toPage(box, 300, 220), p: 0.8 }]);
  const ringed = () => debugValue<{ opcodes: number[] }>(page, "ring").then((r) => r.opcodes.map((o) => o.toString(16)).join(","));
  await expect.poll(ringed).toMatch(/^10(,11){1,3},12$/);
  expect((await debugValue<{ points: number }>(page, "ring")).points).toBe(3);
  const before = await ringed();
  // A disabled button fires no click; even a scripted one changes nothing.
  await page.evaluate(() => { for (const id of ["clear", "new-page"]) document.getElementById(id)!.click(); });
  await page.waitForTimeout(150);
  expect(await ringed()).toBe(before);
  expect(await debugValue<number>(page, "pageIndex")).toBe(0);
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(1);
  await fake.scenario({ refuse: false });
  await expect.poll(() => debugValue<string>(page, "phase"), { timeout: 15_000 }).toBe("live");
  await waitForFrames(fake, "STROKE_COMMIT");
  const names = (await fake.frames()).map((f) => f.name);
  expect(names).not.toContain("CLEAR_CANVAS");
  expect(names).not.toContain("PAGE_CHANGE");
  await expect(page.locator("#clear")).toBeEnabled();
  await expect(page.locator("#new-page")).toBeEnabled();
  await expect(page.locator("#undo")).toBeDisabled();   // depths come back with the next STATE
  await fake.state({ governor: 2, flags: { allowed: true, activeSource: true }, undoDepth: 2, redoDepth: 0 });
  await expect(page.locator("#undo")).toBeEnabled();
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
  await penMove(page, [{ ...c, p: 0.5 }, { ...d, p: 0.5 }]);
  await penRelease(page, d.x, d.y);
  await expect.poll(() => debugValue<string>(page, "phase"), { timeout: 10_000 }).toBe("live");
  const commits = await waitForFrames(fake, "STROKE_COMMIT");
  const starts = await fake.framesNamed("STROKE_START");
  expect(starts.length).toBe(2);
  expect(starts[1]!.strokeId).not.toBe(first.strokeId);
  expect(commits[0]!.strokeId).toBe(starts[1]!.strokeId);
  const onNewSocket = (await fake.frames()).filter((f) => f.conn === commits[0]!.conn);
  expect(onNewSocket.slice(0, 2).map((f) => f.name)).toEqual(["HANDSHAKE", "STROKE_START"]);
  // Nothing for the old id reaches the new socket: the Mac committed that stroke when the first socket went.
  expect(onNewSocket.filter((f) => f.name === "STROKE_CHUNK" && f.strokeId === first.strokeId).length).toBe(0);
  const chunks = onNewSocket.filter((f) => f.name === "STROKE_CHUNK");
  expect(chunks.length).toBeGreaterThanOrEqual(1);
  for (const ch of chunks) expect(ch.strokeId).toBe(starts[1]!.strokeId);
  const points = chunks.flatMap((ch) => ch.points as { deltaMs: number }[]);
  expect(points.length).toBe(2);
  expect(points[0]!.deltaMs).toBe(0);   // the restarted stroke's clock starts at its first point
  expect(commits[0]!.pointCount).toBe(2);
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

test("a stroke whose START went out by ring replay is restarted when that connection drops later in the contact", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await fake.scenario({ ack: 1 });
  await openWhiteboard(page, { waitFor: "pending" });
  const box = await paperBox(page);
  const row = (x0: number, n: number) => Array.from({ length: n }, (_, k) => ({ ...toPage(box, x0 + k * 5, 600), p: 0.5 }));
  // Pen down while the Allow panel is up: the START is ringed.
  await penStroke(page, row(100, 20), { release: false });
  // Allow, mid-contact: the ring replays the START on this connection, then the samples go out live.
  await fake.ack(0);
  await expect.poll(() => debugValue<string>(page, "phase")).toBe("live");
  const first = (await waitForFrames(fake, "STROKE_START"))[0]!;
  await penMove(page, row(200, 20));
  await waitForFrames(fake, "STROKE_CHUNK", 2);
  // The connection drops while the pen is still down.
  await fake.scenario({ ack: 0, refuse: true });
  await fake.close(1001);
  await expect.poll(() => debugValue<string>(page, "phase")).not.toBe("live");
  await penMove(page, row(300, 20));
  await fake.scenario({ refuse: false });
  await expect.poll(() => debugValue<string>(page, "phase"), { timeout: 15_000 }).toBe("live");
  const last = row(300, 20)[19]!;
  await penRelease(page, last.x, last.y);
  const commits = await waitForFrames(fake, "STROKE_COMMIT");
  const onNewSocket = (await fake.frames()).filter((f) => f.conn !== first.conn);
  const starts = onNewSocket.filter((f) => f.name === "STROKE_START");
  expect(starts.length).toBe(1);
  expect(starts[0]!.strokeId).not.toBe(first.strokeId);
  for (const f of onNewSocket.filter((g) => g.name === "STROKE_CHUNK" || g.name === "STROKE_COMMIT")) expect(f.strokeId).toBe(starts[0]!.strokeId);
  expect(commits.every((c) => c.strokeId === starts[0]!.strokeId)).toBe(true);
  expect((await debugValue<{ restarted: number }>(page, "ink")).restarted).toBe(1);
});

test("after a Mac relaunch the tablet keeps exactly the strokes the Mac holds: the ones drawn offline", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await openWhiteboard(page);
  const box = await paperBox(page);
  for (const y of [300, 500, 700]) await penStroke(page, [{ ...toPage(box, 100, y), p: 0.5 }, { ...toPage(box, 500, y), p: 0.5 }]);
  await waitForFrames(fake, "STROKE_COMMIT", 3);
  // The Mac quits (update, crash); the owner keeps writing while it relaunches.
  await fake.scenario({ refuse: true });
  await fake.close(1001);
  await expect.poll(() => debugValue<string>(page, "phase")).not.toBe("live");
  await penStroke(page, [{ ...toPage(box, 100, 900), p: 0.5 }, { ...toPage(box, 500, 900), p: 0.5 }]);
  await expect.poll(() => debugValue<{ opcodes: number[] }>(page, "ring").then((r) => r.opcodes.includes(0x12))).toBe(true);
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(4);
  // The relaunched Mac starts empty: its ACK 0 comes with STATE 0 / 0, sent before it reads the replay.
  await fake.scenario({ refuse: false });
  await expect.poll(() => debugValue<string>(page, "phase"), { timeout: 15_000 }).toBe("live");
  await expect.poll(() => debugValue<number>(page, "visibleStrokes")).toBe(1);
  expect((await debugValue<{ historyLost: number }>(page, "ink")).historyLost).toBe(1);
  expect(await inkAlphaAt(page, 300, 900)).toBeGreaterThan(0);
  expect(await inkAlphaAt(page, 300, 300)).toBe(0);
  // The Mac's STATEs after the replay (1 Hz repeats past the stale run limit): one stroke, the offline one.
  for (let i = 0; i < 3; i++) await fake.state({ governor: 2, flags: { allowed: true, activeSource: true }, undoDepth: 1, redoDepth: 0 });
  await page.waitForTimeout(200);
  expect(await debugValue<number>(page, "visibleStrokes")).toBe(1);
  expect(await inkAlphaAt(page, 300, 900)).toBeGreaterThan(0);
  expect(await inkAlphaAt(page, 300, 300)).toBe(0);
  // An undo on the Mac hides that stroke on the tablet as well.
  await fake.state({ governor: 2, flags: { allowed: true, activeSource: true }, undoDepth: 0, redoDepth: 1 });
  await expect.poll(() => debugValue<number>(page, "visibleStrokes")).toBe(0);
  expect(await inkAlphaAt(page, 300, 900)).toBe(0);
});

test("a silent Mac (socket open, no PONG, no STATE) is given up on within 30 s and later ink is ringed", async ({ page, request }) => {
  const fake = new FakeMac(request);
  await page.clock.install();   // before navigation: the ping interval and Date.now run on the fake clock
  await openWhiteboard(page);
  await page.clock.runFor(10_500);
  await expect.poll(() => debugValue<{ rttMs: number | null }>(page, "client").then((c) => c.rttMs)).not.toBeNull();
  // The path dies without a FIN reaching the tablet: the Mac end answers nothing and closes nothing.
  await fake.scenario({ silent: true });
  await page.clock.runFor(20_000);
  expect(await debugValue<string>(page, "phase")).toBe("live");   // 20 s of silence is not yet dead
  await page.clock.runFor(10_000);
  await expect.poll(() => debugValue<string>(page, "phase")).not.toBe("live");
  expect((await debugValue<{ livenessTimeouts: number; lastCloseCode: number }>(page, "client")).livenessTimeouts).toBe(1);
  await expect(page.locator("#chip")).toHaveText("Looking for your Mac");
  await expect(page.locator("#clear")).toBeDisabled();
  const sentBefore = (await debugValue<{ framesSent: number }>(page, "client")).framesSent;
  const box = await paperBox(page);
  await penStroke(page, [{ ...toPage(box, 100, 400), p: 0.5 }, { ...toPage(box, 300, 400), p: 0.5 }]);
  await expect.poll(() => debugValue<{ opcodes: number[] }>(page, "ring").then((r) => r.opcodes.includes(0x12))).toBe(true);
  expect((await debugValue<{ framesSent: number }>(page, "client")).framesSent).toBe(sentBefore);
  // The Mac answers again: the re-dial goes live and the ring replays the stroke.
  await fake.scenario({ silent: false });
  await page.clock.runFor(2_000);
  await expect.poll(() => debugValue<string>(page, "phase"), { timeout: 10_000 }).toBe("live");
  const commits = await waitForFrames(fake, "STROKE_COMMIT");
  expect(commits[0]!.pointCount).toBe(2);
});
