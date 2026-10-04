import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { Encoder, Opcode, toHex } from "../../src/protocol.js";
import { LASER_CONTACT_INTENSITY, LASER_DECAY_S, LASER_HOVER_INTENSITY, LaserThrottle, laserIntensity, type LaserPoint } from "../../src/laser.js";

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
  // A side button in the air (or a digitizer's first unpressured sample) is still a hover.
  assert.equal(laserIntensity({ pointerType: "pen", buttons: 1, pressure: 0 }), LASER_HOVER_INTENSITY);
  assert.equal(laserIntensity({ pointerType: "touch", buttons: 1, pressure: 0.5 }), null);
  assert.equal(laserIntensity({ pointerType: "mouse", buttons: 1, pressure: 0.5 }), null);
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
