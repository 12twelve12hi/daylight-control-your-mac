import type { Stroke } from "@twelve/protocol";

export interface InkTemplate {
  /** Faint headings drawn on the page, in fractions of the page height. */
  headings: { text: string; y: number }[];
}

export const TEMPLATES: Record<string, InkTemplate> = {
  plan: {
    headings: [
      { text: "Intention — what is this session for?", y: 0.06 },
      { text: "Priorities — up to three", y: 0.36 },
      { text: "To-do", y: 0.68 },
    ],
  },
  reply: { headings: [{ text: "Your answer", y: 0.06 }] },
  checkin: {
    headings: [
      { text: "Where am I?", y: 0.06 },
      { text: "What happened?", y: 0.3 },
      { text: "Stuck on?", y: 0.54 },
      { text: "Next step", y: 0.78 },
    ],
  },
  wrapup: {
    headings: [
      { text: "What got done", y: 0.06 },
      { text: "What's next", y: 0.5 },
    ],
  },
};

export type Tool = "pen" | "eraser";

interface Pt {
  x: number;
  y: number;
  p: number;
  t: number;
}

/**
 * A pressure-aware ink canvas built on pointer events.
 * - Pen input always wins; touch is ignored for a moment after any pen contact (palm rejection).
 * - Strokes are kept as data so the page can be re-rendered, undone and exported.
 */
export class InkCanvas {
  readonly el: HTMLCanvasElement;
  private ctx: CanvasRenderingContext2D;
  private strokes: Stroke[] = [];
  private redoStack: Stroke[] = [];
  private current: Pt[] | null = null;
  private activePointer: number | null = null;
  private lastPenAt = 0;
  private dpr = Math.max(1, Math.min(3, window.devicePixelRatio || 1));
  private width = 0;
  private height = 0;
  private ro: ResizeObserver;
  tool: Tool = "pen";
  penWidth = 2.6;
  /** When true, fingers never draw (the Daylight has a pen; palms happen). */
  penOnly = false;
  onChange: (() => void) | null = null;

  constructor(
    private readonly container: HTMLElement,
    private template: InkTemplate,
  ) {
    this.el = document.createElement("canvas");
    this.el.className = "ink";
    this.el.setAttribute("aria-label", "Handwriting area");
    container.appendChild(this.el);
    this.ctx = this.el.getContext("2d", { desynchronized: true }) ?? this.el.getContext("2d")!;
    this.ro = new ResizeObserver(() => this.resize());
    this.ro.observe(container);
    this.resize();
    this.bind();
  }

  destroy() {
    this.ro.disconnect();
    this.el.remove();
  }

  setTemplate(t: InkTemplate) {
    this.template = t;
    this.redraw();
  }

  get isEmpty() {
    return this.strokes.length === 0;
  }

  get strokeCount() {
    return this.strokes.length;
  }

  // -- geometry -------------------------------------------------------------

  private resize() {
    const r = this.container.getBoundingClientRect();
    const w = Math.max(1, Math.floor(r.width));
    const h = Math.max(1, Math.floor(r.height));
    if (w === this.width && h === this.height) return;
    this.width = w;
    this.height = h;
    this.el.width = Math.floor(w * this.dpr);
    this.el.height = Math.floor(h * this.dpr);
    this.el.style.width = `${w}px`;
    this.el.style.height = `${h}px`;
    this.redraw();
  }

  private pointFromEvent(e: PointerEvent): Pt {
    const r = this.el.getBoundingClientRect();
    const p = e.pointerType === "pen" ? clamp(e.pressure || 0.5, 0.05, 1) : 0.5;
    return { x: e.clientX - r.left, y: e.clientY - r.top, p, t: e.timeStamp };
  }

  // -- input ----------------------------------------------------------------

  private bind() {
    const el = this.el;
    el.style.touchAction = "none";
    el.addEventListener("pointerdown", (e) => this.down(e));
    el.addEventListener("pointermove", (e) => this.move(e));
    el.addEventListener("pointerup", (e) => this.up(e));
    el.addEventListener("pointercancel", (e) => this.up(e));
    el.addEventListener("pointerleave", (e) => this.up(e));
    el.addEventListener("contextmenu", (e) => e.preventDefault());
  }

  private accepts(e: PointerEvent): boolean {
    if (e.pointerType === "pen") {
      this.lastPenAt = e.timeStamp;
      return true;
    }
    if (e.pointerType === "touch") {
      if (this.penOnly) return false;
      // Palm: a finger/palm arriving shortly after (or during) pen contact.
      if (e.timeStamp - this.lastPenAt < 1500) return false;
      return true;
    }
    return true; // mouse, for desktop testing
  }

  private down(e: PointerEvent) {
    if (!this.accepts(e)) return;
    if (this.activePointer !== null) return; // one stroke at a time
    // The pen's side button (or a right-click) erases.
    const erasing = this.tool === "eraser" || e.button === 5 || e.buttons === 32 || e.button === 2;
    e.preventDefault();
    this.activePointer = e.pointerId;
    try {
      this.el.setPointerCapture(e.pointerId);
    } catch {
      /* not fatal */
    }
    const pt = this.pointFromEvent(e);
    if (erasing) {
      this.current = null;
      this.eraseAt(pt);
      (this as { erasingPointer?: boolean }).erasingPointer = true;
      return;
    }
    (this as { erasingPointer?: boolean }).erasingPointer = false;
    this.current = [pt];
    this.redoStack = [];
  }

