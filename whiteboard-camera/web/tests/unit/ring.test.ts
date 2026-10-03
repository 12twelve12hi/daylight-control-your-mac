import { test } from "node:test";
import assert from "node:assert/strict";
import { Ring, RING_CAPACITY_FRAMES, RING_CAPACITY_POINTS } from "../../src/ring.js";

function frame(tag: number): ArrayBuffer {
  const b = new ArrayBuffer(1);
  new Uint8Array(b)[0] = tag & 0xff;
  return b;
}
const tag = (b: ArrayBuffer) => new Uint8Array(b)[0];

test("capacity is 2000 points", () => {
  assert.equal(RING_CAPACITY_POINTS, 2000);
  assert.equal(new Ring().capacityPoints, 2000);
});

test("drain returns frames in arrival order and empties the ring", () => {
  const r = new Ring();
  r.push(frame(1), "a");
  r.push(frame(2), "a", 3);
  r.push(frame(3), "a");
  assert.equal(r.length, 3);
  assert.equal(r.points, 3);
  assert.deepEqual(r.drain().map(tag), [1, 2, 3]);
  assert.equal(r.length, 0);
  assert.equal(r.points, 0);
});

test("overflow drops the oldest whole stroke, start and commit included", () => {
  const r = new Ring(10);
  r.push(frame(1), "a");        // start a
  r.push(frame(2), "a", 6);     // chunk a
  r.push(frame(3), "a");        // commit a
  r.push(frame(4), "b");        // start b
  r.push(frame(5), "b", 4);     // chunk b: total 10, still fits
  assert.equal(r.points, 10);
  r.push(frame(6), "b", 1);     // 11 > 10: stroke a goes, all three frames
  assert.deepEqual(r.drain().map(tag), [4, 5, 6]);
  assert.equal(r.droppedStrokes, 1);
});

test("a single stroke larger than the capacity is dropped entirely", () => {
  const r = new Ring(5);
  r.push(frame(1), "a");
  r.push(frame(2), "a", 6);
  assert.equal(r.length, 0);
  assert.equal(r.points, 0);
  assert.equal(r.droppedStrokes, 1);
});

test("stroke-independent frames (key empty) survive until they are the oldest thing", () => {
  const r = new Ring(4);
  r.push(frame(9), "");         // an erase
  r.push(frame(1), "a");
  r.push(frame(2), "a", 4);
  r.push(frame(3), "b");
  r.push(frame(4), "b", 1);     // 5 > 4: oldest stroke with points is a; the erase stays
  assert.deepEqual(r.drain().map(tag), [9, 3, 4]);
});

test("clear discards everything", () => {
  const r = new Ring();
  r.push(frame(1), "a", 2);
  r.clear();
  assert.equal(r.length, 0);
  assert.equal(r.points, 0);
});

test("a frame budget bounds point-free frames too: the oldest frames go one by one and are counted apart", () => {
  const r = new Ring(2000, 4);
  for (let i = 1; i <= 6; i++) r.push(frame(i), "");   // six erase frames into a ring of four
  assert.equal(r.length, 4);
  assert.deepEqual(r.drain().map(tag), [3, 4, 5, 6]);
  assert.equal(r.droppedFrames, 2);
  assert.equal(r.droppedStrokes, 0, "frame drops are not stroke drops");
  assert.equal(RING_CAPACITY_FRAMES, 4096);
  assert.equal(new Ring().capacityFrames, 4096);
});

test("the frame budget keeps the point total right and never reorders erase frames against ink", () => {
  const r = new Ring(2000, 3);
  r.push(frame(1), "a", 2);
  r.push(frame(2), "");         // erase after stroke a
  r.push(frame(3), "b", 1);
  r.push(frame(4), "b");        // 4 > 3: frame 1 goes (its 2 points too)
  assert.equal(r.points, 1);
  assert.deepEqual(r.drain().map(tag), [2, 3, 4]);
  assert.equal(r.droppedFrames, 1);
});
