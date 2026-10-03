import { test } from "node:test";
import assert from "node:assert/strict";
import { LONG_PRESS_MS, breath, chipView, returningSeconds } from "../../src/chip-state.js";
import type { StateReport } from "../../src/protocol.js";

function state(over: Partial<StateReport> = {}): StateReport {
  return {
    governor: 2,
    pinned: false,
    preWarning: false,
    allowed: true,
    activeSource: true,
    cameraAttached: true,
    sinkConnected: true,
    saving: false,
    captureIdle: false,
    mode: 0,
    inkSource: 0,
    progress: 1,
    msToReturn: 60000,
    pageIndex: 0,
    strokeCount: 0,
    undoDepth: 0,
    redoDepth: 0,
    ...over,
  };
}

test("SPEC 10 numbers: long press 600 ms, breath formula at 0.5 Hz", () => {
  assert.equal(LONG_PRESS_MS, 600);
  assert.ok(Math.abs(breath(0)) < 1e-12);
  assert.ok(Math.abs(breath(1) - 1) < 1e-12);
  assert.ok(Math.abs(breath(2)) < 1e-12);
  assert.ok(Math.abs(breath(0.5) - 0.5) < 1e-12);
});

test("Returning in N uses ceil(ms / 1000) and never shows 0", () => {
  assert.equal(returningSeconds(4200), 5);
  assert.equal(returningSeconds(4000), 4);
  assert.equal(returningSeconds(1), 1);
  assert.equal(returningSeconds(0), 1);
});

test("connection phases before any STATE", () => {
  assert.equal(chipView("disconnected", null).text, "Looking for your Mac");
  assert.equal(chipView("connecting", null).kind, "searching");
  const pending = chipView("pending", null);
  assert.equal(pending.text, "Look at your Mac");
  assert.equal(pending.dot, true);
  const denied = chipView("denied", null);
  assert.equal(denied.text, "Not allowed by the Mac");
  assert.equal(denied.tap, "retry");
  assert.equal(chipView("live", null).text, "Looking for your Mac");
  const incompatible = chipView("incompatible", null);
  assert.equal(incompatible.text, "Update Daylight on your Mac");
  assert.equal(incompatible.tap, "retry");
  const refused = chipView("refused", null);
  assert.equal(refused.kind, "refused");
  assert.equal(refused.text, "Mac found, socket refused. Tap to retry");
  assert.equal(refused.tap, "retry");
  assert.equal(refused.longPressReturns, false);
});

test("STATE mapping of PROTOCOL 6.14", () => {
  assert.equal(chipView("live", state({ allowed: false })).text, "Look at your Mac");
  assert.equal(chipView("live", state({ activeSource: false, inkSource: 1 })).text, "Ink source is Daylight Ink on the Mac");
  assert.equal(chipView("live", state({ activeSource: false, inkSource: 2 })).text, "Ink source is mirror on the Mac");
  assert.equal(chipView("live", state({ activeSource: false, inkSource: 0 })).text, "Ink source is web on the Mac");
  assert.equal(chipView("live", state({ activeSource: false })).tap, "explain");
  assert.equal(chipView("live", state({ governor: 0, msToReturn: null })).text, "Camera");
  assert.equal(chipView("live", state({ governor: 0, msToReturn: null })).kind, "camera");
  assert.equal(chipView("live", state({ governor: 1 })).text, "LIVE");
  assert.equal(chipView("live", state({ governor: 2 })).text, "LIVE");
  assert.equal(chipView("live", state({ governor: 2 })).dot, true);
  assert.equal(chipView("live", state({ governor: 3, msToReturn: 0 })).text, "Returning");
  assert.equal(chipView("live", state({ governor: 3, msToReturn: 0 })).kind, "returning");
});

test("pinned wins in any governor state", () => {
  for (const governor of [1, 2, 3] as const) {
    const v = chipView("live", state({ governor, pinned: true, msToReturn: null }));
    assert.equal(v.text, "KEEP WHITEBOARD");
    assert.equal(v.kind, "pinned");
    assert.equal(v.tap, "pin");
  }
});

test("pre-warning counts down locally between STATE messages", () => {
  const s = state({ preWarning: true, msToReturn: 4200 });
  assert.equal(chipView("live", s, 0).text, "Returning in 5");
  assert.equal(chipView("live", s, 300).text, "Returning in 4");
  assert.equal(chipView("live", s, 3300).text, "Returning in 1");
  assert.equal(chipView("live", s, 9000).text, "Returning in 1");
  const v = chipView("live", s);
  assert.equal(v.kind, "prewarn");
  assert.equal(v.breathing, true);
  assert.equal(v.dot, true);
  assert.equal(v.tap, "pin");
  assert.equal(v.longPressReturns, true);
});

test("tap and long press semantics", () => {
  assert.equal(chipView("live", state({ governor: 2 })).tap, "pin");
  assert.equal(chipView("live", state({ governor: 2 })).longPressReturns, true);
  assert.equal(chipView("live", state({ governor: 3, msToReturn: 0 })).tap, "pin");
  assert.equal(chipView("live", state({ governor: 0, msToReturn: null })).longPressReturns, false);
  assert.equal(chipView("pending", null).tap, "none");
});
