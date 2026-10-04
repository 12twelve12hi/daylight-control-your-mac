// Pen-only ink canvas (SPEC D3, PROTOCOL 4, 6.3 to 6.8). Three stacked canvases over PaperBg:
// highlight (amber under the ink), ink, and a wet layer that receives the pointer events.
// Local rendering is a preview; the Mac is the source of truth (undo and redo follow STATE depths).
// The Laser tool sends LASER_POINT (PROTOCOL 6.9) instead: nothing drawn, no stroke, no undo.

import { clampPressure, strokeHitsSegment, strokeWidth, type LocalPoint } from "./geometry.js";
import { LASER_DECAY_S, LaserThrottle, laserIntensity, laserTakesSample, type LaserPoint } from "./laser.js";
import { Encoder, MAX_POINTS_PER_CHUNK, newUuid16, toHex, type WirePoint } from "./protocol.js";
import type { Tool } from "./tools.js";

export { clampPressure, pointSegmentDistance, strokeHitsSegment, strokeWidth, type LocalPoint } from "./geometry.js";

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
/** PROTOCOL 6.8: ERASE_STROKES carries at most this many ids (a hint; the Mac's hit test is authoritative). */
export const MAX_ERASE_IDS = 1024;
/**
 * A STATE whose depths predate a COMMIT this page just sent would make the fresh stroke vanish for one
 * message. While a commit is in flight such STATEs are skipped, but never more than this many in a row
 * without the Mac's total growing, so a Mac-side Clear in that window still lands within a second or two.
 */
export const STALE_STATE_RUN_LIMIT = 2;

export interface InkSink {
  readonly encoder: Encoder;
  /** Sends live, or rings while offline / pending. Returns true when it went out on a live socket. */
  sendInk(frame: ArrayBuffer, strokeKey: string, points: number): boolean;
  /** Meaningful now or never (the laser): sent while live, dropped otherwise. Returns true when it went out. */
  sendControl(frame: ArrayBuffer): boolean;
  isLive(): boolean;
  backpressure(): "ok" | "hold" | "thin";
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
  /** The ring dropped this stroke's frames while it was being flushed: restart it under a new id. */
  lost: boolean;
  /** Restarted after a ring drop: nothing drawn before the restart reached the Mac. */
  forgotten: boolean;
}

interface ActiveErase {
  pointerId: number;
  last: LocalPoint;
}

