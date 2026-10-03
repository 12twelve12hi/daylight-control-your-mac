// Daylight whiteboard page: wiring of the ink canvas, the toolbar, the chip, the socket and the
// Start overlay. Served by the Mac at http://<mac>:7788/ (or over adb reverse at http://localhost:7788/).
import "./styles.css";
import { capabilities, enterFullscreenAndWake, wakeLockHeld, type Capabilities, type StartResult } from "./caps.js";
import { Chip } from "./chip.js";
import type { ConnectionPhase } from "./chip-state.js";
import { CANVAS_H, CANVAS_W, InkCanvas } from "./ink.js";
import * as protocol from "./protocol.js";
import { newUuid16, type HandshakeAck, type StateReport } from "./protocol.js";
import { Toolbar, type Tool } from "./tools.js";
import { InkClient } from "./ws.js";

interface ApiInfo {
  app?: string;
  version?: string;
  build?: number;
  port?: number;
  inkSource?: string;
  pillStripHeight?: number;
  secureHint?: string;
  origin?: string;
}

const STORAGE_CLIENT_ID = "daylight.clientId";
const STORAGE_DEVICE_NAME = "daylight.deviceName";
const STORAGE_FLAG_DISMISSED = "daylight.flagHintDismissed";
const DEFAULT_LABEL = "Chrome on Daylight";

function storageGet(key: string): string | null {
  try { return localStorage.getItem(key); } catch { return null; }
}
function storageSet(key: string, value: string): void {
  try { localStorage.setItem(key, value); } catch { /* storage unavailable */ }
}

function clientId(): string {
  let id = storageGet(STORAGE_CLIENT_ID);
  if (!id) {
    id = protocol.uuidToString(newUuid16());
    storageSet(STORAGE_CLIENT_ID, id);
  }
  return id;
}

function identity(): string {
  const label = (storageGet(STORAGE_DEVICE_NAME) ?? DEFAULT_LABEL).slice(0, 64);
  return `web;${clientId()};${label}`;
}

/** ws://<same host>/ink, or ?host=<ip[:port]> to point a dev page at another Mac. */
function socketUrl(): string {
  const params = new URLSearchParams(location.search);
  const scheme = location.protocol === "https:" ? "wss" : "ws";
  const host = params.get("host");
  if (host) return `${scheme}://${host.includes(":") ? host : `${host}:7788`}/ink`;
  return `${scheme}://${location.host}/ink`;
}

function $(id: string): HTMLElement {
  const el = document.getElementById(id);
  if (!el) throw new Error(`#${id} missing`);
  return el;
}

const caps: Capabilities = capabilities();
const paper = $("paper");
const chipEl = $("chip");
const toolbarEl = $("toolbar");
const startEl = $("start");
const cardEl = $("card");

// -- page model ----------------------------------------------------------------

let pageId = newUuid16();
let pageIndex = 0;
let lastState: StateReport | null = null;
let lastAck: HandshakeAck | null = null;
let info: ApiInfo | null = null;
let startResult: StartResult | null = null;
const consoleFacts: string[] = [];

const client = new InkClient(socketUrl(), identity(), {
  onPhase(phase: ConnectionPhase) {
    chip.setPhase(phase);
    document.body.dataset.connection = phase;
    if (phase !== "live") ink.restartOpenStroke();
    if (phase === "live" && !lastState) toolbar.setDepths(0, 0);
  },
  onState(state: StateReport) {
    lastState = state;
    chip.setState(state);
    toolbar.setDepths(state.undoDepth, state.redoDepth);
    ink.applyDepths(state.undoDepth, state.redoDepth);
    document.body.dataset.governor = String(state.governor);
    renderCard();
  },
  onAck(ack) {
    lastAck = ack;
  },
});

const ink = new InkCanvas(paper, client);

const toolbar = new Toolbar(toolbarEl, {
  setTool(tool: Tool) { ink.tool = tool; },
  undo() { client.sendControl(client.encoder.undo(pageId)); },
  redo() { client.sendControl(client.encoder.redo(pageId)); },
  newPage() {
    pageId = newUuid16();
    pageIndex += 1;
    client.sendControl(client.encoder.pageChange(pageId, CANVAS_W, CANVAS_H, pageIndex));
    ink.clearLocal();
  },
  clear() {
    client.sendControl(client.encoder.clear(pageId));
    ink.clearLocal();
  },
  info() { toggleCard(); },
});

const chip = new Chip(chipEl, {
  togglePin() { client.sendControl(client.encoder.togglePin(-1)); },
  returnNow() { client.sendControl(client.encoder.returnNow()); },
  retry() { client.retry(); },
  explain() { toggleCard(true); },
});

// -- Start overlay ---------------------------------------------------------------

function hideStart(): void {
  startEl.hidden = true;
  document.body.classList.add("started");
  ink.layout();
}

startEl.addEventListener("click", () => {
  hideStart();
  void enterFullscreenAndWake().then((r) => { startResult = r; renderCard(); });
});

document.addEventListener("fullscreenchange", () => {
  // Leaving fullscreen (system gesture) offers the Start tap again so the owner can re-enter.
  if (!document.fullscreenElement && document.body.classList.contains("started") && caps.fullscreen) {
    startEl.hidden = false;
    startEl.querySelector(".start-title")!.textContent = "Tap to go full screen again";
  }
});

// -- expanded card ---------------------------------------------------------------

function toggleCard(force?: boolean): void {
  const show = force ?? cardEl.hidden;
  cardEl.hidden = !show;
  if (show) renderCard();
}

