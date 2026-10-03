// Pen-only ink canvas (SPEC D3, PROTOCOL 4, 6.3 to 6.8). Three stacked canvases over PaperBg:
// highlight (amber under the ink), ink, and a wet layer that receives the pointer events.
// Local rendering is a preview; the Mac is the source of truth (undo and redo follow STATE depths).

import { Encoder, MAX_POINTS_PER_CHUNK, newUuid16, toHex, type WirePoint } from "./protocol.js";
import type { Tool } from "./tools.js";

export const CANVAS_W = 1200;
export const CANVAS_H = 1600;
export const PEN_COLOR = 0xff111111;          // InkBlack
export const HIGHLIGHTER_COLOR = 0x80d97706;  // Amber at 50 percent
export const PEN_WIDTH = 3.2;
export const HIGHLIGHTER_WIDTH = 12.0;
export const ERASER_RADIUS = 12.0;
/** pointercancel / pointerleave: COMMIT when at least this many points and older than CANCEL_MIN_MS. */
export const CANCEL_MIN_POINTS = 2;
export const CANCEL_MIN_MS = 80;

/** Stroke width for a segment at pressure p (SPEC 6.6). */
export function strokeWidth(baseWidth: number, pressure: number): number {
  return baseWidth * (0.55 + 0.9 * pressure);
}

export function clampPressure(p: number): number {
  if (!(p > 0)) return 0;
  return p > 1 ? 1 : p;
}

export interface InkSink {
  readonly encoder: Encoder;
  /** Sends live, or rings while offline / pending. Returns true when it went out on a live socket. */
  sendInk(frame: ArrayBuffer, strokeKey: string, points: number): boolean;
  isLive(): boolean;
  backpressure(): "ok" | "hold" | "thin";
}

export interface LocalPoint {
  x: number;
  y: number;
  p: number;
}

export interface LocalStroke {
  key: string;
  tool: Tool;
  color: number;
  baseWidth: number;
  points: LocalPoint[];
}

interface ActiveStroke {
  id: Uint8Array;
  key: string;
  tool: Tool;
  color: number;
  baseWidth: number;
  pointerId: number;
  startedAt: number;        // timeStamp of the first point (delta_ms base)
  firstDownAt: number;      // for the 80 ms cancel rule
  lastDelta: number;
  last: LocalPoint;
  points: LocalPoint[];
  pending: WirePoint[];
  sent: number;
  startedLive: boolean;
}

interface ActiveErase {
  pointerId: number;
  last: LocalPoint;
}

export interface InkStats {
  strokes: number;
  points: number;
  ignored: number;
  committed: number;
  cancelled: number;
  erases: number;
  rawUpdates: number;
  coalesced: number;
  restarted: number;
  thinned: number;
}

export class InkCanvas {
  readonly highlight: HTMLCanvasElement;
  readonly ink: HTMLCanvasElement;
  readonly wet: HTMLCanvasElement;
  private readonly hctx: CanvasRenderingContext2D;
  private readonly ictx: CanvasRenderingContext2D;
  private readonly wctx: CanvasRenderingContext2D;
  private committed: LocalStroke[] = [];
  private visible = 0;
  private active: ActiveStroke | null = null;
  private erasing: ActiveErase | null = null;
  private rafQueued = false;
  private scale = 1;
  private readonly useRawUpdate: boolean;
  tool: Tool = "pen";
  readonly stats: InkStats = { strokes: 0, points: 0, ignored: 0, committed: 0, cancelled: 0, erases: 0, rawUpdates: 0, coalesced: 0, restarted: 0, thinned: 0 };
  /** Called after any local change (for autosave-style hooks and tests). */
  onChange: (() => void) | null = null;

  constructor(readonly container: HTMLElement, private readonly sink: InkSink) {
    const make = (cls: string): HTMLCanvasElement => {
      const c = document.createElement("canvas");
      c.className = `layer ${cls}`;
      container.appendChild(c);
      return c;
    };
    this.highlight = make("highlight");
    this.ink = make("ink");
    this.wet = make("wet");
    this.wet.setAttribute("aria-label", "Whiteboard canvas");
    const ctx = (c: HTMLCanvasElement): CanvasRenderingContext2D => {
      const got = c.getContext("2d", { desynchronized: true }) ?? c.getContext("2d");
      if (!got) throw new Error("no 2d context");
      return got;
    };
    this.hctx = ctx(this.highlight);
    this.ictx = ctx(this.ink);
    this.wctx = ctx(this.wet);
    this.useRawUpdate = "onpointerrawupdate" in window;
    this.layout();
    this.bind();
    if (typeof ResizeObserver === "function") new ResizeObserver(() => this.layout()).observe(container);
    else window.addEventListener("resize", () => this.layout());
  }

