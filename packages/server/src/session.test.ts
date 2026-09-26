import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { ConfigSchema, type Config, type StateSnapshot, type Turn } from "@twelve/protocol";
import { Engine, type Clock } from "./session.js";
import { Store } from "./store.js";
import { MockBrain } from "./brain.js";
import { StaticCalendar, type CalEvent } from "./calendar.js";

/** Deterministic clock with manually fired timers. */
class FakeClock implements Clock {
  t = Date.parse("2026-09-28T09:00:00Z"); // a Monday, 09:00 UTC
  private timers: { at: number; fn: () => void; id: number }[] = [];
  private seq = 0;
  now() {
    return this.t;
  }
  setTimeout(fn: () => void, ms: number) {
    const id = ++this.seq;
    this.timers.push({ at: this.t + ms, fn, id });
    return id;
  }
  clearTimeout(h: unknown) {
    this.timers = this.timers.filter((x) => x.id !== h);
  }
  /** Advance time, firing due timers in order. */
  advance(ms: number) {
    const target = this.t + ms;
    for (;;) {
      const due = this.timers.filter((x) => x.at <= target).sort((a, b) => a.at - b.at)[0];
      if (!due) break;
      this.timers = this.timers.filter((x) => x.id !== due.id);
      this.t = due.at;
      due.fn();
    }
    this.t = target;
  }
}

function harness(overrides: Partial<Config> = {}, events: CalEvent[] = []) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "twelve-test-"));
  const cfg = ConfigSchema.parse({ schedule: { timezone: "UTC" }, ...overrides });
  const clock = new FakeClock();
  const states: StateSnapshot[] = [];
  const assistant: Turn[] = [];
  const errors: string[] = [];
  const calendar = new StaticCalendar(events, () => cfg.calendar);
  const engine = new Engine({
    config: () => cfg,
    publicConfig: () => {
      const { pairing: _p, ...rest } = cfg;
      return rest;
    },
    store: new Store(root),
    brain: new MockBrain(),
    calendar,
    clock,
    onChange: (s) => states.push(s),
    onAssistant: (t) => assistant.push(t),
    onBusy: () => {},
    onError: (code) => errors.push(code),
  });
  engine.start();
  const last = () => states[states.length - 1]!;
  return { engine, clock, states, assistant, errors, last, cfg, calendar, root };
}

test("idle inside work hours shields the Mac; outside it is free", () => {
  const h = harness();
  assert.equal(h.last().phase, "idle");
  assert.equal(h.last().gateActive, true);
  assert.equal(h.last().lockMode, "shield");
  h.clock.advance(10 * 3600_000); // 19:00 UTC
  h.engine.tick();
  assert.equal(h.last().gateActive, false);
  assert.equal(h.last().lockMode, "free");
  h.engine.arm();
  assert.equal(h.last().lockMode, "shield");
  h.engine.disarm();
  assert.equal(h.last().lockMode, "free");
});

test("plan → review → confirm unlocks; hourly check-in warns then locks; back to work unlocks", async () => {
  const h = harness();
  h.engine.startPlanning();
  assert.equal(h.last().phase, "planning");
  assert.equal(h.last().lockMode, "shield");

  await h.engine.submitInk({ purpose: "plan", text: "intention: ship the gate\n1. write the engine\n2. test it\n- buy milk" });
  assert.equal(h.last().phase, "reviewing");
  const plan = h.last().session!.plan;
  assert.equal(plan.intention, "ship the gate");
  assert.deepEqual(plan.priorities, ["write the engine", "test it"]);
  assert.equal(plan.todos[0]!.text, "buy milk");
  assert.equal(h.assistant.length, 1);

  h.engine.confirmPlan();
  assert.equal(h.last().phase, "working");
  assert.equal(h.last().lockMode, "free");
  assert.equal(h.last().nextCheckinAt, h.clock.now() + 60 * 60_000);

  h.clock.advance(60 * 60_000);
  assert.equal(h.last().phase, "checkin_warn");
  assert.equal(h.last().lockMode, "free");
  assert.ok(h.last().banner);
  assert.equal(h.last().banner!.canSnooze, true);

  h.clock.advance(120_000);
  assert.equal(h.last().phase, "checkin");
  assert.equal(h.last().lockMode, "shield");
  assert.match(h.last().shield!.title, /Check-in/);

  await h.engine.submitInk({ purpose: "checkin", text: "where: halfway through the engine\nhappened: tests pass\nstuck: naming\nnext: write the hub" });
  assert.equal(h.last().phase, "checkin");
  assert.equal(h.last().session!.checkins.length, 1);
  assert.match(h.last().session!.checkins[0]!.aiReply, /stuck on naming/);

  h.engine.backToWork();
  assert.equal(h.last().phase, "working");
  assert.equal(h.last().lockMode, "free");
});

