// Laser tool (LOOSE_ENDS F3, PROTOCOL 6.9): pen motion becomes LASER_POINT messages instead of strokes.
// Pure logic shared by the canvas and the Node unit tests (no DOM): the intensity rule and a per-frame
// throttle that coalesces to the newest point. The laser never draws, never strokes and never touches undo.

/** Intensity while the pen is on the glass. */
export const LASER_CONTACT_INTENSITY = 1.0;
/** Intensity while the stylus hovers (no buttons, or pressure 0). */
export const LASER_HOVER_INTENSITY = 0.5;
/** How long the Mac keeps a laser point glowing after the last one. */
export const LASER_DECAY_S = 0.5;

/** The parts of a PointerEvent the intensity rule reads. */
export interface LaserSample {
  pointerType: string;
  buttons: number;
  pressure: number;
}

/**
 * Contact (pen, a button down and pressure above 0) is LASER_CONTACT_INTENSITY; a hovering pen is
 * LASER_HOVER_INTENSITY. Anything that is not a pen returns null: fingers and palms never point, as they never draw.
 */
export function laserIntensity(s: LaserSample): number | null {
  if (s.pointerType !== "pen") return null;
  return s.buttons !== 0 && s.pressure > 0 ? LASER_CONTACT_INTENSITY : LASER_HOVER_INTENSITY;
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