  // -- geometry ---------------------------------------------------------------

  /** Backing store = CSS size times DPR; drawing happens in canvas units through a transform. */
  layout(): void {
    const rect = this.container.getBoundingClientRect();
    const dpr = Math.max(1, Math.min(3, window.devicePixelRatio || 1));
    const w = Math.max(1, Math.round(rect.width * dpr));
    const h = Math.max(1, Math.round(rect.height * dpr));
    if (this.ink.width === w && this.ink.height === h) return;
    for (const c of [this.highlight, this.ink, this.wet]) { c.width = w; c.height = h; }
    this.scale = w / CANVAS_W;
    this.redraw();
  }

  private canvasPoint(e: { clientX: number; clientY: number; pressure: number }): LocalPoint {
    const rect = this.wet.getBoundingClientRect();
    return {
      x: ((e.clientX - rect.left) * CANVAS_W) / rect.width,
      y: ((e.clientY - rect.top) * CANVAS_H) / rect.height,
      p: clampPressure(e.pressure),
    };
  }

  // -- model ------------------------------------------------------------------

  get strokeCount(): number {
    return this.visible;
  }

  /** Visible strokes in order (for tests and export). */
  visibleStrokes(): readonly LocalStroke[] {
    return this.committed.slice(0, this.visible);
  }

  /**
   * STATE `undo_depth` / `redo_depth`: the local list and the Mac's list hold the same strokes in the
   * same order, so the first `undoDepth` are visible and the next `redoDepth` are the redo tail.
   */
  applyDepths(undoDepth: number, redoDepth: number): void {
    const visible = Math.min(undoDepth, this.committed.length);
    const keep = Math.min(this.committed.length, visible + redoDepth);
    const changed = visible !== this.visible || keep !== this.committed.length;
    this.visible = visible;
    this.committed = this.committed.slice(0, keep);
    if (changed) this.redraw();
  }

  /** Clear and New page: both layers and the local list. The Mac does the same on its side. */
  clearLocal(): void {
    this.committed = [];
    this.visible = 0;
    this.redraw();
    this.onChange?.();
  }

  /**
   * Called when the connection that carried the open stroke's STROKE_START is gone: the Mac committed
   * that stroke as it stood (SPEC D37), so the rest of the glass contact becomes a new stroke whose
   * START is ringed in front of its points.
   */
  restartOpenStroke(): void {
    const a = this.active;
    if (!a || !a.startedLive) return;
    this.flush();
    a.id = newUuid16();
    a.key = toHex(a.id);
    a.sent = 0;
    a.startedAt = -1;   // the next sample becomes the first point (delta_ms 0)
    a.lastDelta = 0;
    // A START with pressure 0 is dropped by the Mac (PROTOCOL 6.3); a lifted-but-captured pen reports 0.
    const pressure = a.last.p > 0 ? a.last.p : 0.5;
    a.startedLive = this.sink.sendInk(this.sink.encoder.strokeStart(a.id, toolCode(a.tool), a.color, a.baseWidth, pressure), a.key, 0);
    this.stats.restarted++;
  }

  // -- input ------------------------------------------------------------------

  private bind(): void {
    const el = this.wet;
    el.addEventListener("pointerdown", (e) => this.down(e));
    el.addEventListener("pointermove", (e) => this.move(e));
    if (this.useRawUpdate) {
      el.addEventListener("pointerrawupdate" as "pointermove", (e) => this.raw(e));
    }
    el.addEventListener("pointerup", (e) => this.up(e));
    el.addEventListener("pointercancel", (e) => this.cancel(e));
    el.addEventListener("pointerleave", (e) => { if (e.buttons !== 0) this.cancel(e); });
    el.addEventListener("contextmenu", (e) => e.preventDefault());
  }

