import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { Encoder, Opcode, toHex } from "../../src/protocol.js";
import { LASER_CONTACT_INTENSITY, LASER_DECAY_S, LASER_HOVER_INTENSITY, LaserThrottle, PEN_ERASER_BUTTON, PEN_TIP_BUTTON, laserIntensity, laserTakesSample, type LaserPoint } from "../../src/laser.js";

interface Manifest {
  timestamp_us: number;
  cases: { name: string; opcode: number; hex: string }[];
}

const manifest = JSON.parse(readFileSync(resolve("tests/golden/solstream-v1.json"), "utf8")) as Manifest;
/** PROTOCOL.md section 12, `laser_point`: (600, 800), intensity 1.0, decay 0.5 s. */
const PROTOCOL_LASER_POINT = "da0130001000000040e2cfeeb540060000001644000048440000803f0000003f";

test("the laser constants match the ticket and the golden vector's field values", () => {
  assert.equal(LASER_CONTACT_INTENSITY, 1.0);
  assert.equal(LASER_HOVER_INTENSITY, 0.5);
  assert.equal(LASER_DECAY_S, 0.5);
});

test("LASER_POINT (600, 800, contact, decay) encodes byte for byte as the golden laser_point", () => {
  // The header carries only the timestamp besides the opcode and length; the golden clock makes it deterministic.
  const enc = new Encoder(() => BigInt(manifest.timestamp_us));
  const hex = toHex(enc.laserPoint(600, 800, LASER_CONTACT_INTENSITY, LASER_DECAY_S));
  assert.equal(hex, PROTOCOL_LASER_POINT);
  const golden = manifest.cases.find((c) => c.name === "laser_point");
  assert.ok(golden);
  assert.equal(golden.opcode, Opcode.LASER_POINT);
  assert.equal(golden.opcode, 0x0030);
  assert.equal(hex, golden.hex);
});

test("intensity: pen contact 1.0, pen hover 0.5, fingers and mice never point", () => {
  assert.equal(laserIntensity({ pointerType: "pen", buttons: 1, pressure: 0.6 }), LASER_CONTACT_INTENSITY);
  assert.equal(laserIntensity({ pointerType: "pen", buttons: 0, pressure: 0 }), LASER_HOVER_INTENSITY);
  assert.equal(laserIntensity({ pointerType: "touch", buttons: 1, pressure: 0.5 }), null);
  assert.equal(laserIntensity({ pointerType: "mouse", buttons: 1, pressure: 0.5 }), null);
  assert.equal(laserIntensity({ pointerType: "touch", buttons: 0, pressure: 0 }), null, "a finger never hovers a laser");
});

// Review F7, the rule both clients share (Daylight Ink: PenRouterTest pins the same three rules).
test("rule 1: any pen contact is 1.0 whatever the pressure, pressure 0 included", () => {
  assert.equal(PEN_TIP_BUTTON, 1);
  assert.equal(PEN_ERASER_BUTTON, 32);
  // A digitizer's first contact sample may carry pressure 0 (LOOSE_ENDS D4): still contact, still 1.0.
  assert.equal(laserIntensity({ pointerType: "pen", buttons: PEN_TIP_BUTTON, pressure: 0 }), LASER_CONTACT_INTENSITY);
  assert.equal(laserIntensity({ pointerType: "pen", buttons: PEN_TIP_BUTTON, pressure: 1 }), LASER_CONTACT_INTENSITY);
  // The tip down with the barrel button held is contact too.
  assert.equal(laserIntensity({ pointerType: "pen", buttons: PEN_TIP_BUTTON | 2, pressure: 0.3 }), LASER_CONTACT_INTENSITY);
  // The barrel button pressed in the air is a hover, not a contact.
  assert.equal(laserIntensity({ pointerType: "pen", buttons: 2, pressure: 0 }), LASER_HOVER_INTENSITY);
});

test("rule 2: the eraser end on contact points at 1.0; an eraser end in the air is not reported by the browser", () => {
  assert.equal(laserIntensity({ pointerType: "pen", buttons: PEN_ERASER_BUTTON, pressure: 0.5 }), LASER_CONTACT_INTENSITY);
  assert.equal(laserIntensity({ pointerType: "pen", buttons: PEN_ERASER_BUTTON, pressure: 0 }), LASER_CONTACT_INTENSITY);
  // Pointer Events carry no eraser state while hovering (buttons 0), so the page cannot tell it from the tip: 0.5
  // (LOOSE_ENDS IL-9; Daylight Ink, which can, sends nothing for an eraser end in the air).
  assert.equal(laserIntensity({ pointerType: "pen", buttons: 0, pressure: 0 }), LASER_HOVER_INTENSITY);
});

test("rule 3: picking Laser mid-stroke lets the open stroke end normally; the laser takes the next contact", () => {
  // A stroke or an erase is open: its samples stay with it until its own pen-up (a COMMIT, never a CANCEL).
  assert.equal(laserTakesSample("laser", true), false);
  // Nothing open: the laser takes contact and hover.
  assert.equal(laserTakesSample("laser", false), true);
  // Any other tool: never the laser, open contact or not.
  for (const tool of ["pen", "highlighter", "eraser"]) {
    assert.equal(laserTakesSample(tool, false), false, tool);
    assert.equal(laserTakesSample(tool, true), false, tool);
  }
});

/** A fake animation frame: callbacks run only when the test says a frame passed. */
function fakeFrames() {
  let queue: (() => void)[] = [];
  return {
    schedule: (cb: () => void) => { queue.push(cb); },
    get pending() { return queue.length; },
    frame() { const q = queue; queue = []; for (const cb of q) cb(); },
  };
}

test("throttle: at most one point per frame, coalesced to the newest", () => {
  const raf = fakeFrames();
  const sent: LaserPoint[] = [];
  const t = new LaserThrottle((p) => sent.push(p), raf.schedule);
  t.offer({ x: 1, y: 1, intensity: 0.5 });
  t.offer({ x: 2, y: 2, intensity: 0.5 });
  t.offer({ x: 3, y: 3, intensity: 1 });
  assert.equal(raf.pending, 1, "one frame request for three offers");
  assert.equal(sent.length, 0);
  raf.frame();
  assert.deepEqual(sent, [{ x: 3, y: 3, intensity: 1 }]);
  assert.equal(t.coalesced, 2);
  // Nothing new: the next frame sends nothing and nothing is scheduled.
  raf.frame();
  assert.equal(sent.length, 1);
  assert.equal(raf.pending, 0);
  t.offer({ x: 4, y: 4, intensity: 0.5 });
  raf.frame();
  assert.deepEqual(sent.map((p) => p.x), [3, 4]);
  assert.equal(t.sent, 2);
});
