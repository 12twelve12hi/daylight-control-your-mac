import { test } from "node:test";
import assert from "node:assert/strict";
import { eraserReach, pointSegmentDistance, segmentDistance, strokeHitsSegment, strokeWidth, type StrokeShape } from "../../src/geometry.js";

const pt = (x: number, y: number, p = 0.5) => ({ x, y, p });

test("eraser reach mirrors DaylightKit Geometry.strokeHit: radius plus half the wider neighbouring width", () => {
  const s: StrokeShape = { baseWidth: 3.2, points: [pt(0, 0, 0.2), pt(10, 0, 1.0), pt(20, 0, 0.4)] };
  // Segment 1 (points 0 and 1): widths 3.2 * (0.55 + 0.18) = 2.336 and 3.2 * 1.45 = 4.64; the wider one counts.
  assert.ok(Math.abs(eraserReach(s, 1, 12) - (12 + strokeWidth(3.2, 1.0) / 2)) < 1e-12);
  assert.ok(Math.abs(eraserReach(s, 1, 12) - 14.32) < 1e-9);
  // Segment 2 (points 1 and 2): still the pressure-1 point.
  assert.ok(Math.abs(eraserReach(s, 2, 12) - 14.32) < 1e-9);
  // A dot: half its own width.
  const dot: StrokeShape = { baseWidth: 12, points: [pt(5, 5, 0.5)] };
  assert.ok(Math.abs(eraserReach(dot, 0, 12) - (12 + strokeWidth(12, 0.5) / 2)) < 1e-12);
  assert.ok(Math.abs(eraserReach(dot, 0, 12) - 18) < 1e-9);
});

test("a dot is hit within its reach and missed just outside it", () => {
  const dot: StrokeShape = { baseWidth: 12, points: [pt(100, 100, 0.5)] };   // reach 18
  assert.equal(strokeHitsSegment(dot, pt(100, 82.5), pt(140, 82.5), 12), true);
  assert.equal(strokeHitsSegment(dot, pt(100, 81.5), pt(140, 81.5), 12), false);
});

test("a stroke segment is hit by a crossing eraser and by a near miss within the reach, missed beyond it", () => {
  const s: StrokeShape = { baseWidth: 3.2, points: [pt(0, 100, 0.5), pt(200, 100, 0.5)] };   // width 3.2, reach 13.6
  assert.equal(strokeHitsSegment(s, pt(100, 50), pt(100, 150), 12), true, "crossing");
  assert.equal(strokeHitsSegment(s, pt(100, 86.5), pt(150, 86.5), 12), true, "parallel inside the reach");
  assert.equal(strokeHitsSegment(s, pt(100, 86.3), pt(150, 86.3), 12), false, "parallel just outside");
  assert.equal(strokeHitsSegment({ baseWidth: 3.2, points: [] }, pt(0, 0), pt(1, 1), 12), false);
});

test("point and segment distances", () => {
  assert.equal(pointSegmentDistance(pt(5, 5), pt(0, 0), pt(10, 0)), 5);
  assert.equal(pointSegmentDistance(pt(-3, 4), pt(0, 0), pt(10, 0)), 5, "clamped to the end point");
  assert.equal(segmentDistance(pt(0, 0), pt(10, 10), pt(0, 10), pt(10, 0)), 0, "crossing segments");
  assert.equal(segmentDistance(pt(0, 0), pt(10, 0), pt(0, 3), pt(10, 3)), 3, "parallel segments");
  assert.equal(segmentDistance(pt(0, 0), pt(10, 0), pt(13, 4), pt(20, 4)), 5, "end point to end point");
});
