import { test } from "node:test";
import assert from "node:assert/strict";
import {
  FACTS_SCHEMA,
  PressureTracker,
  WEB_FACT_KEYS,
  buildFactsPayload,
  factsResult,
  fullscreenStateOf,
  parseChromeVersion,
  sendFacts,
  wakeLockStateOf,
  type FactsRequestInit,
} from "../../src/facts.js";

// The web key list of PROTOCOL 15.1, typed here from the document (not imported) so a drift in facts.ts fails.
const PROTOCOL_WEB_KEYS = [
  "chromeVersion", "userAgent", "devicePixelRatio", "viewport", "displayMode", "secureContext", "wakeLockSupported",
  "wakeLockState", "fullscreenState", "coalescedEvents", "rawUpdate", "predictedEvents", "firstPenPointerdown",
  "pressureMin", "pressureMax", "pressureSamples", "rttMs", "macBuild",
];

const UA = "Mozilla/5.0 (Linux; Android 13; DC-1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.7390.54 Safari/537.36";
const NOW = new Date(Date.UTC(2026, 9, 3, 14, 5, 9, 123));

test("PROTOCOL 15.1: exact web key set, schema, source, sentAt without milliseconds", () => {
  assert.deepEqual([...WEB_FACT_KEYS].sort(), [...PROTOCOL_WEB_KEYS].sort());
  const p = buildFactsPayload({ now: NOW, clientId: "3f0c" });
  assert.equal(p.schema, "daylight-tablet-facts/1");
  assert.equal(FACTS_SCHEMA, "daylight-tablet-facts/1");
  assert.equal(p.source, "web");
  assert.equal(p.clientId, "3f0c");
  assert.equal(p.sentAt, "2026-10-03T14:05:09Z");
  assert.deepEqual(Object.keys(p), ["schema", "source", "clientId", "sentAt", "facts"]);
  assert.deepEqual(Object.keys(p.facts).sort(), [...PROTOCOL_WEB_KEYS].sort());
});

test("every key is present and null when unknown; clientId omitted when absent, empty or over 64", () => {
  const p = buildFactsPayload({ now: NOW });
  for (const k of PROTOCOL_WEB_KEYS) assert.ok(k in p.facts, k);
  for (const k of PROTOCOL_WEB_KEYS) assert.equal((p.facts as Record<string, unknown>)[k], null, k);
  assert.equal("clientId" in p, false);
  assert.equal("clientId" in buildFactsPayload({ now: NOW, clientId: "" }), false);
  assert.equal("clientId" in buildFactsPayload({ now: NOW, clientId: "a".repeat(65) }), false);
  assert.equal(buildFactsPayload({ now: NOW, clientId: "a".repeat(64) }).clientId, "a".repeat(64));
  const nan = buildFactsPayload({ now: NOW, devicePixelRatio: Number.NaN, rttMs: Infinity, viewport: [Number.NaN, 5] });
  assert.equal(nan.facts.devicePixelRatio, null);
  assert.equal(nan.facts.rttMs, null);
  assert.equal(nan.facts.viewport, null);
});

test("values are flat (string, finite number, boolean or null) and strings are capped at 1024", () => {
  const long = `${UA} ${"x".repeat(3000)}`;
  const p = buildFactsPayload({
    now: NOW,
    clientId: "0123456789abcdef",
    userAgent: long,
    devicePixelRatio: 2,
    viewport: [800, 1280],
    displayMode: "fullscreen",
    secureContext: false,
    wakeLockSupported: true,
    wakeLockState: "held",
    fullscreenState: "on",
    coalescedEvents: true,
    rawUpdate: false,
    predictedEvents: true,
    firstPenPointerdown: `daylight-web first pen pointerdown button=0 buttons=1 pressure=0.5 tiltX=0 tiltY=0${"y".repeat(2000)}`,
    pressure: { min: 0.1, max: 1.4, samples: 12 },
    rttMs: 3.25,
    macBuild: 42,
  });
  for (const [k, v] of Object.entries(p.facts)) {
    assert.ok(v === null || typeof v === "boolean" || typeof v === "string" || (typeof v === "number" && Number.isFinite(v)), k);
    if (typeof v === "string") assert.ok(v.length <= 1024, k);
  }
  assert.equal((p.facts.userAgent as string).length, 1024);
  assert.equal((p.facts.firstPenPointerdown as string).length, 1024);
  assert.equal(p.facts.chromeVersion, "141.0.7390.54");
  assert.equal(p.facts.viewport, "800x1280");
  assert.equal(p.facts.devicePixelRatio, 2);
  assert.equal(p.facts.pressureMin, 0.1);
  assert.equal(p.facts.pressureMax, 1.4);
  assert.equal(p.facts.pressureSamples, 12);
  assert.equal(p.facts.wakeLockState, "held");
  assert.equal(p.facts.fullscreenState, "on");
  assert.equal(p.facts.macBuild, 42);
  assert.ok(Buffer.byteLength(JSON.stringify(p)) <= 16384);
});

