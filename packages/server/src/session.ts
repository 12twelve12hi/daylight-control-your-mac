import crypto from "node:crypto";
import {
  PROTOCOL_VERSION,
  type BrainOutput,
  type Config,
  type Event,
  type InkPurpose,
  type LockMode,
  type Meeting,
  type Phase,
  type Plan,
  type PublicConfig,
  type Session,
  type StateSnapshot,
  type Turn,
} from "@twelve/protocol";
import type { Brain, BrainInput } from "./brain.js";
import type { CalendarProvider } from "./calendar.js";
import type { Store } from "./store.js";
import { isWorkHours } from "./schedule.js";

export interface Clock {
  now(): number;
  setTimeout(fn: () => void, ms: number): unknown;
  clearTimeout(h: unknown): void;
}

export const realClock: Clock = {
  now: () => Date.now(),
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (h) => clearTimeout(h as NodeJS.Timeout),
};

export interface EngineDeps {
  config: () => Config;
  publicConfig: () => PublicConfig;
  store: Store;
  brain: Brain;
  calendar: CalendarProvider;
  clock?: Clock;
  /** Called after any state change with the fresh snapshot. */
  onChange: (state: StateSnapshot) => void;
  /** Called when the coach has something to say. */
  onAssistant: (turn: Turn, purpose: InkPurpose) => void;
  onBusy: (busy: boolean, what: "reading" | "thinking") => void;
  onError: (code: string, message: string) => void;
}

/**
 * The session engine. Single source of truth for phase, lock mode and timers.
 * All public methods are commands; they mutate state, persist, and emit.
 */
export class Engine {
  private phase: Phase = "idle";
  private session: Session | null = null;
  private armedManually = false;
  private manualMeetingUntil: number | null = null;
  private manualMeetingTitle = "Meeting (manual pass)";
  private manualPassDay = "";
  private manualPassesUsed = 0;
  private emergencyUntil: number | null = null;
  private nextCheckinAt: number | null = null;
  private checkinLocksAt: number | null = null;
  private pausedCheckinRemainingMs: number | null = null;
  private lastCalendarMeeting: Meeting | null = null;
  private aiBusy = false;
  private clients = { mac: false, daylight: false };
  private timers = new Map<string, unknown>();
  private readonly clock: Clock;

  constructor(private readonly deps: EngineDeps) {
    this.clock = deps.clock ?? realClock;
  }

  // -- lifecycle ------------------------------------------------------------

  start() {
    const open = this.deps.store.findOpenSession();
    if (open) {
      // Resume after a restart: the plan is confirmed, so we are working.
      this.session = open;
      this.phase = "working";
      this.scheduleCheckin(this.deps.config().checkin.intervalMinutes * 60_000);
      console.log(`[engine] resumed session ${open.id}`);
    }
    this.armTick();
    this.emit();
  }

  stop() {
    for (const h of this.timers.values()) this.clock.clearTimeout(h);
    this.timers.clear();
  }

  setClient(role: "mac" | "daylight", connected: boolean) {
    this.clients[role] = connected;
    this.emit();
  }

  // -- derived state --------------------------------------------------------

  get currentPhase(): Phase {
    return this.phase;
  }

  get currentSession(): Session | null {
    return this.session;
  }

  private now() {
    return this.clock.now();
  }

  private today() {
    return new Date(this.now()).toISOString().slice(0, 10);
  }

  gateActive(): boolean {
    return this.armedManually || isWorkHours(this.deps.config().schedule, new Date(this.now()));
  }

  meeting(): Meeting | null {
    const t = this.now();
    if (this.manualMeetingUntil && this.manualMeetingUntil > t) {
      return {
        title: this.manualMeetingTitle,
        start: new Date(t).toISOString(),
        end: new Date(this.manualMeetingUntil).toISOString(),
        source: "manual",
      };
    }
    const cal = this.deps.calendar.currentMeeting(new Date(t));
    return cal;
  }

  private baseLockMode(): LockMode {
    switch (this.phase) {
      case "working":
      case "checkin_warn":
        return "free";
      case "idle":
        return this.gateActive() ? "shield" : "free";
      default:
        return "shield";
    }
  }

  lockMode(): LockMode {
    if (this.emergencyUntil && this.emergencyUntil > this.now()) return "free";
    const base = this.baseLockMode();
    if (base === "shield" && this.meeting()) return "allowlist";
    return base;
  }