/** A pen contact that arrived with pressure 0 (LOOSE_ENDS D4): the stroke starts on its first pressured sample. */
interface ArmedContact {
  pointerId: number;
  timeStamp: number;
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
  /** Strokes that began on a pressured sample after a pressure-0 pointerdown. */
  armedStarts: number;
  /** STATE messages skipped because a COMMIT of ours was still in flight. */
  staleStates: number;
  /** Strokes removed from the page because the offline ring dropped them before they reached the Mac. */
  forgotten: number;
  /** First STATEs after a reconnect that showed the Mac had lost history (a relaunch); the page kept the newest. */
  historyLost: number;
  /** LASER_POINT messages that went out on a live socket. */
  laserPoints: number;
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
  private armed: ArmedContact | null = null;
  private rafQueued = false;
  private scale = 1;
  private readonly useRawUpdate: boolean;
  private inFlightCommits = 0;
  private staleRun = 0;
  private staleLastTotal = -1;
  /** COMMITs the ring replays on the socket just ACKed; consumed by the first STATE after it (null: none expected). */
  private replayCommits: number | null = null;
  private flushing = false;
  /** One LASER_POINT per animation frame, the newest point wins. */
  private readonly laser = new LaserThrottle((p) => this.sendLaser(p), (cb) => requestAnimationFrame(cb));
  tool: Tool = "pen";
  readonly stats: InkStats = { strokes: 0, points: 0, ignored: 0, committed: 0, cancelled: 0, erases: 0, rawUpdates: 0, coalesced: 0, restarted: 0, thinned: 0, armedStarts: 0, staleStates: 0, forgotten: 0, historyLost: 0, laserPoints: 0 };
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
   * STATE `undo_depth` / `redo_depth`. In the common case the local list and the Mac's list hold the same
   * strokes in the same order, so the first `undoDepth` are visible and the next `redoDepth` are the redo tail.
   * Departures from that rule: a STATE generated before the Mac saw a COMMIT of ours is skipped (see
   * STALE_STATE_RUN_LIMIT), and when the two lists differ in length they are aligned on their newest end, so
   * an undo still hides the stroke drawn last. The Mac holds more after a reload mid-session or strokes from
   * another client; it holds fewer after a relaunch (its history starts empty) or a loss the page could not
   * see. The suffix rule is a heuristic in mixed histories; the Mac never replays its canvas.
   */
  applyDepths(undoDepth: number, redoDepth: number): void {
    const macTotal = undoDepth + redoDepth;
    if (this.replayCommits !== null) {
      // The first STATE after ACK 0 predates the replay of the ring: the Mac's history plus the COMMITs in that
      // replay is what the Mac will hold. Fewer than this page holds means the Mac lost history (it relaunched):
      // keep the newest strokes, the ones the replay delivers, and treat its COMMITs as in flight.
      const ringed = this.replayCommits;
      this.replayCommits = null;
      if (macTotal + ringed < this.committed.length) {
        const n = ringed > 0 ? undoDepth + ringed : macTotal;   // a COMMIT clears the Mac's redo tail
        this.committed = this.committed.slice(this.committed.length - Math.min(n, this.committed.length));
        this.visible = ringed > 0 ? this.committed.length : Math.min(undoDepth, this.committed.length);
        this.inFlightCommits = ringed;
        this.staleRun = 0;
        this.staleLastTotal = -1;
        this.stats.historyLost++;
        this.redraw();
        this.onChange?.();
        return;
      }
    }
    if (this.inFlightCommits > 0) {
      if (undoDepth >= this.visible) {
        this.inFlightCommits = 0;
        this.staleRun = 0;
        this.staleLastTotal = -1;
      } else {
        // Stale: the Mac has not counted our newest COMMIT yet. Judged by the undo depth, not the total: after an
        // Undo the Mac's redo tail can make an old total look current. Skip it unless the total stopped growing
        // for too long (a Mac-side Clear, Undo or erase during the window); then the ordinary rule applies.
        this.staleRun = macTotal > this.staleLastTotal ? 1 : this.staleRun + 1;
        this.staleLastTotal = macTotal;
        if (this.staleRun <= STALE_STATE_RUN_LIMIT) {
          this.stats.staleStates++;
          return;
        }
        this.inFlightCommits = 0;
        this.staleRun = 0;
        this.staleLastTotal = -1;
      }
    }
    const total = this.committed.length;
    let visible: number;
    let from = 0;
    if (macTotal > total) {
      visible = Math.max(0, total - redoDepth);
    } else if (macTotal < total) {
      // The oldest local strokes are the ones the Mac does not hold; the newest went through the socket last.
      from = total - macTotal;
      visible = undoDepth;
    } else {
      visible = undoDepth;
    }
    const changed = visible !== this.visible || from > 0;
    this.visible = visible;
    if (from > 0) this.committed = this.committed.slice(from);
    if (changed) this.redraw();
  }

  /**
   * The socket was just ACKed and the ring is about to replay `ringedCommits` COMMITs: the next STATE tells
   * whether the Mac still holds the history this page shows (see applyDepths).
   */
  expectReplay(ringedCommits: number): void {
    this.replayCommits = ringedCommits;
  }

  /**
   * The phase became live and the ring is about to replay in order: an open stroke whose START was ringed is
   * now on this connection, so a later drop must restart it (SPEC D37) like a stroke that started live.
   */
  markLive(): void {
    if (this.active) this.active.startedLive = true;
  }

