// Stroke geometry shared by the canvas and the Node unit tests (no DOM): pressure to width (SPEC 6.6),
// point and segment distances, and the eraser hit test, which mirrors DaylightKit's Geometry.strokeHit
// so the page's guess about what it erased matches the Mac's authoritative answer as closely as possible.

export interface LocalPoint {
  x: number;
  y: number;
  p: number;
}

/** The part of a stroke the hit test reads (LocalStroke in ink.ts is one). */
export interface StrokeShape {
  baseWidth: number;
  points: readonly LocalPoint[];
}

/** Stroke width for a segment at pressure p (SPEC 6.6). */
export function strokeWidth(baseWidth: number, pressure: number): number {
  return baseWidth * (0.55 + 0.9 * pressure);
}

export function clampPressure(p: number): number {
  if (!(p > 0)) return 0;
  return p > 1 ? 1 : p;
}

/** Point-to-segment distance in canvas units. */
export function pointSegmentDistance(p: LocalPoint, a: LocalPoint, b: LocalPoint): number {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  const len2 = dx * dx + dy * dy;
  let t = 0;
  if (len2 > 0) t = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2));
  const cx = a.x + t * dx;
  const cy = a.y + t * dy;
  return Math.hypot(p.x - cx, p.y - cy);
}

function cross(o: LocalPoint, p: LocalPoint, q: LocalPoint): number {
  return (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x);
}

function segmentsIntersect(a: LocalPoint, b: LocalPoint, c: LocalPoint, d: LocalPoint): boolean {
  const d1 = cross(c, d, a);
  const d2 = cross(c, d, b);
  const d3 = cross(a, b, c);
  const d4 = cross(a, b, d);
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

/** Segment-to-segment distance (0 when they cross), as the Kit's Geometry.segmentDistanceSquared. */
export function segmentDistance(a: LocalPoint, b: LocalPoint, c: LocalPoint, d: LocalPoint): number {
  if (segmentsIntersect(a, b, c, d)) return 0;
  return Math.min(pointSegmentDistance(a, c, d), pointSegmentDistance(b, c, d), pointSegmentDistance(c, a, b), pointSegmentDistance(d, a, b));
}

/**
 * How far the eraser reaches for stroke segment `i` (from point i-1 to point i): the eraser radius plus half the
 * wider of the two neighbouring widths; for a one-point stroke (`i` 0) half the dot's width (Kit Geometry.strokeHit).
 */
export function eraserReach(s: StrokeShape, i: number, radius: number): number {
  const pts = s.points;
  if (pts.length === 0) return radius;
  if (i <= 0 || pts.length === 1) return radius + strokeWidth(s.baseWidth, pts[0]!.p) / 2;
  const a = pts[i - 1];
  const b = pts[i];
  if (!a || !b) return radius;
  return radius + Math.max(strokeWidth(s.baseWidth, a.p), strokeWidth(s.baseWidth, b.p)) / 2;
}

/**
 * True when the eraser segment `from`-`to` with `radius` touches the stroke: some stroke segment (or its single
 * point) lies within `eraserReach` of the eraser segment. Same rule as DaylightKit's Geometry.strokeHit.
 */
export function strokeHitsSegment(s: StrokeShape, from: LocalPoint, to: LocalPoint, radius: number): boolean {
  const pts = s.points;
  if (pts.length === 0) return false;
  if (pts.length === 1) return pointSegmentDistance(pts[0]!, from, to) <= eraserReach(s, 0, radius);
  for (let i = 1; i < pts.length; i++) {
    const a = pts[i - 1];
    const b = pts[i];
    if (!a || !b) continue;
    if (segmentDistance(a, b, from, to) <= eraserReach(s, i, radius)) return true;
  }
  return false;
}