  private shieldText(): { title: string; body: string } | null {
    if (this.lockMode() !== "shield") return null;
    switch (this.phase) {
      case "idle":
        return { title: "Your Mac is waiting for your Daylight", body: "Write your intention and priorities on the Daylight to unlock." };
      case "planning":
        return { title: "Planning on the Daylight", body: "Take your time. The Mac unlocks when the plan is in." };
      case "reviewing":
        return { title: "Almost there", body: "Confirm the plan on the Daylight to unlock." };
      case "checkin":
        return { title: "Check-in time", body: "Write where you are on the Daylight. Two minutes, no grades." };
      case "wrapup":
        return { title: "Wrapping up", body: "Finish the wrap-up on the Daylight. Then the Mac rests until your next plan." };
      default:
        return { title: "Locked", body: "" };
    }
  }

  snapshot(): StateSnapshot {
    const cfg = this.deps.config();
    const banner =
      this.phase === "checkin_warn" && this.checkinLocksAt
        ? {
            text: "Check-in on your Daylight",
            endsAt: this.checkinLocksAt,
            canSnooze: !(this.session?.snoozeUsedForCurrentCheckin ?? false),
          }
        : null;
    const lastAssistant = [...(this.session?.transcript ?? [])].reverse().find((t) => t.role === "assistant") ?? null;
    const passesLeft = this.manualPassDay === this.today() ? Math.max(0, cfg.meetingPass.manualPerDay - this.manualPassesUsed) : cfg.meetingPass.manualPerDay;
    return {
      protocolVersion: PROTOCOL_VERSION,
      now: this.now(),
      gateActive: this.gateActive(),
      armedManually: this.armedManually,
      phase: this.phase,
      lockMode: this.lockMode(),
      shield: this.shieldText(),
      banner,
      allowlist: cfg.allowlist.bundleIds,
      meeting: this.meeting(),
      emergencyUntil: this.emergencyUntil && this.emergencyUntil > this.now() ? this.emergencyUntil : null,
      nextCheckinAt: this.phase === "working" ? this.nextCheckinAt : null,
      checkinLocksAt: this.phase === "checkin_warn" ? this.checkinLocksAt : null,
      session: this.session,
      aiBusy: this.aiBusy,
      clients: { ...this.clients },
      config: this.deps.publicConfig(),
      lastAssistant,
      manualPassesLeftToday: passesLeft,
    };
  }

  private emit() {
    this.deps.onChange(this.snapshot());
  }

  private persist() {
    if (this.session) this.deps.store.saveSession(this.session);
  }

  private logEvent(kind: Event["kind"], detail?: string) {
    const ev: Event = { at: new Date(this.now()).toISOString(), kind, detail };
    if (this.session) {
      this.session.events.push(ev);
      this.persist();
    } else {
      this.deps.store.appendDayEvent(ev);
    }
  }

  // -- timers ---------------------------------------------------------------

  private setTimer(name: string, ms: number, fn: () => void) {
    this.clearTimer(name);
    this.timers.set(name, this.clock.setTimeout(() => {
      this.timers.delete(name);
      fn();
    }, Math.max(0, ms)));
  }

  private clearTimer(name: string) {
    const h = this.timers.get(name);
    if (h !== undefined) {
      this.clock.clearTimeout(h);
      this.timers.delete(name);
    }
  }

  /** Once a minute: schedule boundaries, calendar changes, session max length. */
  private armTick() {
    this.setTimer("tick", 60_000, () => {
      this.tick();
      this.armTick();
    });
  }

  tick() {
    const cfg = this.deps.config();
    // Meeting overlay start/end → pause or resume check-in timers.
    const m = this.meeting();
    const was = this.lastCalendarMeeting;
    if (m && !was) {
      this.logEvent(m.source === "manual" ? "meeting_pass" : "calendar_meeting_start", m.title);
      this.pauseCheckin();
    } else if (!m && was) {
      this.logEvent("calendar_meeting_end", was.title);
      this.resumeCheckin();
    }
    this.lastCalendarMeeting = m;

    if (this.emergencyUntil && this.emergencyUntil <= this.now()) this.emergencyUntil = null;

    if (this.session && this.phase !== "idle") {
      const maxMs = cfg.session.maxHours * 3600_000;
      if (this.now() - Date.parse(this.session.startedAt) > maxMs && this.phase !== "wrapup") {
        this.logEvent("auto_end", `after ${cfg.session.maxHours}h`);
        this.endSession();
        return;
      }
    }
    this.emit();
  }