  /**
   * The offline ring dropped this stroke's frames (point or frame budget): the Mac will never hold it, so the
   * page lets it go too, or the depths in STATE would hide the wrong strokes. A stroke still on the glass is
   * restarted under a new id from its unsent points; what was dropped leaves the screen.
   */
  forget(key: string): void {
    const a = this.active;
    if (a && a.key === key) {
      a.lost = true;
      if (!this.flushing) { this.restartLost(a); this.queueFlush(); }
      return;
    }
    const i = this.committed.findIndex((s) => s.key === key);
    if (i < 0) return;
    this.committed.splice(i, 1);
    if (i < this.visible) this.visible--;
    // Its COMMIT was in the ring, so it was counted in flight.
    if (this.inFlightCommits > 0) this.inFlightCommits--;
    this.stats.forgotten++;
    this.redraw();
    this.onChange?.();
  }

  /** Clear and New page: both layers and the local list. The Mac does the same on its side. */
  clearLocal(): void {
    this.committed = [];
    this.visible = 0;
    this.inFlightCommits = 0;
    this.staleRun = 0;
    this.staleLastTotal = -1;
    this.replayCommits = null;
    this.redraw();
    this.onChange?.();
  }

  /**
   * Called when the connection that carried the open stroke's STROKE_START is gone: the Mac committed
   * that stroke as it stood (SPEC D37), so the rest of the glass contact becomes a new stroke. The points
   * not yet sent stay with the contact under the new id (nothing for the old id goes into the ring, which
   * would reach the Mac after its COMMIT and be dropped); their delta_ms are rebased so the restarted
   * stroke starts at 0, and the new START is ringed ahead of them.
   */
  restartOpenStroke(): void {
    const a = this.active;
    if (!a || !a.startedLive) return;
    a.forgotten = false;   // the Mac committed what it had; the restart continues it
    this.rekey(a);
  }

  /** The ring dropped the open stroke: the points not yet sent start it again; the dropped part leaves the screen. */
  private restartLost(a: ActiveStroke): void {
    a.lost = false;
    a.forgotten = true;
    a.points = a.pending.length > 0 ? a.points.slice(Math.max(0, a.points.length - a.pending.length)) : [];
    this.stats.forgotten++;
    this.rekey(a);
    if (a.tool === "highlighter") {
      this.clearWet();
      for (let i = 1; i < a.points.length; i++) this.drawWetSegment(a, a.points[i - 1]!, a.points[i]!);
    }
    this.redraw();
  }

  /** A new id and a new STROKE_START for the open stroke; its pending points are rebased to delta_ms 0. */
  private rekey(a: ActiveStroke): void {
    a.id = newUuid16();
    a.key = toHex(a.id);
    a.sent = 0;
    const first = a.pending[0];
    if (first) {
      const base = first.deltaMs;
      a.startedAt += base;
      for (const pt of a.pending) pt.deltaMs -= base;
      a.lastDelta = a.pending[a.pending.length - 1]?.deltaMs ?? 0;
    } else {
      a.startedAt = -1;   // the next sample becomes the first point (delta_ms 0)
      a.lastDelta = 0;
    }
    // A START with pressure 0 is dropped by the Mac (PROTOCOL 6.3); a lifted-but-captured pen reports 0.
    const pressure = first && first.pressure > 0 ? first.pressure : a.last.p > 0 ? a.last.p : 0.5;
    a.startedLive = this.sink.sendInk(this.sink.encoder.strokeStart(a.id, toolCode(a.tool), a.color, a.baseWidth, pressure), a.key, 0);
    this.stats.restarted++;
    if (a.pending.length > 0) this.queueFlush();
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
    this.armed = null;
    if (laserTakesSample(this.tool, this.active !== null || this.erasing !== null)) {
      if (this.pointLaser(e)) e.preventDefault();
      else this.stats.ignored++;
      return;
    }
    // Fingers and palms never draw and never engage; a pen with pressure 0 is a side button in the air, or a
    // digitizer whose first contact sample carries no pressure yet (LOOSE_ENDS D4): the contact is armed and
    // becomes a stroke on its first pressured sample.
    if (e.pointerType !== "pen" || e.buttons === 0 || clampPressure(e.pressure) <= 0) {
      this.stats.ignored++;
      if (e.pointerType === "pen" && e.buttons !== 0 && !this.active && !this.erasing) {
        this.armed = { pointerId: e.pointerId, timeStamp: e.timeStamp };
      }
      return;
    }
    if (this.active || this.erasing) return;   // one contact at a time
    e.preventDefault();
    this.beginContact(e, this.canvasPoint(e), e.timeStamp);
  }