  private down(e: PointerEvent): void {
    // Fingers and palms never draw and never engage; a pen with pressure 0 is a side button in the air.
    if (e.pointerType !== "pen" || e.buttons === 0 || clampPressure(e.pressure) <= 0) {
      this.stats.ignored++;
      return;
    }
    if (this.active || this.erasing) return;   // one contact at a time
    e.preventDefault();
    try { this.wet.setPointerCapture(e.pointerId); } catch { /* not fatal */ }
    const p = this.canvasPoint(e);
    if (this.tool === "eraser") {
      this.erasing = { pointerId: e.pointerId, last: p };
      this.eraseSegment(p, p);
      return;
    }
    const id = newUuid16();
    const color = this.tool === "highlighter" ? HIGHLIGHTER_COLOR : PEN_COLOR;
    const baseWidth = this.tool === "highlighter" ? HIGHLIGHTER_WIDTH : PEN_WIDTH;
    const a: ActiveStroke = {
      id,
      key: toHex(id),
      tool: this.tool,
      color,
      baseWidth,
      pointerId: e.pointerId,
      startedAt: e.timeStamp,
      firstDownAt: e.timeStamp,
      lastDelta: 0,
      last: p,
      points: [p],
      pending: [{ x: p.x, y: p.y, pressure: p.p, deltaMs: 0 }],
      sent: 0,
      startedLive: false,
    };
    a.startedLive = this.sink.sendInk(this.sink.encoder.strokeStart(id, toolCode(a.tool), color, baseWidth, p.p), a.key, 0);
    this.active = a;
    this.stats.strokes++;
    this.stats.points++;
    this.drawWetDot(a, p);
    this.queueFlush();
  }

  private raw(e: PointerEvent): void {
    this.stats.rawUpdates++;
    this.sample(e, [e]);
  }

  private move(e: PointerEvent): void {
    if (this.useRawUpdate && this.active) return;   // raw updates already carried these samples
    let events: PointerEvent[] = [e];
    if (typeof e.getCoalescedEvents === "function") {
      const c = e.getCoalescedEvents();
      if (c.length > 0) { events = c; this.stats.coalesced += c.length; }
    }
    this.sample(e, events);
  }

  private sample(e: PointerEvent, events: readonly PointerEvent[]): void {
    if (e.pointerType !== "pen") return;
    if (this.erasing && e.pointerId === this.erasing.pointerId) {
      if (e.buttons === 0) return;
      for (const ev of events) {
        const p = this.canvasPoint(ev);
        this.eraseSegment(this.erasing.last, p);
        this.erasing.last = p;
      }
      return;
    }
    const a = this.active;
    if (!a || e.pointerId !== a.pointerId || e.buttons === 0) return;
    for (const ev of events) {
      const p = this.canvasPoint(ev);
      if (a.startedAt < 0) a.startedAt = ev.timeStamp;
      const delta = Math.max(a.lastDelta, Math.round(ev.timeStamp - a.startedAt));
      a.lastDelta = delta;
      a.pending.push({ x: p.x, y: p.y, pressure: p.p, deltaMs: delta });
      a.points.push(p);
      this.drawWetSegment(a, a.last, p);
      a.last = p;
      this.stats.points++;
    }
    this.queueFlush();
  }

  private up(e: PointerEvent): void {
    if (this.erasing && e.pointerId === this.erasing.pointerId) { this.erasing = null; return; }
    const a = this.active;
    if (!a || e.pointerId !== a.pointerId) return;
    this.finish(a, false, e.timeStamp);
  }

  private cancel(e: PointerEvent): void {
    if (this.erasing && e.pointerId === this.erasing.pointerId) { this.erasing = null; return; }
    const a = this.active;
    if (!a || e.pointerId !== a.pointerId) return;
    this.finish(a, true, e.timeStamp);
  }

  private finish(a: ActiveStroke, cancelled: boolean, at: number): void {
    this.flush();
    this.active = null;
    const young = a.points.length < CANCEL_MIN_POINTS || at - a.firstDownAt <= CANCEL_MIN_MS;
    if (cancelled && young) {
      this.sink.sendInk(this.sink.encoder.strokeCancel(a.id), a.key, 0);
      this.stats.cancelled++;
      this.clearWet();
      return;
    }
    this.sink.sendInk(this.sink.encoder.strokeCommit(a.id, a.sent), a.key, 0);
    this.stats.committed++;
    this.commitLocal(a);
  }