  /** A fresh check-in cycle: the snooze becomes available again. */
  private scheduleCheckin(ms: number) {
    if (this.session) this.session.snoozeUsedForCurrentCheckin = false;
    this.nextCheckinAt = this.now() + ms;
    this.setTimer("checkin", ms, () => this.startCheckinWarning());
  }

  private pauseCheckin() {
    if (this.phase === "working" && this.nextCheckinAt) {
      this.pausedCheckinRemainingMs = Math.max(60_000, this.nextCheckinAt - this.now());
      this.clearTimer("checkin");
      this.nextCheckinAt = null;
    } else if (this.phase === "checkin_warn") {
      // A meeting started during the warning: cancel the warning, resume later.
      this.clearTimer("checkin_lock");
      this.phase = "working";
      this.checkinLocksAt = null;
      this.pausedCheckinRemainingMs = 2 * 60_000;
    }
  }

  private resumeCheckin() {
    if (this.phase === "working" && this.pausedCheckinRemainingMs != null) {
      // Give a short landing after a meeting before asking for a check-in.
      const ms = Math.max(this.pausedCheckinRemainingMs, 5 * 60_000);
      this.pausedCheckinRemainingMs = null;
      this.scheduleCheckin(ms);
    }
  }

  private startCheckinWarning() {
    if (this.phase !== "working") return;
    if (this.meeting()) {
      // Never interrupt a meeting; try again after it.
      this.pausedCheckinRemainingMs = 60_000;
      this.nextCheckinAt = null;
      return;
    }
    const cfg = this.deps.config();
    this.phase = "checkin_warn";
    this.checkinLocksAt = this.now() + cfg.checkin.warningSeconds * 1000;
    this.logEvent("checkin_warn");
    this.setTimer("checkin_lock", cfg.checkin.warningSeconds * 1000, () => this.lockForCheckin());
    this.emit();
  }

  private lockForCheckin() {
    if (this.phase !== "checkin_warn") return;
    this.phase = "checkin";
    this.checkinLocksAt = null;
    this.logEvent("checkin_lock");
    this.emit();
  }

  // -- commands -------------------------------------------------------------

  arm() {
    this.armedManually = true;
    this.logEvent("arm");
    this.emit();
  }

  disarm() {
    this.armedManually = false;
    this.logEvent("disarm");
    this.emit();
  }

  startPlanning() {
    if (this.phase !== "idle") return this.emit();
    this.session = {
      id: `${new Date(this.now()).toISOString().replace(/[:.]/g, "-")}-${crypto.randomBytes(2).toString("hex")}`,
      startedAt: new Date(this.now()).toISOString(),
      plan: { intention: "", priorities: [], todos: [] },
      transcript: [],
      checkins: [],
      events: [],
      questionsAsked: 0,
      snoozeUsedForCurrentCheckin: false,
    };
    this.phase = "planning";
    this.persist();
    this.emit();
  }

  /** Ink or text arrives from the Daylight (or a voice transcript). */
  async submitInk(msg: { purpose: InkPurpose; png?: string; text?: string; via?: "ink" | "text" | "voice" }) {
    if (!this.session) {
      if (msg.purpose === "plan") this.startPlanning();
      else return this.deps.onError("no_session", "There is no session to write into.");
    }
    const s = this.session!;
    const allowed: Record<InkPurpose, Phase[]> = {
      plan: ["planning", "reviewing"],
      reply: ["reviewing", "planning"],
      checkin: ["checkin", "checkin_warn", "working"],
      wrapup: ["wrapup"],
    };
    if (!allowed[msg.purpose].includes(this.phase)) {
      return this.deps.onError("wrong_phase", `Cannot submit ${msg.purpose} while ${this.phase}.`);
    }
    if (msg.purpose === "checkin" && this.phase !== "checkin") {
      // "Check in now" straight from the dashboard.
      this.clearTimer("checkin");
      this.clearTimer("checkin_lock");
      this.phase = "checkin";
      this.checkinLocksAt = null;
    }
    const cfg = this.deps.config();
    const inkFile = msg.png ? this.deps.store.saveInk(s.id, msg.png) : undefined;
    const via = msg.via ?? (msg.png ? "ink" : "text");
    s.transcript.push({ at: new Date(this.now()).toISOString(), role: "user", text: msg.text ?? "(handwritten page)", via, inkFile });
    this.persist();

    const questionsLeft = msg.purpose === "plan" || msg.purpose === "reply" ? Math.max(0, cfg.gate.maxQuestions - s.questionsAsked) : 0;
    const input: BrainInput = {
      purpose: msg.purpose,
      png: msg.png,
      text: msg.text,
      plan: s.plan.intention || s.plan.priorities.length ? s.plan : null,
      history: s.transcript.slice(0, -1),
      questionsLeft,
      now: new Date(this.now()),
    };

    this.aiBusy = true;
    this.deps.onBusy(true, "reading");
    this.emit();
    let out: BrainOutput;
    try {
      out = await this.deps.brain.read(input);
    } catch (err) {
      this.aiBusy = false;
      this.deps.onBusy(false, "reading");
      const message = (err as Error).message || String(err);
      console.error("[engine] brain failed:", message);
      this.deps.onError("brain_failed", `The coach could not read that: ${message}`);
      this.emit();
      return;
    }
    this.aiBusy = false;
    this.deps.onBusy(false, "reading");
    this.applyBrainOutput(msg.purpose, out, inkFile);
  }