  /** Starts an erase or a stroke at `p`; `firstDownAt` is the pointerdown time (the 80 ms cancel rule). */
  private beginContact(e: PointerEvent, p: LocalPoint, firstDownAt: number): void {
    try { this.wet.setPointerCapture(e.pointerId); } catch { /* not fatal */ }
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
      firstDownAt,
      lastDelta: 0,
      last: p,
      points: [p],
      pending: [{ x: p.x, y: p.y, pressure: p.p, deltaMs: 0 }],
      sent: 0,
      startedLive: false,
      lost: false,
      forgotten: false,
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
    if (this.useRawUpdate && (this.active || this.erasing)) return;   // raw updates already carried these samples
    let events: PointerEvent[] = [e];
    if (typeof e.getCoalescedEvents === "function") {
      const c = e.getCoalescedEvents();
      if (c.length > 0) { events = c; this.stats.coalesced += c.length; }
    }
    this.sample(e, events);
  }

  private sample(e: PointerEvent, samples: readonly PointerEvent[]): void {
    if (e.pointerType !== "pen") return;
    if (laserTakesSample(this.tool, this.active !== null || this.erasing !== null)) {
      // Only the newest sample matters: the throttle keeps one point per frame anyway.
      this.pointLaser(samples[samples.length - 1] ?? e);
      return;
    }
    let events: readonly PointerEvent[] = samples;
    const armed = this.armed;
    if (armed && !this.active && !this.erasing) {
      if (e.pointerId !== armed.pointerId || e.buttons === 0) return;
      // The first sample with pressure starts the contact; everything after it is ordinary motion.
      for (let i = 0; i < events.length; i++) {
        const ev = events[i]!;
        const p = this.canvasPoint(ev);
        if (p.p <= 0) continue;
        this.armed = null;
        this.beginContact(ev, p, armed.timeStamp);
        this.stats.armedStarts++;
        events = events.slice(i + 1);
        break;
      }
      if (this.armed) return;
    }
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
    if (this.armed && e.pointerId === this.armed.pointerId) this.armed = null;
    if (this.erasing && e.pointerId === this.erasing.pointerId) { this.erasing = null; return; }
    const a = this.active;
    if (!a || e.pointerId !== a.pointerId) return;
    this.finish(a, false, e.timeStamp);
  }

  private cancel(e: PointerEvent): void {
    if (this.armed && e.pointerId === this.armed.pointerId) this.armed = null;
    if (this.erasing && e.pointerId === this.erasing.pointerId) { this.erasing = null; return; }
    const a = this.active;
    if (!a || e.pointerId !== a.pointerId) return;
    this.finish(a, true, e.timeStamp);
  }

  private finish(a: ActiveStroke, cancelled: boolean, at: number): void {
    // The tail goes out whatever the backpressure says: a COMMIT must follow every point it counts.
    this.flush(true);
    this.active = null;
    const young = a.points.length < CANCEL_MIN_POINTS || at - a.firstDownAt <= CANCEL_MIN_MS;
    // Restarted after a ring drop and lifted before a point went out under the new id: nothing of it reaches the Mac.
    const empty = a.forgotten && a.sent === 0;
    if ((cancelled && young) || empty) {
      this.sink.sendInk(this.sink.encoder.strokeCancel(a.id), a.key, 0);
      if (!empty) this.stats.cancelled++;
      // The wet dot or segment went to the ink layer (pen) or the wet layer (highlighter): rebuild both from the model.
      this.clearWet();
      this.redraw();
      return;
    }
    // The local list first: if ringing the COMMIT makes the ring drop this very stroke, forget() finds it there.
    this.stats.committed++;
    this.inFlightCommits++;
    this.commitLocal(a);
    this.sink.sendInk(this.sink.encoder.strokeCommit(a.id, a.sent), a.key, 0);
  }