  private move(e: PointerEvent) {
    if (e.pointerId !== this.activePointer) return;
    e.preventDefault();
    const events = typeof e.getCoalescedEvents === "function" ? e.getCoalescedEvents() : [e];
    if ((this as { erasingPointer?: boolean }).erasingPointer) {
      for (const ce of events) this.eraseAt(this.pointFromEvent(ce));
      return;
    }
    if (!this.current) return;
    for (const ce of events) {
      const pt = this.pointFromEvent(ce);
      const prev = this.current[this.current.length - 1]!;
      this.current.push(pt);
      this.drawSegment(this.ctx, prev, pt, this.penWidth, "#111111");
    }
  }

  private up(e: PointerEvent) {
    if (e.pointerId !== this.activePointer) return;
    this.activePointer = null;
    try {
      this.el.releasePointerCapture(e.pointerId);
    } catch {
      /* ignore */
    }
    if ((this as { erasingPointer?: boolean }).erasingPointer) {
      (this as { erasingPointer?: boolean }).erasingPointer = false;
      this.onChange?.();
      return;
    }
    if (!this.current) return;
    const pts = this.current;
    this.current = null;
    if (pts.length === 1) {
      // A dot.
      const p = pts[0]!;
      pts.push({ ...p, x: p.x + 0.4, y: p.y + 0.4 });
      this.drawSegment(this.ctx, pts[0]!, pts[1]!, this.penWidth, "#111111");
    }
    this.strokes.push({ points: pts, width: this.penWidth, color: "#111111", eraser: false });
    this.onChange?.();
  }

  private eraseAt(pt: Pt) {
    const r = 14;
    const before = this.strokes.length;
    this.strokes = this.strokes.filter((s) => !s.points.some((q) => (q.x - pt.x) ** 2 + (q.y - pt.y) ** 2 < r * r));
    if (this.strokes.length !== before) this.redraw();
  }

  // -- drawing --------------------------------------------------------------

  private drawSegment(ctx: CanvasRenderingContext2D, a: Pt, b: Pt, base: number, color: string, scale = this.dpr) {
    ctx.save();
    ctx.scale(scale, scale);
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    ctx.strokeStyle = color;
    ctx.lineWidth = base * (0.55 + 0.9 * ((a.p + b.p) / 2));
    ctx.beginPath();
    ctx.moveTo(a.x, a.y);
    ctx.lineTo(b.x, b.y);
    ctx.stroke();
    ctx.restore();
  }

  private drawTemplate(ctx: CanvasRenderingContext2D, w: number, h: number, scale: number) {
    ctx.save();
    ctx.scale(scale, scale);
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, w, h);
    // Faint ruled lines
    ctx.strokeStyle = "rgba(0,0,0,0.06)";
    ctx.lineWidth = 1;
    const gap = 44;
    for (let y = gap; y < h; y += gap) {
      ctx.beginPath();
      ctx.moveTo(24, y + 0.5);
      ctx.lineTo(w - 24, y + 0.5);
      ctx.stroke();
    }
    ctx.fillStyle = "rgba(0,0,0,0.38)";
    ctx.font = `500 17px system-ui, -apple-system, "Segoe UI", sans-serif`;
    ctx.textBaseline = "alphabetic";
    for (const hd of this.template.headings) {
      ctx.fillText(hd.text, 24, Math.round(hd.y * h) + 20);
    }
    ctx.restore();
  }

  private redraw() {
    const ctx = this.ctx;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.el.width, this.el.height);
    this.drawTemplate(ctx, this.width, this.height, this.dpr);
    for (const s of this.strokes) this.drawStroke(ctx, s, this.dpr);
  }

  private drawStroke(ctx: CanvasRenderingContext2D, s: Stroke, scale: number) {
    for (let i = 1; i < s.points.length; i++) this.drawSegment(ctx, s.points[i - 1]!, s.points[i]!, s.width, s.color, scale);
  }

  // -- commands -------------------------------------------------------------

  undo() {
    const s = this.strokes.pop();
    if (s) this.redoStack.push(s);
    this.redraw();
    this.onChange?.();
  }

  redo() {
    const s = this.redoStack.pop();
    if (s) this.strokes.push(s);
    this.redraw();
    this.onChange?.();
  }

  clear() {
    this.strokes = [];
    this.redoStack = [];
    this.redraw();
    this.onChange?.();
  }

  getStrokes(): Stroke[] {
    return this.strokes.map((s) => ({ ...s, points: s.points.map((p) => ({ ...p })) }));
  }

  /**
   * Export the page as a base64 PNG (no data: prefix), white background,
   * template headings included so the reader knows which section is which.
   * The long side is capped so the image stays cheap to send and read.
   */
  toPNG(maxSide = 1568): string {
    const scale = Math.min(2, maxSide / Math.max(this.width, this.height));
    const off = document.createElement("canvas");
    off.width = Math.round(this.width * scale);
    off.height = Math.round(this.height * scale);
    const ctx = off.getContext("2d")!;
    this.drawTemplate(ctx, this.width, this.height, scale);
    for (const s of this.strokes) this.drawStroke(ctx, s, scale);
    return off.toDataURL("image/png").split(",")[1] ?? "";
  }
}

function clamp(v: number, lo: number, hi: number) {
  return Math.max(lo, Math.min(hi, v));
}
