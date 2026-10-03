// "Send facts to Mac" (PROTOCOL 15): the web facts object, the pen pressure range seen since load and
// the one POST to /api/facts on the page's own origin. Everything except sendFacts is pure (no DOM) so
// the Node unit tests cover the payload rules; sendFacts takes the fetch it uses as a parameter.

export const FACTS_SCHEMA = "daylight-tablet-facts/1";
export const FACTS_TIMEOUT_MS = 5000;
/** PROTOCOL 15.1: a fact string is at most 1024 characters, a clientId at most 64. */
export const FACT_STRING_MAX = 1024;
export const CLIENT_ID_MAX = 64;

/** The web `facts` keys of PROTOCOL 15.1, in its order. Every one is always sent. */
export const WEB_FACT_KEYS = [
  "chromeVersion",
  "userAgent",
  "devicePixelRatio",
  "viewport",
  "displayMode",
  "secureContext",
  "wakeLockSupported",
  "wakeLockState",
  "fullscreenState",
  "coalescedEvents",
  "rawUpdate",
  "predictedEvents",
  "firstPenPointerdown",
  "pressureMin",
  "pressureMax",
  "pressureSamples",
  "rttMs",
  "macBuild",
] as const;

export type WebFactKey = (typeof WEB_FACT_KEYS)[number];
export type FactValue = string | number | boolean | null;

export type WakeLockState = "held" | "refused" | "released" | "not requested";
export type FullscreenState = "on" | "refused" | "not requested";

export interface PressureRange {
  min: number | null;
  max: number | null;
  samples: number;
}

/** Plain inputs; anything missing or not a finite number becomes null in the payload. */
export interface FactsInput {
  clientId?: string | null;
  now: Date;
  userAgent?: string | null;
  devicePixelRatio?: number | null;
  viewport?: readonly [number, number] | null;
  displayMode?: string | null;
  secureContext?: boolean | null;
  wakeLockSupported?: boolean | null;
  wakeLockState?: WakeLockState | null;
  fullscreenState?: FullscreenState | null;
  coalescedEvents?: boolean | null;
  rawUpdate?: boolean | null;
  predictedEvents?: boolean | null;
  firstPenPointerdown?: string | null;
  pressure?: PressureRange | null;
  rttMs?: number | null;
  macBuild?: number | string | null;
}

export interface FactsPayload {
  schema: string;
  source: "web";
  clientId?: string;
  sentAt: string;
  facts: Record<WebFactKey, FactValue>;
}

/** "141.0.7390.54" from a user agent with `Chrome/141.0.7390.54`; null when there is none. */
export function parseChromeVersion(ua: string | null | undefined): string | null {
  if (!ua) return null;
  const m = /Chrome\/(\d+(?:\.\d+)*)/.exec(ua);
  return m ? m[1]! : null;
}