  // -- laser ------------------------------------------------------------------

  /** Offers a laser point for a pen sample (contact or hover); false for anything that is not a pen. */
  private pointLaser(e: PointerEvent): boolean {
    const intensity = laserIntensity(e);
    if (intensity === null) return false;
    const p = this.canvasPoint(e);
    this.laser.offer({ x: p.x, y: p.y, intensity });
    return true;
  }

  /** The throttle's frame callback. A point offered just before another tool was selected is let go. */
  private sendLaser(p: LaserPoint): void {
    if (this.tool !== "laser") return;
    if (this.sink.sendControl(this.sink.encoder.laserPoint(p.x, p.y, p.intensity, LASER_DECAY_S))) this.stats.laserPoints++;
  }

  // -- wire -------------------------------------------------------------------

  private queueFlush(): void {
    if (this.rafQueued) return;
    this.rafQueued = true;
    requestAnimationFrame(() => { this.rafQueued = false; this.flush(); });
  }

  /**
   * One STROKE_CHUNK per animation frame per active stroke, with the bufferedAmount policy of ARCHITECTURE 3.4.
   * `force` (the end of a stroke) skips the hold branch; thinning still applies.
   */
  private flush(force = false): void {
    const a = this.active;
    if (!a || a.pending.length === 0) return;
    const bp = this.sink.backpressure();
    if (!force && bp === "hold" && a.pending.length < MAX_POINTS_PER_CHUNK) { this.queueFlush(); return; }
    if (bp === "thin" && a.pending.length > 2) {
      const thinned: WirePoint[] = [];
      for (let i = 0; i < a.pending.length; i++) {
        const pt = a.pending[i];
        if (pt && (i % 2 === 0 || i === a.pending.length - 1)) thinned.push(pt);
      }
      this.stats.thinned += a.pending.length - thinned.length;
      a.pending = thinned;
    }
    this.flushing = true;
    try {
      while (a.pending.length > 0) {
        const batch = a.pending.splice(0, MAX_POINTS_PER_CHUNK);
        this.sink.sendInk(this.sink.encoder.strokeChunk(a.id, batch), a.key, batch.length);
        // Ringing this chunk overflowed the ring and it dropped this stroke, the chunk included: go on under a new id.
        if (a.lost) { this.restartLost(a); continue; }
        a.sent += batch.length;
      }
    } finally {
      this.flushing = false;
    }
  }

  // -- eraser -----------------------------------------------------------------

  private eraseSegment(from: LocalPoint, to: LocalPoint): void {
    const hit: LocalStroke[] = [];
    const kept: LocalStroke[] = [];
    // Only visible strokes can be erased; the redo tail stays as it is (the Mac erases from its visible list too).
    for (const s of this.committed.slice(0, this.visible)) {
      if (strokeHitsSegment(s, from, to, ERASER_RADIUS)) hit.push(s);
      else kept.push(s);
    }
    const ids = hit.slice(0, MAX_ERASE_IDS).map((s) => uuidFromHex(s.key));
    const frame = this.sink.encoder.erase(from.x, from.y, to.x, to.y, ERASER_RADIUS, ids);
    this.stats.erases++;
    if (hit.length > 0) {
      // Erased strokes leave the local list; the Mac's hit test is authoritative and STATE depths follow.
      const redoTail = this.committed.slice(this.visible);
      this.committed = kept.concat(redoTail);
      this.visible = kept.length;
      this.redraw();
      this.onChange?.();
    }
    // Sent after the local change: ringing it may make the ring drop (and the page forget) an older stroke.
    this.sink.sendInk(frame, "", 0);
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
