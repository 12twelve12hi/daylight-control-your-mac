// The tablet chip (SPEC section 10 and PROTOCOL 6.14), as a pure function so Node can test it.
// Input: the connection phase and the last STATE; output: text, a CSS state token and what a tap does.

import type { StateReport } from "./protocol.js";

/** Connection phase as the socket layer reports it. */
export type ConnectionPhase =
  | "disconnected"   // no socket; re-dial scheduled
  | "connecting"     // socket opening or HANDSHAKE sent, no ACK yet
  | "pending"        // ACK status 1: the Mac shows the Allow panel
  | "live"           // ACK status 0
  | "denied"         // ACK status 2: retry only on user action
  | "incompatible"   // ACK status 3 or the server did not echo solstream.v1
  | "refused";       // the Mac answers /api/info but the socket never opens (LOOSE_ENDS E18); re-dial every 60 s

export type ChipKind =
  | "searching"
  | "pending"
  | "denied"
  | "incompatible"
  | "refused"
  | "inactive"
  | "camera"
  | "live"
  | "prewarn"
  | "returning"
  | "pinned";

export interface ChipView {
  kind: ChipKind;
  text: string;
  /** Amber dot shown next to the text. */
  dot: boolean;
  /** Dot breathes in phase with the Mac divider (pre-warning only). */
  breathing: boolean;
  /** What a tap does. */
  tap: "pin" | "retry" | "explain" | "none";
  /** Whether a 600 ms long press sends AUTO_ENGAGE_RETURN. */
  longPressReturns: boolean;
}

export const LONG_PRESS_MS = 600;
export const INK_SOURCE_NAMES: Record<0 | 1 | 2, string> = { 0: "web", 1: "Daylight Ink", 2: "mirror" };

/** Pre-warning breath weight at `t` seconds since the pre-warning was first seen: 0.5 Hz, same as the Mac divider. */
export function breath(tSeconds: number): number {
  return 0.5 * (1 - Math.cos((2 * Math.PI * tSeconds) / 2));
}

/** Seconds shown in "Returning in N": ceil(ms / 1000), never below 1 while a return is scheduled. */
export function returningSeconds(msToReturn: number): number {
  return Math.max(1, Math.ceil(msToReturn / 1000));
}

/**
 * `msElapsed` is the time since the STATE carrying `state.msToReturn` arrived; the chip counts down
 * locally between messages (PROTOCOL 6.14).
 */
export function chipView(phase: ConnectionPhase, state: StateReport | null, msElapsed = 0): ChipView {
  switch (phase) {
    case "disconnected":
    case "connecting":
      return { kind: "searching", text: "Looking for your Mac", dot: false, breathing: false, tap: "none", longPressReturns: false };
    case "pending":
      return { kind: "pending", text: "Look at your Mac", dot: true, breathing: false, tap: "none", longPressReturns: false };
    case "denied":
      return { kind: "denied", text: "Not allowed by the Mac", dot: false, breathing: false, tap: "retry", longPressReturns: false };
    case "incompatible":
      return { kind: "incompatible", text: "Update Daylight on your Mac", dot: false, breathing: false, tap: "retry", longPressReturns: false };
    case "refused":
      // The page cannot tell an old protocol from a refused socket (Chromium hides the upgrade result); say what it knows.
      return { kind: "refused", text: "Mac found, socket refused. Tap to retry", dot: false, breathing: false, tap: "retry", longPressReturns: false };
    case "live":
      break;
  }
  if (!state) {
    // Live but no STATE yet (it follows the ACK within the same burst).
    return { kind: "searching", text: "Looking for your Mac", dot: false, breathing: false, tap: "none", longPressReturns: false };
  }
  if (!state.allowed) {
    return { kind: "pending", text: "Look at your Mac", dot: true, breathing: false, tap: "none", longPressReturns: false };
  }
  if (!state.activeSource) {
    return {
      kind: "inactive",
      text: `Ink source is ${INK_SOURCE_NAMES[state.inkSource]} on the Mac`,
      dot: false,
      breathing: false,
      tap: "explain",
      longPressReturns: false,
    };
  }
  if (state.pinned) {
    return { kind: "pinned", text: "KEEP WHITEBOARD", dot: false, breathing: false, tap: "pin", longPressReturns: true };
  }
  if (state.preWarning && state.msToReturn !== null) {
    const remaining = Math.max(0, state.msToReturn - msElapsed);
    return { kind: "prewarn", text: `Returning in ${returningSeconds(remaining)}`, dot: true, breathing: true, tap: "pin", longPressReturns: true };
  }
  switch (state.governor) {
    case 0:
      return { kind: "camera", text: "Camera", dot: false, breathing: false, tap: "pin", longPressReturns: false };
    case 3:
      return { kind: "returning", text: "Returning", dot: true, breathing: false, tap: "pin", longPressReturns: false };
    default:
      return { kind: "live", text: "LIVE", dot: true, breathing: false, tap: "pin", longPressReturns: true };
  }
}