  private applyBrainOutput(purpose: InkPurpose, out: BrainOutput, inkFile?: string) {
    const s = this.session;
    if (!s) return;
    // Keep the transcript honest: replace the placeholder user text with the transcription.
    const lastUser = [...s.transcript].reverse().find((t) => t.role === "user");
    if (lastUser && lastUser.via === "ink" && out.transcript) lastUser.text = out.transcript;

    const questions = out.questions ?? [];
    const turn: Turn = { at: new Date(this.now()).toISOString(), role: "assistant", text: out.message, questions };
    s.transcript.push(turn);

    if (purpose === "plan" || purpose === "reply") {
      if (out.plan) s.plan = mergePlan(s.plan, out.plan);
      s.questionsAsked += questions.length;
      this.phase = "reviewing";
    } else if (purpose === "checkin") {
      const c = out.checkin ?? { where: "", happened: "", stuck: "", next: "" };
      s.checkins.push({
        at: new Date(this.now()).toISOString(),
        where: c.where,
        happened: c.happened,
        stuck: c.stuck || undefined,
        next: c.next,
        aiReply: out.message,
        inkFile,
      });
      // Stay in "checkin" until the person taps "Back to work" so they read the reply.
    } else if (purpose === "wrapup") {
      s.wrapup = { done: out.wrapup?.done ?? "", next: out.wrapup?.next ?? "", summary: out.message, inkFile };
    }
    this.persist();
    this.deps.onAssistant(turn, purpose);
    this.emit();
  }

  confirmPlan(plan?: Plan) {
    if (!this.session || (this.phase !== "reviewing" && this.phase !== "planning")) return this.emit();
    if (plan) this.session.plan = normalizePlan(plan);
    if (!this.session.plan.intention.trim()) {
      return this.deps.onError("incomplete", "Write an intention before unlocking.");
    }
    this.phase = "working";
    this.persist();
    this.scheduleCheckin(this.deps.config().checkin.intervalMinutes * 60_000);
    this.emit();
  }

  editPlan(plan: Plan) {
    if (!this.session) return;
    this.session.plan = normalizePlan(plan);
    this.persist();
    this.emit();
  }

  toggleTodo(id: string, done: boolean) {
    const t = this.session?.plan.todos.find((x) => x.id === id);
    if (t) {
      t.done = done;
      this.persist();
    }
    this.emit();
  }

  checkinNow() {
    if (this.phase !== "working" && this.phase !== "checkin_warn") return this.emit();
    this.clearTimer("checkin");
    this.clearTimer("checkin_lock");
    this.phase = "checkin";
    this.checkinLocksAt = null;
    this.nextCheckinAt = null;
    this.emit();
  }

  snooze() {
    if (this.phase !== "checkin_warn" || !this.session) return this.emit();
    if (this.session.snoozeUsedForCurrentCheckin) return this.deps.onError("snoozed", "Snooze already used for this check-in.");
    const cfg = this.deps.config();
    this.session.snoozeUsedForCurrentCheckin = true;
    this.clearTimer("checkin_lock");
    this.checkinLocksAt = null;
    this.phase = "working";
    this.logEvent("snooze", `${cfg.checkin.snoozeMinutes} min`);
    this.setTimer("checkin", cfg.checkin.snoozeMinutes * 60_000, () => this.startCheckinWarning());
    this.nextCheckinAt = this.now() + cfg.checkin.snoozeMinutes * 60_000;
    this.persist();
    this.emit();
  }