/** ISO 8601 UTC without milliseconds, as in the PROTOCOL 15.1 example. */
export function isoSeconds(d: Date): string {
  return d.toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function wakeLockStateOf(requested: boolean, ok: boolean, heldNow: boolean): WakeLockState {
  if (heldNow) return "held";
  if (!requested) return "not requested";
  return ok ? "released" : "refused";
}

export function fullscreenStateOf(requested: boolean, ok: boolean): FullscreenState {
  if (!requested) return "not requested";
  return ok ? "on" : "refused";
}

function str(v: string | null | undefined): string | null {
  if (typeof v !== "string") return null;
  return v.length > FACT_STRING_MAX ? v.slice(0, FACT_STRING_MAX) : v;
}

function num(v: number | null | undefined): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

function bool(v: boolean | null | undefined): boolean | null {
  return typeof v === "boolean" ? v : null;
}

/** The PROTOCOL 15.1 request body for source "web": exactly WEB_FACT_KEYS, flat, null when unknown. */
export function buildFactsPayload(input: FactsInput): FactsPayload {
  const vp = input.viewport;
  const viewport = vp && num(vp[0]) !== null && num(vp[1]) !== null ? `${Math.round(vp[0])}x${Math.round(vp[1])}` : null;
  const p = input.pressure;
  const facts: Record<WebFactKey, FactValue> = {
    chromeVersion: str(parseChromeVersion(input.userAgent)),
    userAgent: str(input.userAgent),
    devicePixelRatio: num(input.devicePixelRatio),
    viewport,
    displayMode: str(input.displayMode),
    secureContext: bool(input.secureContext),
    wakeLockSupported: bool(input.wakeLockSupported),
    wakeLockState: str(input.wakeLockState),
    fullscreenState: str(input.fullscreenState),
    coalescedEvents: bool(input.coalescedEvents),
    rawUpdate: bool(input.rawUpdate),
    predictedEvents: bool(input.predictedEvents),
    firstPenPointerdown: str(input.firstPenPointerdown),
    pressureMin: p ? num(p.min) : null,
    pressureMax: p ? num(p.max) : null,
    pressureSamples: p ? num(p.samples) : null,
    rttMs: num(input.rttMs),
    macBuild: typeof input.macBuild === "string" ? str(input.macBuild) : num(input.macBuild),
  };
  const payload: FactsPayload = { schema: FACTS_SCHEMA, source: "web", sentAt: isoSeconds(input.now), facts };
  if (typeof input.clientId === "string" && input.clientId.length > 0 && input.clientId.length <= CLIENT_ID_MAX) {
    // Key order as in PROTOCOL 15.1 (schema, source, clientId, sentAt, facts).
    return { schema: payload.schema, source: payload.source, clientId: input.clientId, sentAt: payload.sentAt, facts };
  }
  return payload;
}

/** Pen pressures above 0 from pointerdown and pointermove since load (PROTOCOL 15.1 pressureMin/Max/Samples). */
export class PressureTracker {
  private lo = Infinity;
  private hi = -Infinity;
  private n = 0;

  observe(pointerType: string, pressure: number): void {
    if (pointerType !== "pen" || !Number.isFinite(pressure) || !(pressure > 0)) return;
    if (pressure < this.lo) this.lo = pressure;
    if (pressure > this.hi) this.hi = pressure;
    this.n++;
  }

  get range(): PressureRange {
    return this.n === 0 ? { min: null, max: null, samples: 0 } : { min: this.lo, max: this.hi, samples: this.n };
  }
}

export type FactsOutcome = "sent" | "old-mac" | "unreachable" | "refused";

export interface FactsSendResult {
  outcome: FactsOutcome;
  status: number | null;
  text: string;
}

/** The owner-facing line under the button for an HTTP status (null: network error or timeout). */
export function factsResult(status: number | null): FactsSendResult {
  if (status === null) return { outcome: "unreachable", status, text: "Could not reach your Mac. Check the connection and tap again." };
  if (status === 200) return { outcome: "sent", status, text: "Sent to your Mac." };
  if (status === 404 || status === 405) return { outcome: "old-mac", status, text: `Your Mac did not accept the facts (${status}). Update Daylight on your Mac.` };
  return { outcome: "refused", status, text: `Your Mac refused the facts (${status}).` };
}

export interface FactsRequestInit {
  method: string;
  headers: Record<string, string>;
  body: string;
  signal?: AbortSignal;
}

export type FactsFetch = (url: string, init: FactsRequestInit) => Promise<{ status: number }>;

/** One POST of the payload to ./api/facts; settles within timeoutMs with a result, never throws. */
export async function sendFacts(payload: FactsPayload, fetchImpl: FactsFetch, timeoutMs = FACTS_TIMEOUT_MS, url = "./api/facts"): Promise<FactsSendResult> {
  const controller = typeof AbortController === "function" ? new AbortController() : null;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<null>((resolve) => {
    timer = setTimeout(() => { controller?.abort(); resolve(null); }, timeoutMs);
  });
  const init: FactsRequestInit = { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) };
  if (controller) init.signal = controller.signal;
  const request = fetchImpl(url, init).then((res) => res.status, () => null);
  try {
    return factsResult(await Promise.race([request, timeout]));
  } finally {
    clearTimeout(timer);
  }
}