test("parseChromeVersion reads Chrome/<v> and is null otherwise", () => {
  assert.equal(parseChromeVersion(UA), "141.0.7390.54");
  assert.equal(parseChromeVersion("Mozilla/5.0 HeadlessChrome/141.0.7390.37 Safari/537.36"), "141.0.7390.37");
  assert.equal(parseChromeVersion("Mozilla/5.0 (Macintosh) Gecko/20100101 Firefox/131.0"), null);
  assert.equal(parseChromeVersion(""), null);
  assert.equal(parseChromeVersion(null), null);
  assert.equal(parseChromeVersion(undefined), null);
});

test("PressureTracker: min, max and count of pen pressures above 0 only", () => {
  const t = new PressureTracker();
  assert.deepEqual(t.range, { min: null, max: null, samples: 0 });
  t.observe("pen", 0);
  t.observe("touch", 0.7);
  t.observe("mouse", 0.5);
  t.observe("pen", Number.NaN);
  t.observe("pen", -0.2);
  assert.deepEqual(t.range, { min: null, max: null, samples: 0 });
  t.observe("pen", 0.4);
  t.observe("pen", 0.05);
  t.observe("pen", 1.3);
  t.observe("touch", 2);
  assert.deepEqual(t.range, { min: 0.05, max: 1.3, samples: 3 });
});

test("wake lock and fullscreen states use the PROTOCOL 15.1 words", () => {
  assert.equal(wakeLockStateOf(false, false, false), "not requested");
  assert.equal(wakeLockStateOf(true, false, false), "refused");
  assert.equal(wakeLockStateOf(true, true, true), "held");
  assert.equal(wakeLockStateOf(true, true, false), "released");
  assert.equal(fullscreenStateOf(false, false), "not requested");
  assert.equal(fullscreenStateOf(true, true), "on");
  assert.equal(fullscreenStateOf(true, false), "refused");
});

test("result lines: 200 sent, 404 and 405 old Mac, other refused, null unreachable; no em-dash", () => {
  assert.deepEqual(factsResult(200), { outcome: "sent", status: 200, text: "Sent to your Mac." });
  assert.equal(factsResult(404).text, "Your Mac did not accept the facts (404). Update Daylight on your Mac.");
  assert.equal(factsResult(405).text, "Your Mac did not accept the facts (405). Update Daylight on your Mac.");
  assert.equal(factsResult(415).text, "Your Mac refused the facts (415).");
  assert.equal(factsResult(415).outcome, "refused");
  assert.equal(factsResult(null).text, "Could not reach your Mac. Check the connection and tap again.");
  for (const s of [200, 404, 405, 400, 413, null]) assert.ok(!factsResult(s).text.includes("\u2014"));
});

test("sendFacts posts JSON to ./api/facts and maps status, network error and timeout", async () => {
  const payload = buildFactsPayload({ now: NOW, clientId: "ab" });
  let seen: { url: string; init: FactsRequestInit } | null = null;
  const ok = await sendFacts(payload, async (url, init) => { seen = { url, init }; return { status: 200 }; });
  assert.equal(ok.outcome, "sent");
  const s = seen as unknown as { url: string; init: FactsRequestInit };
  assert.equal(s.url, "./api/facts");
  assert.equal(s.init.method, "POST");
  assert.deepEqual(s.init.headers, { "Content-Type": "application/json" });
  assert.deepEqual(JSON.parse(s.init.body), payload);
  assert.ok(s.init.signal);
  assert.equal((await sendFacts(payload, async () => ({ status: 404 }))).outcome, "old-mac");
  assert.equal((await sendFacts(payload, async () => { throw new TypeError("Failed to fetch"); })).outcome, "unreachable");
  let aborted = false;
  const slow = await sendFacts(payload, (_url, init) => new Promise((_resolve, reject) => {
    init.signal?.addEventListener("abort", () => { aborted = true; reject(new Error("aborted")); });
  }), 20);
  assert.equal(slow.outcome, "unreachable");
  assert.equal(slow.status, null);
  assert.equal(aborted, true);
});