test("snooze works once per check-in and delays the lock", () => {
  const h = harness();
  h.engine.startPlanning();
  h.engine.confirmPlan({ intention: "x", priorities: ["y"], todos: [] });
  h.clock.advance(60 * 60_000);
  assert.equal(h.last().phase, "checkin_warn");
  h.engine.snooze();
  assert.equal(h.last().phase, "working");
  assert.equal(h.last().lockMode, "free");
  h.clock.advance(15 * 60_000);
  assert.equal(h.last().phase, "checkin_warn");
  assert.equal(h.last().banner!.canSnooze, false);
  h.engine.snooze();
  assert.ok(h.errors.includes("snoozed"));
  h.clock.advance(120_000);
  assert.equal(h.last().phase, "checkin");
});

test("gate asks at most maxQuestions, then unlock is allowed with an intention", async () => {
  const h = harness();
  h.engine.startPlanning();
  await h.engine.submitInk({ purpose: "plan", text: "1. thing one\n2. thing two" }); // no intention line → first line becomes intention in mock
  // The mock treats the first bare line as the intention, so provide a truly empty one:
  const h2 = harness();
  h2.engine.startPlanning();
  await h2.engine.submitInk({ purpose: "plan", text: "" });
  assert.equal(h2.last().session!.questionsAsked, 1);
  assert.equal(h2.assistant[0]!.questions!.length, 1);
  await h2.engine.submitInk({ purpose: "reply", text: "" });
  assert.equal(h2.last().session!.questionsAsked, 2);
  await h2.engine.submitInk({ purpose: "reply", text: "" });
  assert.equal(h2.last().session!.questionsAsked, 2, "budget is capped by the server");
  assert.equal(h2.assistant[2]!.questions!.length, 0);
  h2.engine.confirmPlan();
  assert.ok(h2.errors.includes("incomplete"), "no intention → cannot unlock");
  await h2.engine.submitInk({ purpose: "reply", text: "make the demo work" });
  assert.equal(h2.last().session!.plan.intention, "make the demo work");
  h2.engine.confirmPlan();
  assert.equal(h2.last().phase, "working");
  void h;
});

test("calendar meeting turns shield into allowlist and pauses check-ins", () => {
  const start = new Date("2026-09-28T09:30:00Z");
  const end = new Date("2026-09-28T10:00:00Z");
  const h = harness({}, [{ title: "Standup", start, end, attendees: ["bob@example.com"], status: "CONFIRMED", allDay: false }]);
  assert.equal(h.last().lockMode, "shield");
  h.clock.advance(28 * 60_000); // 09:28 → inside the 2 min pre-roll
  h.engine.tick();
  assert.equal(h.last().lockMode, "allowlist");
  assert.equal(h.last().meeting?.title, "Standup");

  // Start a session during the meeting, confirm, then the meeting ends: check-in resumes.
  h.engine.startPlanning();
  h.engine.confirmPlan({ intention: "x", priorities: ["y"], todos: [] });
  assert.equal(h.last().lockMode, "free");
  h.clock.advance(40 * 60_000); // 10:08, meeting over (post-roll 2 min)
  h.engine.tick();
  assert.equal(h.last().meeting, null);
  assert.equal(h.last().phase, "working");
  assert.ok(h.last().nextCheckinAt! > h.clock.now(), "check-in was rescheduled after the meeting");
});

