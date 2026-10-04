// Laser tool (LOOSE_ENDS F3, PROTOCOL 6.9): pen motion becomes LASER_POINT messages instead of strokes.
// Pure logic shared by the canvas and the Node unit tests (no DOM): the intensity rule and a per-frame
// throttle that coalesces to the newest point. The laser never draws, never strokes and never touches undo.

/** Intensity while the pen is on the glass (the tip or the eraser end, whatever the pressure). */
export const LASER_CONTACT_INTENSITY = 1.0;
/** Intensity while the stylus hovers (neither the tip nor the eraser end touches). */
export const LASER_HOVER_INTENSITY = 0.5;
/** PointerEvent `buttons` bit of the pen tip touching the glass. */
export const PEN_TIP_BUTTON = 1;
/** PointerEvent `buttons` bit of the pen's eraser end touching the glass (Pointer Events: button 5, buttons 32). */
export const PEN_ERASER_BUTTON = 32;
/** How long the Mac keeps a laser point glowing after the last one. */
export const LASER_DECAY_S = 0.5;

/** The parts of a PointerEvent the intensity rule reads. */
export interface LaserSample {
  pointerType: string;
  buttons: number;
  pressure: number;
}

/**
 * The rule both clients apply (Daylight Ink's LaserPointer and PenRouter say the same): any pen contact, the tip or the
 * eraser end, is LASER_CONTACT_INTENSITY whatever its pressure (a digitizer's first contact sample may carry 0); a
 * hovering pen is LASER_HOVER_INTENSITY, the barrel button pressed in the air included. Anything that is not a pen
 * returns null: fingers and palms never point, as they never draw. Pointer Events report no eraser-end hover (only
 * eraser contact sets buttons 32), so a hovering eraser end points like the tip here (LOOSE_ENDS IL-9).
 */
export function laserIntensity(s: LaserSample): number | null {
  if (s.pointerType !== "pen") return null;
  return (s.buttons & (PEN_TIP_BUTTON | PEN_ERASER_BUTTON)) !== 0 ? LASER_CONTACT_INTENSITY : LASER_HOVER_INTENSITY;
}

/**
 * Whether the laser takes a pen sample. Only with the Laser tool selected and only while no stroke or erase is open: a
 * stroke begun before Laser was picked runs to its own pen-up and is committed normally (never cancelled, so the Mac
 * keeps it); the laser starts with the next contact or hover. Daylight Ink's PenRouter applies the same rule.
 */
export function laserTakesSample(tool: string, contactOpen: boolean): boolean {
  return tool === "laser" && !contactOpen;
}

export interface LaserPoint {
  x: number;
  y: number;
  intensity: number;
}

/**
 * At most one LASER_POINT per animation frame: `offer` keeps only the newest point and asks `schedule` for one
 * frame callback; the callback hands that point to `send`.
 */
export class LaserThrottle {
  private latest: LaserPoint | null = null;
  private queued = false;
  sent = 0;
  coalesced = 0;

  constructor(
    private readonly send: (p: LaserPoint) => void,
    private readonly schedule: (cb: () => void) => void,
  ) {}

  offer(p: LaserPoint): void {
    if (this.latest) this.coalesced++;
    this.latest = p;
    if (this.queued) return;
    this.queued = true;
    this.schedule(() => this.flush());
  }

  private flush(): void {
    this.queued = false;
    const p = this.latest;
    this.latest = null;
    if (!p) return;
    this.sent++;
    this.send(p);
  }
}
