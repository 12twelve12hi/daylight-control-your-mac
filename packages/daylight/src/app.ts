import type { InkPurpose, ServerMessage, StateSnapshot } from "@twelve/protocol";
import { Client, connectionFromLocation, loadConnection, saveConnection } from "./ws.js";
import { h, clear, fmtTime, toast } from "./util.js";
import * as screens from "./screens.js";

export interface AiMessage {
  text: string;
  questions: string[];
  purpose?: InkPurpose;
  at: number;
}

export interface Ctx {
  client: Client | null;
  state: StateSnapshot | null;
  connected: boolean;
  lastAi: AiMessage | null;
  /** Local: when we last entered the check-in phase (ms). */
  checkinStartedAt: number;
  navigate(route: string): void;
  send: Client["send"];
}

export interface Screen {
  el: HTMLElement;
  update?(ctx: Ctx): void;
  unmount?(): void;
}

type Route = { name: string; arg?: string };

function parseRoute(): Route {
  const hash = location.hash.replace(/^#\/?/, "");
  const [name = "", arg] = hash.split("/");
  return { name: name || "home", arg };
}

/** Screens that follow the session phase and get redirected when it changes. */
const FLOW = new Set(["home", "write", "review", "checkin", "wrapup"]);

export class App {
  private root: HTMLElement;
  private topbar: HTMLElement;
  private body: HTMLElement;
  private current: Screen | null = null;
  private currentKey = "";
  private ctx: Ctx;
  private clockTimer: number;

  constructor(root: HTMLElement) {
    this.root = root;
    this.topbar = h("header.topbar");
    this.body = h("main", { style: { display: "contents" } });
    root.append(this.topbar, this.body);
    const conn = connectionFromLocation() ?? loadConnection();
    const client = conn ? new Client(conn) : null;
    this.ctx = {
      client,
      state: null,
      connected: false,
      lastAi: null,
      checkinStartedAt: 0,
      navigate: (r) => {
        if (location.hash !== `#/${r}`) location.hash = `#/${r}`;
        else this.render();
      },
      send: (m) => client?.send(m),
    };
    window.addEventListener("hashchange", () => this.render());
    this.clockTimer = window.setInterval(() => this.tickClock(), 1000);
    if (client) this.connect(client);
    this.render();
  }

  private connect(client: Client) {
    client.onConnection = (up) => {
      this.ctx.connected = up;
      this.renderTopbar();
      this.current?.update?.(this.ctx);
    };
    client.onState = (s) => this.onState(s);
    client.onMessage = (m) => this.onMessage(m);
    client.open();
  }

  private onState(s: StateSnapshot) {
    const prev = this.ctx.state;
    this.ctx.state = s;
    if (s.phase === "checkin" && prev?.phase !== "checkin") {
      // Entered check-in: if we reloaded mid-check-in, fall back to the last lock event.
      const lock = [...(s.session?.events ?? [])].reverse().find((e) => e.kind === "checkin_lock");
      this.ctx.checkinStartedAt = prev ? s.now : lock ? Date.parse(lock.at) : 0;
    }
    if (prev && prev.phase !== s.phase && s.phase === "idle") this.ctx.lastAi = null;
    // The plan was just confirmed: always land on the dashboard, whatever the hash says.
    if (prev && prev.phase === "reviewing" && s.phase === "working") return this.ctx.navigate("home");
    this.render();
  }

  private onMessage(m: ServerMessage) {
    if (m.type === "ai.message") {
      this.ctx.lastAi = { text: m.text, questions: m.questions, purpose: m.purpose, at: Date.now() };
      // A plan page or an answer was read: show the review, wherever we were writing.
      if ((m.purpose === "plan" || m.purpose === "reply") && parseRoute().name === "write") this.ctx.navigate("review");
      else this.current?.update?.(this.ctx);
    } else if (m.type === "error") {
      toast(m.message);
      this.current?.update?.(this.ctx);
    } else if (m.type === "ai.busy") {
      this.current?.update?.(this.ctx);
    }
  }

  private tickClock() {
    const clock = this.topbar.querySelector(".clock");
    if (clock) clock.textContent = fmtTime(Date.now());
    (this.current as Screen & { tick?: () => void })?.tick?.();
  }

  /** Decide which screen the phase wants, if the user is on a flow screen. */
  private phaseRoute(route: Route): Route {
    const s = this.ctx.state;
    if (!this.ctx.client) return { name: "pair" };
    if (!s || !FLOW.has(route.name)) return route;
    switch (s.phase) {
      case "planning":
        return route.name === "write" ? route : { name: "write", arg: "plan" };
      case "reviewing":
        return route.name === "write" && (route.arg === "reply" || route.arg === "plan") ? route : { name: "review" };
      case "checkin":
        return { name: "checkin" };
      case "wrapup":
        return { name: "wrapup" };
      default:
        return route.name === "review" && s.phase === "working" ? route : { name: "home" };
    }
  }

  render() {
    const route = this.phaseRoute(parseRoute());
    const key = `${route.name}/${route.arg ?? ""}`;
    this.renderTopbar();
    if (key === this.currentKey && this.current) {
      this.current.update?.(this.ctx);
      return;
    }
    this.current?.unmount?.();
    clear(this.body);
    this.currentKey = key;
    const make = (screens as unknown as Record<string, (ctx: Ctx, arg?: string) => Screen>)[route.name] ?? screens.home;
    this.current = make(this.ctx, route.arg);
    this.body.appendChild(this.current.el);
    this.current.update?.(this.ctx);
    window.scrollTo(0, 0);
  }

  private renderTopbar() {
    const s = this.ctx.state;
    clear(this.topbar);
    const phaseLabel = (() => {
      if (!this.ctx.client) return "Not paired";
      if (!this.ctx.connected) return "Connecting to your Mac…";
      if (!s) return "";
      const mac = s.clients.mac ? "" : " · Mac app not connected";
      switch (s.phase) {
        case "idle":
          return (s.gateActive ? "Mac is gated" : "Mac is free") + mac;
        case "planning":
          return "Planning" + mac;
        case "reviewing":
          return "Reviewing your plan" + mac;
        case "working":
          return "Working" + (s.meeting ? ` · in a meeting: ${s.meeting.title}` : "") + mac;
        case "checkin_warn":
          return "Check-in soon" + mac;
        case "checkin":
          return "Check-in" + mac;
        case "wrapup":
          return "Wrapping up" + mac;
      }
    })();
    this.topbar.append(
      h("a.brand", { href: "#/" }, "Twelve"),
      h("div.status", null, h("span", { class: "phase" }, phaseLabel), h("span.dot", { class: this.ctx.connected ? "dot on" : "dot" }), h("span.clock", null, fmtTime(Date.now()))),
    );
  }

  unpair() {
    this.ctx.client?.close();
    saveConnection(null);
    location.href = "/";
  }
}
