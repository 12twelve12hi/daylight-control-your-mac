// Browser capabilities that differ between a secure origin (http://localhost over adb reverse) and
// the plain http://<mac-ip>:7788 origin (research-web-server F13 to F16, F23, F26). Every API here is
// feature-detected; nothing throws when it is missing.

export interface Capabilities {
  secureContext: boolean;
  wakeLock: boolean;
  coalescedEvents: boolean;
  rawUpdate: boolean;
  predictedEvents: boolean;
  fullscreen: boolean;
  bigUint64: boolean;
  devicePixelRatio: number;
  viewport: [number, number];
  userAgent: string;
  displayMode: "fullscreen" | "standalone" | "minimal-ui" | "browser";
}

export function capabilities(): Capabilities {
  const proto = typeof PointerEvent === "function" ? (PointerEvent.prototype as unknown as Record<string, unknown>) : {};
  const nav = navigator as Navigator & { wakeLock?: unknown };
  const root = document.documentElement as HTMLElement & { requestFullscreen?: unknown };
  let displayMode: Capabilities["displayMode"] = "browser";
  for (const mode of ["fullscreen", "standalone", "minimal-ui"] as const) {
    try {
      if (window.matchMedia(`(display-mode: ${mode})`).matches) { displayMode = mode; break; }
    } catch { /* matchMedia missing */ }
  }
  return {
    secureContext: window.isSecureContext === true,
    wakeLock: typeof nav.wakeLock === "object" && nav.wakeLock !== null,
    coalescedEvents: typeof proto.getCoalescedEvents === "function",
    rawUpdate: "onpointerrawupdate" in window,
    predictedEvents: typeof proto.getPredictedEvents === "function",
    fullscreen: typeof root.requestFullscreen === "function",
    bigUint64: typeof DataView.prototype.setBigUint64 === "function",
    devicePixelRatio: window.devicePixelRatio || 1,
    viewport: [window.innerWidth, window.innerHeight],
    userAgent: navigator.userAgent,
    displayMode,
  };
}

interface WakeLockSentinelLike {
  released?: boolean;
  release(): Promise<void>;
  addEventListener?(type: "release", listener: () => void): void;
}

interface WakeLockLike {
  request(type: "screen"): Promise<WakeLockSentinelLike>;
}

export interface StartResult {
  fullscreenRequested: boolean;
  fullscreenOk: boolean;
  wakeLockRequested: boolean;
  wakeLockOk: boolean;
}

let sentinel: WakeLockSentinelLike | null = null;
let wantWakeLock = false;
let visibilityBound = false;

async function requestWakeLock(): Promise<boolean> {
  const nav = navigator as Navigator & { wakeLock?: WakeLockLike };
  if (!nav.wakeLock || typeof nav.wakeLock.request !== "function") return false;
  try {
    sentinel = await nav.wakeLock.request("screen");
    sentinel.addEventListener?.("release", () => { sentinel = null; });
    return true;
  } catch {
    sentinel = null;
    return false;
  }
}

/**
 * Called from the Start tap (transient user activation is required for fullscreen). Fullscreen uses
 * `navigationUI: "hide"`; the wake lock is re-requested whenever the page becomes visible again,
 * because the platform releases it on hide (MDN Screen Wake Lock).
 */
export async function enterFullscreenAndWake(): Promise<StartResult> {
  const result: StartResult = { fullscreenRequested: false, fullscreenOk: false, wakeLockRequested: false, wakeLockOk: false };
  const root = document.documentElement as HTMLElement & { requestFullscreen?: (o?: { navigationUI?: "hide" | "show" | "auto" }) => Promise<void> };
  if (typeof root.requestFullscreen === "function" && !document.fullscreenElement) {
    result.fullscreenRequested = true;
    try {
      await root.requestFullscreen({ navigationUI: "hide" });
      result.fullscreenOk = true;
    } catch {
      result.fullscreenOk = false;
    }
  }
  const nav = navigator as Navigator & { wakeLock?: unknown };
  if (nav.wakeLock) {
    result.wakeLockRequested = true;
    wantWakeLock = true;
    result.wakeLockOk = await requestWakeLock();
    if (!visibilityBound) {
      visibilityBound = true;
      document.addEventListener("visibilitychange", () => {
        if (document.visibilityState === "visible" && wantWakeLock && !sentinel) void requestWakeLock();
      });
    }
  }
  return result;
}

export function wakeLockHeld(): boolean {
  return sentinel !== null && sentinel.released !== true;
}