  // -- wire -------------------------------------------------------------------

  private queueFlush(): void {
    if (this.rafQueued) return;
    this.rafQueued = true;
    requestAnimationFrame(() => { this.rafQueued = false; this.flush(); });
  }

  /** One STROKE_CHUNK per animation frame per active stroke, with the bufferedAmount policy of ARCHITECTURE 3.4. */
  private flush(): void {
    const a = this.active;
    if (!a || a.pending.length === 0) return;
    const bp = this.sink.backpressure();
    if (bp === "hold" && a.pending.length < MAX_POINTS_PER_CHUNK) { this.queueFlush(); return; }
    if (bp === "thin" && a.pending.length > 2) {
      const thinned: WirePoint[] = [];
      for (let i = 0; i < a.pending.length; i++) {
        const pt = a.pending[i];
        if (pt && (i % 2 === 0 || i === a.pending.length - 1)) thinned.push(pt);
      }
      this.stats.thinned += a.pending.length - thinned.length;
      a.pending = thinned;
    }
    while (a.pending.length > 0) {
      const batch = a.pending.splice(0, MAX_POINTS_PER_CHUNK);
      this.sink.sendInk(this.sink.encoder.strokeChunk(a.id, batch), a.key, batch.length);
      a.sent += batch.length;
    }
  }

  // -- eraser -----------------------------------------------------------------

  private eraseSegment(from: LocalPoint, to: LocalPoint): void {
    const hit: LocalStroke[] = [];
    const kept: LocalStroke[] = [];
    const visible = this.committed.slice(0, this.visible);
    for (const s of visible) {
      const reach = ERASER_RADIUS + strokeWidth(s.baseWidth, 1) / 2;
      if (strokeHitsSegment(s, from, to, reach)) hit.push(s);
      else kept.push(s);
    }
    const ids = hit.map((s) => uuidFromHex(s.key));
    this.sink.sendInk(this.sink.encoder.erase(from.x, from.y, to.x, to.y, ERASER_RADIUS, ids), "", 0);
    this.stats.erases++;
    if (hit.length > 0) {
      // Erased strokes leave the local list; the Mac's hit test is authoritative and STATE depths follow.
      this.committed = kept;
      this.visible = kept.length;
      this.redraw();
      this.onChange?.();
    }
  }

  // -- drawing ----------------------------------------------------------------

  private setup(ctx: CanvasRenderingContext2D): void {
    ctx.setTransform(this.scale, 0, 0, this.scale, 0, 0);
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
  }

  private drawWetDot(a: ActiveStroke, p: LocalPoint): void {
    const ctx = a.tool === "highlighter" ? this.wctx : this.ictx;
    this.setup(ctx);
    ctx.fillStyle = cssColor(a.color, a.tool === "highlighter" ? 1 : undefined);
    ctx.beginPath();
    ctx.arc(p.x, p.y, strokeWidth(a.baseWidth, p.p) / 2, 0, Math.PI * 2);
    ctx.fill();
  }

  private drawWetSegment(a: ActiveStroke, from: LocalPoint, to: LocalPoint): void {
    // The wet layer carries the highlighter opaque (its element is 50 percent translucent in CSS) so
    // overlapping segments do not darken; the pen goes straight to the ink layer.
    const ctx = a.tool === "highlighter" ? this.wctx : this.ictx;
    this.setup(ctx);
    ctx.strokeStyle = cssColor(a.color, a.tool === "highlighter" ? 1 : undefined);
    ctx.lineWidth = a.tool === "highlighter" ? a.baseWidth : strokeWidth(a.baseWidth, (from.p + to.p) / 2);
    ctx.beginPath();
    ctx.moveTo(from.x, from.y);
    ctx.lineTo(to.x, to.y);
    ctx.stroke();
  }

  private clearWet(): void {
    this.wctx.setTransform(1, 0, 0, 1, 0, 0);
    this.wctx.clearRect(0, 0, this.wet.width, this.wet.height);
  }