test("check-in warning is deferred while a meeting is running", () => {
  const start = new Date("2026-09-28T09:55:00Z");
  const end = new Date("2026-09-28T10:30:00Z");
  const h = harness({}, [{ title: "1:1", start, end, attendees: ["ann@example.com"], status: "CONFIRMED", allDay: false }]);
  h.engine.startPlanning();
  h.engine.confirmPlan({ intention: "x", priorities: ["y"], todos: [] });
  // The engine ticks itself once a minute; at 09:53 the pre-roll starts and the
  // pending 10:00 check-in (7 min away) is paused.
  h.clock.advance(55 * 60_000); // 09:55
  assert.equal(h.last().meeting?.title, "1:1");
  assert.equal(h.last().nextCheckinAt, null, "check-in paused during the meeting");
  h.clock.advance(6 * 60_000); // 10:01 — the hourly check-in would have been due at 10:00
  assert.equal(h.last().phase, "working", "no warning during a meeting");
  h.clock.advance(31 * 60_000 + 30_000); // 10:32:30 — meeting + post-roll over, engine tick resumed the timer
  assert.equal(h.last().meeting, null);
  assert.equal(h.last().phase, "working");
  const resumeAt = h.last().nextCheckinAt!;
  assert.ok(resumeAt >= h.clock.now() + 5 * 60_000 - 60_000, "at least a five-minute landing after the meeting");
  h.clock.advance(resumeAt - h.clock.now() + 1000);
  assert.equal(h.last().phase, "checkin_warn");
});

test("manual meeting pass is limited per day and logged", () => {
  const h = harness();
  assert.equal(h.last().manualPassesLeftToday, 1);
  h.engine.manualMeetingPass(30);
  assert.equal(h.last().lockMode, "allowlist");
  assert.equal(h.last().meeting?.source, "manual");
  assert.equal(h.last().manualPassesLeftToday, 0);
  h.engine.manualMeetingPass(30);
  assert.ok(h.errors.includes("no_passes"));
  h.clock.advance(31 * 60_000);
  assert.equal(h.last().lockMode, "shield");
  const dayEvents = new Store(h.root).dayEvents(new Date(h.clock.now()));
  assert.ok(dayEvents.some((e) => e.kind === "meeting_pass"));
});

test("emergency unlock needs a reason, frees the Mac for 30 min, and is logged", () => {
  const h = harness();
  h.engine.emergencyUnlock("short");
  assert.ok(h.errors.includes("reason_too_short"));
  assert.equal(h.last().lockMode, "shield");
  h.engine.emergencyUnlock("The printer driver install needs the screen right now.");
  assert.equal(h.last().lockMode, "free");
  assert.ok(h.last().emergencyUntil);
  h.clock.advance(30 * 60_000 + 1);
  assert.equal(h.last().lockMode, "shield");
  const dayEvents = new Store(h.root).dayEvents(new Date(h.clock.now()));
  assert.equal(dayEvents.filter((e) => e.kind === "emergency_unlock").length, 1);
});

test("wrap-up closes the session and the Mac returns to gated", async () => {
  const h = harness();
  h.engine.startPlanning();
  h.engine.confirmPlan({ intention: "x", priorities: ["y"], todos: [{ id: "a", text: "t", done: false }] });
  h.engine.toggleTodo("a", true);
  assert.equal(h.last().session!.plan.todos[0]!.done, true);
  h.engine.endSession();
  assert.equal(h.last().phase, "wrapup");
  assert.equal(h.last().lockMode, "shield");
  await h.engine.submitInk({ purpose: "wrapup", text: "done: engine and tests\nnext: the PWA" });
  assert.match(h.last().session!.wrapup!.summary, /engine and tests/);
  h.engine.closeWrapup();
  assert.equal(h.last().phase, "idle");
  assert.equal(h.last().session, null);
  const saved = new Store(h.root).listSessions();
  assert.equal(saved.length, 1);
  assert.ok(saved[0]!.endedAt);
});

test("sessions auto-end after maxHours", () => {
  const h = harness({ session: { maxHours: 1 } });
  h.engine.startPlanning();
  h.engine.confirmPlan({ intention: "x", priorities: ["y"], todos: [] });
  h.clock.advance(61 * 60_000);
  h.engine.tick();
  assert.equal(h.last().phase, "wrapup");
});

test("an open session is resumed after a restart", () => {
  const h = harness();
  h.engine.startPlanning();
  h.engine.confirmPlan({ intention: "resume me", priorities: ["y"], todos: [] });
  h.engine.stop();
  const cfg = h.cfg;
  const states: StateSnapshot[] = [];
  const e2 = new Engine({
    config: () => cfg,
    publicConfig: () => ({ ...cfg }),
    store: new Store(h.root),
    brain: new MockBrain(),
    calendar: h.calendar,
    clock: h.clock,
    onChange: (s) => states.push(s),
    onAssistant: () => {},
    onBusy: () => {},
    onError: () => {},
  });
  e2.start();
  assert.equal(states.at(-1)!.phase, "working");
  assert.equal(states.at(-1)!.session!.plan.intention, "resume me");
  e2.stop();
});
