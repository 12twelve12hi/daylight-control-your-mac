// The chip element: binds chip-state.ts to the DOM, counts down locally between STATE messages,
// breathes the amber dot in phase with the Mac divider, and turns tap / long press into actions.

import { LONG_PRESS_MS, breath, chipView, type ChipView, type ConnectionPhase } from "./chip-state.js";
import type { StateReport } from "./protocol.js";

export interface ChipActions {
  togglePin(): void;
  returnNow(): void;
  retry(): void;
  explain(): void;
}

export class Chip {
  private phase: ConnectionPhase = "disconnected";
  private state: StateReport | null = null;
  private stateAt = 0;
  private preWarningSince: number | null = null;
  private view: ChipView = chipView("disconnected", null);
  private readonly label: HTMLSpanElement;
  private readonly dot: HTMLSpanElement;
  private pressTimer: number | null = null;
  private longPressFired = false;
  private pressedPointer: number | null = null;
  private breathFrame: number | null = null;
  /** Diagnostics for tests. */
  readonly stats = { taps: 0, longPresses: 0 };

  constructor(readonly el: HTMLElement, private readonly actions: ChipActions, private readonly now: () => number = () => performance.now()) {
    el.innerHTML = "";
    this.dot = document.createElement("span");
    this.dot.className = "dot";
    this.label = document.createElement("span");
    this.label.className = "label";
    el.append(this.dot, this.label);
    el.addEventListener("pointerdown", (e) => this.down(e));
    el.addEventListener("pointerup", (e) => this.up(e));
    el.addEventListener("pointercancel", (e) => this.cancel(e));
    el.addEventListener("pointerleave", (e) => this.cancel(e));
    el.addEventListener("contextmenu", (e) => e.preventDefault());
    window.setInterval(() => this.render(), 250);
    this.render();
  }

  get current(): ChipView {
    return this.view;
  }

  setPhase(phase: ConnectionPhase): void {
    this.phase = phase;
    if (phase !== "live") this.state = null;
    this.render();
  }

  setState(state: StateReport): void {
    this.state = state;
    this.stateAt = this.now();
    if (state.preWarning) {
      if (this.preWarningSince === null) this.preWarningSince = this.stateAt;
    } else {
      this.preWarningSince = null;
    }
    this.render();
  }

  /** Breath weight right now (0 when not breathing). */
  breathWeight(): number {
    if (this.preWarningSince === null || !this.view.breathing) return 0;
    return breath((this.now() - this.preWarningSince) / 1000);
  }

  private render(): void {
    const elapsed = this.state ? this.now() - this.stateAt : 0;
    this.view = chipView(this.phase, this.state, elapsed);
    if (this.el.dataset.state !== this.view.kind) this.el.dataset.state = this.view.kind;
    if (this.label.textContent !== this.view.text) this.label.textContent = this.view.text;
    this.dot.hidden = !this.view.dot;
    if (this.view.breathing) {
      if (this.breathFrame === null) this.animateBreath();
    } else if (this.breathFrame !== null) {
      cancelAnimationFrame(this.breathFrame);
      this.breathFrame = null;
      this.dot.style.opacity = "";
      this.dot.style.transform = "";
    }
  }

  private animateBreath(): void {
    const w = this.breathWeight();
    this.dot.style.opacity = (0.35 + 0.65 * w).toFixed(3);
    this.dot.style.transform = `scale(${(0.8 + 0.5 * w).toFixed(3)})`;
    this.breathFrame = requestAnimationFrame(() => this.animateBreath());
  }

  private down(e: PointerEvent): void {
    if (this.pressedPointer !== null) return;
    e.preventDefault();
    this.pressedPointer = e.pointerId;
    this.longPressFired = false;
    try { this.el.setPointerCapture(e.pointerId); } catch { /* not fatal */ }
    if (this.view.longPressReturns) {
      this.pressTimer = window.setTimeout(() => {
        this.pressTimer = null;
        this.longPressFired = true;
        this.stats.longPresses++;
        this.el.classList.add("pressed");
        this.actions.returnNow();
      }, LONG_PRESS_MS);
    }
  }

  private up(e: PointerEvent): void {
    if (e.pointerId !== this.pressedPointer) return;
    this.pressedPointer = null;
    this.el.classList.remove("pressed");
    if (this.pressTimer !== null) { clearTimeout(this.pressTimer); this.pressTimer = null; }
    if (this.longPressFired) return;
    this.stats.taps++;
    switch (this.view.tap) {
      case "pin": this.actions.togglePin(); break;
      case "retry": this.actions.retry(); break;
      case "explain": this.actions.explain(); break;
      case "none": break;
    }
  }

  private cancel(e: PointerEvent): void {
    if (e.pointerId !== this.pressedPointer) return;
    this.pressedPointer = null;
    this.el.classList.remove("pressed");
    if (this.pressTimer !== null) { clearTimeout(this.pressTimer); this.pressTimer = null; }
  }
}