function renderCard(): void {
  const origin = info?.origin ?? location.origin;
  const flag = info?.secureHint ?? "chrome://flags/#unsafely-treat-insecure-origin-as-secure";
  const source = lastState ? ["web", "Daylight Ink", "mirror"][lastState.inkSource] : null;
  const rows: string[] = [];
  if (lastState && !lastState.activeSource) {
    rows.push(`<section class="row warn"><h3>Ink source is ${source} on the Mac</h3><p>On the Mac: menu bar &gt; Daylight &gt; Ink source &gt; Web. The chip turns to LIVE when the pen touches the glass.</p></section>`);
  }
  rows.push(`<section class="row"><h3>Add to Home screen</h3><p>Chrome menu &gt; Add to Home screen. Every later day: tap the icon.</p></section>`);
  rows.push(`<section class="row"><h3>Get the Daylight Ink app</h3><p><a href="./daylight-ink.apk" id="apk-link">Download Daylight Ink</a> (one-time install; it finds the Mac by itself).</p></section>`);
  if (!caps.secureContext) {
    const dismissed = storageGet(STORAGE_FLAG_DISMISSED) === "1";
    rows.push(`<section class="row flag" data-dismissed="${dismissed}"><h3>Better ink and the screen stays awake over Wi-Fi</h3><p>One time, in Chrome open <code id="flag-url">${flag}</code>, choose Enabled, paste <code id="flag-origin">${origin}</code>, then relaunch Chrome.</p><button type="button" id="flag-dismiss">${dismissed ? "Shown again" : "Got it"}</button></section>`);
  }
  rows.push(`<section class="row facts"><h3>This tablet</h3><p id="facts">${factsText()}</p></section>`);
  cardEl.innerHTML = `<div class="card-head"><h2>Daylight Whiteboard</h2><button type="button" id="card-close" aria-label="Close">Close</button></div>${rows.join("")}`;
  cardEl.querySelector("#card-close")?.addEventListener("click", () => toggleCard(false));
  cardEl.querySelector("#flag-dismiss")?.addEventListener("click", () => {
    storageSet(STORAGE_FLAG_DISMISSED, storageGet(STORAGE_FLAG_DISMISSED) === "1" ? "0" : "1");
    renderCard();
  });
}

function factsText(): string {
  const c = caps;
  const parts = [
    `secure ${c.secureContext}`,
    `wake lock ${c.wakeLock}${startResult ? (startResult.wakeLockOk ? " held" : startResult.wakeLockRequested ? " refused" : "") : ""}${wakeLockHeld() ? " active" : ""}`,
    `coalesced ${c.coalescedEvents}`,
    `rawupdate ${c.rawUpdate}`,
    `fullscreen ${c.fullscreen}${startResult ? (startResult.fullscreenOk ? " on" : startResult.fullscreenRequested ? " refused" : "") : ""}`,
    `display ${c.displayMode}`,
    `dpr ${c.devicePixelRatio}`,
    `viewport ${c.viewport[0]}x${c.viewport[1]}`,
    `rtt ${client.stats.rttMs === null ? "?" : `${client.stats.rttMs.toFixed(1)} ms`}`,
    `mac ${info ? `${info.app ?? "?"} ${info.version ?? ""} build ${info.build ?? "?"} source ${info.inkSource ?? "?"}` : "no /api/info"}`,
    c.userAgent,
  ];
  return parts.join(" | ");
}

// -- /api/info -------------------------------------------------------------------

async function loadInfo(): Promise<void> {
  try {
    const res = await fetch("./api/info", { cache: "no-cache" });
    if (!res.ok) return;
    info = (await res.json()) as ApiInfo;
    renderCard();
  } catch {
    info = null;
  }
}

// -- device facts for LOOSE_ENDS D3, D4, D8 (logged once, copied by the owner) -----

function logFacts(): void {
  const line = `daylight-web caps ${JSON.stringify(caps)}`;
  consoleFacts.push(line);
  console.info(line);
}

let firstPenLogged = false;
paper.addEventListener("pointerdown", (e) => {
  if (firstPenLogged || e.pointerType !== "pen") return;
  firstPenLogged = true;
  const line = `daylight-web first pen pointerdown button=${e.button} buttons=${e.buttons} pressure=${e.pressure} tiltX=${e.tiltX} tiltY=${e.tiltY}`;
  consoleFacts.push(line);
  console.info(line);
}, true);

// -- debug surface for Playwright ------------------------------------------------------

const debug = {
  version: "0.1.0",
  protocol,
  caps,
  consoleFacts,
  get phase() { return client.phase; },
  get state() { return lastState; },
  get ack() { return lastAck; },
  get info() { return info; },
  get start() { return startResult; },
  get ink() { return ink.stats; },
  get client() { return client.stats; },
  get ring() { return { length: client.ring.length, points: client.ring.points, droppedStrokes: client.ring.droppedStrokes }; },
  get chip() { return { ...chip.current, breath: chip.breathWeight(), taps: chip.stats.taps, longPresses: chip.stats.longPresses }; },
  get pageIndex() { return pageIndex; },
  get pageId() { return protocol.uuidToString(pageId); },
  get visibleStrokes() { return ink.strokeCount; },
  get wakeLockHeld() { return wakeLockHeld(); },
  get bufferedAmount() { return client.bufferedAmount; },
  get tool() { return toolbar.tool; },
};
(window as unknown as { __daylight: typeof debug }).__daylight = debug;

// -- go ----------------------------------------------------------------------------

logFacts();
renderCard();
void loadInfo();
client.start();
window.addEventListener("beforeunload", () => client.stop());