  private commitLocal(a: ActiveStroke): void {
    const stroke: LocalStroke = { key: a.key, tool: a.tool, color: a.color, baseWidth: a.baseWidth, points: a.points };
    // A new stroke after an undo discards the redo tail, as the Mac does.
    this.committed = this.committed.slice(0, this.visible);
    this.committed.push(stroke);
    this.visible = this.committed.length;
    if (a.tool === "highlighter") {
      this.clearWet();
      this.drawHighlighter(stroke);
    } else if (a.points.length === 1) {
      this.drawPen(stroke);
    }
    this.onChange?.();
  }

  private drawHighlighter(s: LocalStroke): void {
    const ctx = this.hctx;
    this.setup(ctx);
    ctx.strokeStyle = cssColor(s.color, 1);
    ctx.globalAlpha = ((s.color >>> 24) & 0xff) / 255;
    ctx.lineWidth = s.baseWidth;
    ctx.beginPath();
    const first = s.points[0];
    if (!first) return;
    if (s.points.length === 1) {
      ctx.fillStyle = cssColor(s.color, 1);
      ctx.arc(first.x, first.y, s.baseWidth / 2, 0, Math.PI * 2);
      ctx.fill();
    } else {
      ctx.moveTo(first.x, first.y);
      for (let i = 1; i < s.points.length; i++) {
        const q = s.points[i];
        if (q) ctx.lineTo(q.x, q.y);
      }
      ctx.stroke();   // one stroke() call: overlaps inside the path never double the alpha
    }
    ctx.globalAlpha = 1;
  }

  private drawPen(s: LocalStroke): void {
    const ctx = this.ictx;
    this.setup(ctx);
    ctx.strokeStyle = cssColor(s.color);
    ctx.fillStyle = cssColor(s.color);
    const first = s.points[0];
    if (!first) return;
    if (s.points.length === 1) {
      ctx.beginPath();
      ctx.arc(first.x, first.y, strokeWidth(s.baseWidth, first.p) / 2, 0, Math.PI * 2);
      ctx.fill();
      return;
    }
    for (let i = 1; i < s.points.length; i++) {
      const a = s.points[i - 1];
      const b = s.points[i];
      if (!a || !b) continue;
      ctx.lineWidth = strokeWidth(s.baseWidth, (a.p + b.p) / 2);
      ctx.beginPath();
      ctx.moveTo(a.x, a.y);
      ctx.lineTo(b.x, b.y);
      ctx.stroke();
    }
  }

  redraw(): void {
    for (const [c, ctx] of [[this.highlight, this.hctx], [this.ink, this.ictx]] as const) {
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, c.width, c.height);
    }
    for (const s of this.committed.slice(0, this.visible)) {
      if (s.tool === "highlighter") this.drawHighlighter(s);
      else this.drawPen(s);
    }
    // A pen stroke still on the glass lives on the ink layer too; keep what was drawn so far.
    const a = this.active;
    if (a && a.tool !== "highlighter") {
      this.drawPen({ key: a.key, tool: a.tool, color: a.color, baseWidth: a.baseWidth, points: a.points });
    }
  }
}

export function toolCode(tool: Tool): 0 | 1 | 2 {
  return tool === "pen" ? 0 : tool === "highlighter" ? 1 : 2;
}

/** ARGB u32 to a CSS colour; `alphaOverride` forces the alpha (1 = opaque). */
export function cssColor(argb: number, alphaOverride?: number): string {
  const a = alphaOverride ?? ((argb >>> 24) & 0xff) / 255;
  const r = (argb >>> 16) & 0xff;
  const g = (argb >>> 8) & 0xff;
  const b = argb & 0xff;
  return `rgba(${r}, ${g}, ${b}, ${a.toFixed(3)})`;
}

function uuidFromHex(hex: string): Uint8Array {
  const out = new Uint8Array(16);
  for (let i = 0; i < 16; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
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

/** True when any point of the stroke is within `reach` of the eraser segment, or any stroke segment passes within reach of the eraser points. */
export function strokeHitsSegment(s: LocalStroke, from: LocalPoint, to: LocalPoint, reach: number): boolean {
  for (const q of s.points) {
    if (pointSegmentDistance(q, from, to) <= reach) return true;
  }
  for (let i = 1; i < s.points.length; i++) {
    const a = s.points[i - 1];
    const b = s.points[i];
    if (!a || !b) continue;
    if (pointSegmentDistance(from, a, b) <= reach || pointSegmentDistance(to, a, b) <= reach) return true;
  }
  return false;
}