  backToWork() {
    if (this.phase !== "checkin") return this.emit();
    this.phase = "working";
    this.scheduleCheckin(this.deps.config().checkin.intervalMinutes * 60_000);
    this.emit();
  }

  endSession() {
    if (!this.session || this.phase === "idle" || this.phase === "wrapup") return this.emit();
    this.clearTimer("checkin");
    this.clearTimer("checkin_lock");
    this.nextCheckinAt = null;
    this.checkinLocksAt = null;
    if (this.phase === "planning" || this.phase === "reviewing") {
      // Abandoned before confirming: close quietly without a wrap-up.
      this.session.endedAt = new Date(this.now()).toISOString();
      this.persist();
      this.session = null;
      this.phase = "idle";
      return this.emit();
    }
    this.phase = "wrapup";
    this.emit();
  }

  closeWrapup() {
    if (!this.session || this.phase !== "wrapup") return this.emit();
    this.session.endedAt = new Date(this.now()).toISOString();
    this.persist();
    this.session = null;
    this.phase = "idle";
    this.emit();
  }

  manualMeetingPass(minutes?: number) {
    const cfg = this.deps.config();
    if (this.manualPassDay !== this.today()) {
      this.manualPassDay = this.today();
      this.manualPassesUsed = 0;
    }
    if (this.manualPassesUsed >= cfg.meetingPass.manualPerDay) {
      return this.deps.onError("no_passes", "No manual meeting passes left today. Add the meeting to your calendar instead.");
    }
    this.manualPassesUsed++;
    const mins = minutes ?? cfg.meetingPass.manualMinutes;
    this.manualMeetingUntil = this.now() + mins * 60_000;
    this.logEvent("meeting_pass", `${mins} min (manual)`);
    this.lastCalendarMeeting = this.meeting();
    this.pauseCheckin();
    this.setTimer("manual_pass", mins * 60_000, () => {
      this.manualMeetingUntil = null;
      this.tick();
    });
    this.emit();
  }

  emergencyUnlock(reason: string) {
    const cfg = this.deps.config();
    if (reason.trim().length < cfg.emergency.minReasonChars) {
      return this.deps.onError("reason_too_short", `Write at least ${cfg.emergency.minReasonChars} characters.`);
    }
    this.emergencyUntil = this.now() + cfg.emergency.unlockMinutes * 60_000;
    this.logEvent("emergency_unlock", reason.trim());
    this.setTimer("emergency", cfg.emergency.unlockMinutes * 60_000, () => {
      this.emergencyUntil = null;
      this.emit();
    });
    this.emit();
  }

  noteForeground(bundleId: string, name?: string) {
    // Only logged while the gate is enforcing an allowlist, to keep the journal short.
    if (this.lockMode() === "allowlist") this.logEvent("mac_foreground", name ? `${name} (${bundleId})` : bundleId);
  }

  configChanged() {
    // Re-evaluate anything derived from config.
    this.emit();
  }
}

// ---------------------------------------------------------------------------

function normalizePlan(p: Plan): Plan {
  return {
    intention: p.intention.trim(),
    priorities: p.priorities.map((x) => x.trim()).filter(Boolean).slice(0, 3),
    todos: p.todos.map((t) => ({ id: t.id || crypto.randomBytes(3).toString("hex"), text: t.text.trim(), done: Boolean(t.done) })).filter((t) => t.text),
    notes: p.notes,
  };
}

/** Merge a model-extracted plan into the existing one, keeping todo ids and done flags. */
export function mergePlan(existing: Plan, incoming: { intention: string; priorities: string[]; todos: string[] }): Plan {
  const todos = incoming.todos.map((text) => {
    const prev = existing.todos.find((t) => t.text.toLowerCase() === text.trim().toLowerCase());
    return prev ?? { id: crypto.randomBytes(3).toString("hex"), text: text.trim(), done: false };
  });
  return normalizePlan({
    intention: incoming.intention || existing.intention,
    priorities: incoming.priorities.length ? incoming.priorities : existing.priorities,
    todos: todos.length ? todos : existing.todos,
    notes: existing.notes,
  });
}
