import type { Checkin, InkPurpose, Plan, PublicConfig, Session, StateSnapshot, Todo } from "@twelve/protocol";
import type { Ctx, Screen } from "./app.js";
import { InkCanvas, TEMPLATES } from "./ink.js";
import { h, clear, put, fmtCountdown, fmtDate, fmtElapsed, fmtTime, toast } from "./util.js";
import { startVoice, type VoiceSession } from "./voice.js";
import { saveConnection } from "./ws.js";

type TickScreen = Screen & { tick?: () => void };

function nav(here: string) {
  return h(
    "nav.nav",
    null,
    h("a", { href: "#/", class: here === "home" ? "here" : "" }, "Today"),
    h("a", { href: "#/history", class: here === "history" ? "here" : "" }, "History"),
    h("a", { href: "#/settings", class: here === "settings" ? "here" : "" }, "Settings"),
  );
}

/** Two-tap confirmation for destructive buttons (no modal dialogs on a tablet). */
function twoTap(label: string, confirmLabel: string, cls: string, action: () => void): HTMLElement {
  let armed = false;
  let timer = 0;
  const btn = h(`button.btn.${cls}`, {
    onclick: () => {
      if (!armed) {
        armed = true;
        btn.textContent = confirmLabel;
        timer = window.setTimeout(() => {
          armed = false;
          btn.textContent = label;
        }, 4000);
        return;
      }
      clearTimeout(timer);
      action();
    },
  }, label);
  return btn;
}

// ---------------------------------------------------------------------------
// Pair
// ---------------------------------------------------------------------------

export function pair(_ctx: Ctx): Screen {
  const input = h("input", { type: "url", placeholder: "http://192.168.1.20:7712/?token=…", autocapitalize: "off", autocomplete: "off" }) as HTMLInputElement;
  const err = h("p.mute.small");
  const go = () => {
    try {
      const u = new URL(input.value.trim());
      const token = u.searchParams.get("token");
      if (!token) throw new Error("no token");
      saveConnection({ serverUrl: `${u.protocol}//${u.host}`, token });
      location.href = `${u.protocol}//${u.host}/?token=${encodeURIComponent(token)}`;
    } catch {
      err.textContent = "That does not look like a Twelve pairing link. It should end in ?token=…";
    }
  };
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") go();
  });
  const el = h(
    "section.screen",
    null,
    h("div.hero", null, h("h1", null, "Pair with your Mac"), h("p.mute.big", null, "On the Mac, click the 12 in the menu bar and choose “Open Daylight pairing page”. Scan the QR code with this tablet, or paste the link here.")),
    h("div.field", null, h("label", null, "Pairing link"), input),
    err,
    h("div.row", null, h("button.btn.primary", { onclick: go }, "Connect")),
    h("p.mute.small", null, "Both devices need to be on the same Wi-Fi, or on Tailscale."),
  );
  return { el };
}

// ---------------------------------------------------------------------------
// Home / dashboard
// ---------------------------------------------------------------------------

export function home(ctx: Ctx): TickScreen {
  const el = h("section.screen");
  let armedEnd: HTMLElement | null = null;

  const render = () => {
    const s = ctx.state;
    clear(el);
    if (!s) {
      put(el, h("div.hero", null, h("h1", null, ctx.connected ? "Loading…" : "Connecting to your Mac…"), h("p.mute", null, "If this takes a while, make sure the Mac is awake and on the same network.")), nav("home"));
      return;
    }
    if (s.phase === "idle") renderIdle(s);
    else renderDashboard(s);
    put(el, nav("home"));
  };

  const meetingCard = (s: StateSnapshot) =>
    s.meeting
      ? h("div.card", null, h("div.label", null, s.meeting.source === "manual" ? "Meeting pass" : "Calendar"), h("div.big", null, s.meeting.title), h("p.mute", null, `Until ${fmtTime(s.meeting.end)}. The Mac is in meeting mode: only allowlisted apps open.`))
      : null;

  const passButton = (s: StateSnapshot) =>
    h(
      "button.btn.ghost",
      { onclick: () => ctx.send({ type: "meeting.pass" }), disabled: s.manualPassesLeftToday <= 0 || Boolean(s.meeting) },
      `Meeting pass · ${s.manualPassesLeftToday} left today`,
    );

  const renderIdle = (s: StateSnapshot) => {
    const gated = s.gateActive;
    put(el, 
      h(
        "div.hero",
        null,
        h("h1", null, gated ? "Your Mac is waiting." : "Outside work hours."),
        h("p.mute.big", null, gated ? "Write your intention and priorities by hand. Then it unlocks." : "The Mac is free. You can still do the ritual, or arm the gate for a session."),
      ),
      h("button.btn.primary.huge.wide", { onclick: () => ctx.send({ type: "plan.start" }) }, gated ? "Plan & unlock the Mac" : "Plan a session"),
      h(
        "div.row",
        null,
        gated
          ? s.armedManually
            ? h("button.btn.ghost", { onclick: () => ctx.send({ type: "gate.disarm" }) }, "Disarm the gate")
            : null
          : h("button.btn.ghost", { onclick: () => ctx.send({ type: "gate.arm" }) }, "Arm the gate"),
        passButton(s),
      ),
      meetingCard(s),
      s.emergencyUntil ? h("div.card", null, h("div.label", null, "Emergency unlock"), h("p", null, `The Mac is free until ${fmtTime(s.emergencyUntil)}. It is in today's log, no shame.`)) : null,
      !s.clients.mac ? h("p.mute.small", null, "The Mac app is not connected right now. The plan still gets saved; the Mac follows along when it reconnects.") : null,
    );
  };

  const renderDashboard = (s: StateSnapshot) => {
    const sess = s.session!;
    const plan = sess.plan;
    if (s.phase === "checkin_warn" && s.checkinLocksAt) {
      put(el, 
        h(
          "div.banner",
          null,
          h("div", null, h("div.label", null, "Check-in soon"), h("div.count", { class: "count warn" }, fmtCountdown(s.checkinLocksAt - Date.now())), h("p.mute", null, "Finish your thought. Then the Mac pauses until you write a short check-in.")),
          h(
            "div.stack",
            null,
            h("button.btn.primary", { onclick: () => ctx.send({ type: "checkin.now" }) }, "Check in now"),
            s.banner?.canSnooze ? h("button.btn.ghost", { onclick: () => ctx.send({ type: "checkin.snooze" }) }, `Snooze ${s.config.checkin.snoozeMinutes} min`) : null,
          ),
        ),
      );
    }
    put(el, 
      h("div", null, h("div.label", null, "Intention"), h("div.intention", null, plan.intention || "—")),
      plan.priorities.length
        ? h("div", null, h("div.label", null, "Priorities"), h("ol.plist", null, plan.priorities.map((p, i) => h("li", null, h("span.n", null, String(i + 1)), h("span", null, p)))))
        : null,
      plan.todos.length ? h("div", null, h("div.label", null, "To-do"), h("div.stack", null, plan.todos.map((t) => todoRow(ctx, t)))) : null,
      meetingCard(s),
      h(
        "p.mute",
        null,
        `Started ${fmtTime(sess.startedAt)} · ${fmtElapsed(Date.now() - Date.parse(sess.startedAt))}`,
        s.nextCheckinAt ? ` · next check-in ${fmtTime(s.nextCheckinAt)} (in ${fmtCountdown(s.nextCheckinAt - Date.now())})` : s.meeting ? " · check-ins wait for the meeting to end" : "",
      ),
      h(
        "div.row",
        null,
        h("button.btn", { onclick: () => ctx.send({ type: "checkin.now" }) }, "Check in now"),
        h("button.btn.ghost", { onclick: () => ctx.navigate("review") }, "Edit plan"),
        (armedEnd = twoTap("Done for now", "Tap again to wrap up", "ghost", () => ctx.send({ type: "session.end" }))),
        passButton(s),
      ),
      sess.checkins.length
        ? h(
            "div",
            null,
            h("div.label", null, "Check-ins"),
            h("div.stack", null, [...sess.checkins].reverse().map((c) => checkinCard(c))),
          )
        : null,
    );
  };

  render();
  return {
    el,
    update: () => {
      render();
    },
    tick: () => {
      // Cheap live updates without rebuilding the DOM.
      const s = ctx.state;
      if (!s) return;
      const c = el.querySelector(".count.warn");
      if (c && s.checkinLocksAt) c.textContent = fmtCountdown(s.checkinLocksAt - Date.now());
      if (s.phase === "working" && s.nextCheckinAt && Date.now() % 60_000 < 1000) render();
      void armedEnd;
    },
  };
}

function todoRow(ctx: Ctx, t: Todo): HTMLElement {
  const cb = h("input", { type: "checkbox", checked: t.done, onchange: () => ctx.send({ type: "todo.toggle", id: t.id, done: cb.checked }) }) as HTMLInputElement;
  return h("label.todo", { class: t.done ? "todo done" : "todo" }, cb, h("span", null, t.text));
}

function checkinCard(c: Checkin): HTMLElement {
  return h(
    "div.card",
    null,
    h("div.row.spread", null, h("strong", null, fmtTime(c.at)), h("span.mute.small", null, c.stuck ? `stuck on: ${c.stuck}` : "")),
    c.where ? h("p", null, h("span.mute", null, "Where: "), c.where) : null,
    c.happened ? h("p", null, h("span.mute", null, "Happened: "), c.happened) : null,
    c.next ? h("p", null, h("span.mute", null, "Next: "), c.next) : null,
    c.aiReply ? h("div.coach", null, c.aiReply) : null,
  );
}

// ---------------------------------------------------------------------------
// Writing panel (shared by plan / reply / check-in / wrap-up)
// ---------------------------------------------------------------------------

const TITLES: Record<InkPurpose, string> = {
  plan: "Plan by hand",
  reply: "Your answer",
  checkin: "Where are you?",
  wrapup: "Wrap up",
};

interface WritePanelOpts {
  purpose: InkPurpose;
  /** Extra buttons on the left of the footer (e.g. skip). */
  extras?: HTMLElement[];
  prompt?: string;
}

export function writePanel(ctx: Ctx, opts: WritePanelOpts): TickScreen {
  const purpose = opts.purpose;
  let typed = false;
  let submitted = false;
  const page = h("div.page");
  const textarea = h("textarea", { placeholder: purpose === "plan" ? "Intention: …\n1. …\n2. …\n- to-do …" : "Type here…" }) as HTMLTextAreaElement;
  const typedWrap = h("div.typed", { style: { display: "none" } }, textarea);
  page.appendChild(typedWrap);
  const canvas = new InkCanvas(page, TEMPLATES[purpose] ?? TEMPLATES.plan!);
  try {
    canvas.penOnly = localStorage.getItem("twelve.penOnly") === "1";
  } catch {
    /* ignore */
  }

  const doneBtn = h("button.btn.primary", { onclick: () => submit() }, "I'm done") as HTMLButtonElement;
  const status = h("span.mute.small");
  const toolBtn = (label: string, on: () => void, extra = "") => h(`button.btn.iconbtn${extra}`, { onclick: on }, label);
  const penBtn = toolBtn("Pen", () => setTool("pen"), ".active");
  const eraserBtn = toolBtn("Eraser", () => setTool("eraser"));
  const typeBtn = toolBtn("Type instead", () => setTyped(!typed));
  const setTool = (t: "pen" | "eraser") => {
    canvas.tool = t;
    penBtn.classList.toggle("active", t === "pen");
    eraserBtn.classList.toggle("active", t === "eraser");
  };
  const setTyped = (on: boolean) => {
    typed = on;
    typedWrap.style.display = on ? "block" : "none";
    typeBtn.textContent = on ? "Write instead" : "Type instead";
    typeBtn.classList.toggle("active", on);
    if (on) textarea.focus();
    refresh();
  };
  const refresh = () => {
    const busy = Boolean(ctx.state?.aiBusy) || submitted;
    const empty = typed ? !textarea.value.trim() : canvas.isEmpty;
    doneBtn.disabled = busy || empty;
    clear(status);
    if (busy) status.append(h("span.busy", null, h("span.spinner"), "Reading your page…"));
    else if (!ctx.connected) status.textContent = "Not connected to the Mac. Your page will send when it reconnects.";
    else status.textContent = "";
  };
  canvas.onChange = refresh;
  textarea.addEventListener("input", refresh);

  const submit = () => {
    if (doneBtn.disabled) return;
    const text = typed ? textarea.value.trim() : "";
    const png = canvas.isEmpty ? undefined : canvas.toPNG();
    if (!text && !png) return;
    submitted = true;
    refresh();
    ctx.send({ type: "ink.submit", purpose, png, text: text || undefined, via: typed && !png ? "text" : "ink" });
  };

  const coachLine = () => {
    const ai = ctx.lastAi;
    if (purpose !== "reply" || !ai) return opts.prompt ? h("div.coach", null, opts.prompt) : null;
    return h("div.coach", null, ai.text, ...ai.questions.map((q) => h("div.q", null, q)));
  };
  const coachSlot = h("div");

  const el = h(
    "section.screen.fill.write",
    null,
    h(
      "div.toolbar",
      null,
      h("h2", null, TITLES[purpose]),
      h("span.grow"),
      penBtn,
      eraserBtn,
      toolBtn("Undo", () => canvas.undo()),
      toolBtn("Clear", () => canvas.clear()),
      typeBtn,
    ),
    coachSlot,
    page,
    h("div.footer", null, ...(opts.extras ?? []), h("span.grow", { style: { flex: "1" } }), status, doneBtn),
  );
  // Keyboard fallback is a real feature (dead pen, or a laptop in the loop), not a hidden test hook.
  el.dataset.purpose = purpose;

  const update = () => {
    clear(coachSlot);
    const c = coachLine();
    if (c) coachSlot.appendChild(c);
    // If the server reported an error after our submit, allow trying again.
    if (submitted && ctx.state && !ctx.state.aiBusy) {
      const lastUser = [...(ctx.state.session?.transcript ?? [])].reverse()[0];
      if (lastUser?.role === "assistant") submitted = false; // the coach answered; phase routing takes over
      else if (!ctx.state.aiBusy) submitted = false;
    }
    refresh();
  };
  update();
  return { el, update, unmount: () => canvas.destroy() };
}

export function write(ctx: Ctx, arg?: string): TickScreen {
  const purpose = (["plan", "reply", "checkin", "wrapup"].includes(arg ?? "") ? arg : "plan") as InkPurpose;
  const extras: HTMLElement[] = [];
  if (purpose === "plan") extras.push(twoTap("Cancel", "Tap again to cancel", "ghost", () => ctx.send({ type: "session.end" })));
  if (purpose === "reply") extras.push(h("button.btn.ghost", { onclick: () => ctx.navigate("review") }, "Back"));
  return writePanel(ctx, { purpose, extras });
}

// ---------------------------------------------------------------------------
// Review (after a plan page) and plan editor (while working)
// ---------------------------------------------------------------------------

export function review(ctx: Ctx): TickScreen {
  const el = h("section.screen");
  let form: { el: HTMLElement; read: () => Plan } | null = null;
  let formKey = "";
  let voice: VoiceSession | null = null;
  const voiceStatus = h("span.mute.small");

  const render = () => {
    const s = ctx.state;
    const sess = s?.session;
    if (!s || !sess) {
      clear(el);
      put(el, h("p.mute", null, "No session."), nav("home"));
      return;
    }
    const key = JSON.stringify(sess.plan);
    if (!form || formKey !== key) {
      form = planForm(sess.plan);
      formKey = key;
    }
    const lastUser = [...sess.transcript].reverse().find((t) => t.role === "user");
    const ai = s.lastAssistant;
    const reviewing = s.phase === "reviewing";
    const questions = reviewing ? ai?.questions ?? [] : [];
    const answer = h("input", { type: "text", placeholder: "…or type a short answer" }) as HTMLInputElement;
    const sendAnswer = () => {
      const t = answer.value.trim();
      if (!t) return;
      ctx.send({ type: "ink.submit", purpose: "reply", text: t, via: "text" });
      answer.value = "";
    };
    answer.addEventListener("keydown", (e) => {
      if (e.key === "Enter") sendAnswer();
    });

    clear(el);
    put(el, 
      h("div.hero", null, h("h1", null, reviewing ? "Here's what I read" : "Your plan")),
      reviewing && lastUser ? h("div", null, h("div.label", null, "Your page"), h("div.transcript", null, lastUser.text)) : null,
      ai && reviewing ? h("div.coach", null, ai.text, ...questions.map((q) => h("div.q", null, q))) : null,
      questions.length
        ? h(
            "div.row",
            null,
            h("button.btn", { onclick: () => ctx.navigate("write/reply") }, "Answer by writing"),
            h("div", { style: { flex: "1", minWidth: "240px" } }, answer),
            h("button.btn.ghost", { onclick: sendAnswer }, "Send"),
          )
        : null,
      s.aiBusy ? h("p.busy", null, h("span.spinner"), "Reading…") : null,
      form.el,
      h(
        "div.row",
        null,
        reviewing
          ? h("button.btn.primary.huge", { onclick: () => ctx.send({ type: "plan.confirm", plan: form!.read() }), disabled: s.aiBusy }, "Looks right, unlock my Mac")
          : h("button.btn.primary", { onclick: () => { ctx.send({ type: "plan.edit", plan: form!.read() }); ctx.navigate("home"); } }, "Save changes"),
        reviewing ? h("button.btn.ghost", { onclick: () => ctx.navigate("write/plan") }, "Rewrite the page") : h("button.btn.ghost", { onclick: () => ctx.navigate("home") }, "Back"),
        h(
          "button.btn.ghost",
          {
            onclick: async () => {
              if (voice) {
                voice.stop();
                voice = null;
                voiceStatus.textContent = "Voice stopped.";
                return;
              }
              voiceStatus.textContent = "Starting voice…";
              try {
                voice = await startVoice(ctx.client!, {
                  onStatus: (t) => (voiceStatus.textContent = t),
                  onUserText: (t) => ctx.send({ type: "ink.submit", purpose: reviewing ? "reply" : "plan", text: t, via: "voice" }),
                  onAssistantText: (t) => toast(t, 6000),
                });
              } catch (err) {
                voiceStatus.textContent = `Voice failed: ${(err as Error).message}`;
              }
            },
          },
          "Talk instead",
        ),
        voiceStatus,
      ),
      nav("home"),
    );
  };
  render();
  return {
    el,
    update: render,
    unmount: () => voice?.stop(),
  };
}

function planForm(plan: Plan): { el: HTMLElement; read: () => Plan } {
  const intention = h("input", { type: "text", value: plan.intention, placeholder: "What is this session for?" }) as HTMLInputElement;
  const prios = [0, 1, 2].map((i) => h("input", { type: "text", value: plan.priorities[i] ?? "", placeholder: `Priority ${i + 1}` }) as HTMLInputElement);
  const todoList = h("div.stack");
  const todos: { id: string; input: HTMLInputElement; done: boolean }[] = [];
  const addTodo = (t?: Todo) => {
    const input = h("input", { type: "text", value: t?.text ?? "", placeholder: "To-do" }) as HTMLInputElement;
    const entry = { id: t?.id ?? "", input, done: t?.done ?? false };
    todos.push(entry);
    const row = h("div.row", null, h("div", { style: { flex: "1" } }, input), h("button.btn.ghost.iconbtn", { onclick: () => { row.remove(); todos.splice(todos.indexOf(entry), 1); }, "aria-label": "Remove" }, "×"));
    todoList.appendChild(row);
  };
  plan.todos.forEach((t) => addTodo(t));
  const el = h(
    "div.card.stack",
    null,
    h("div.field", null, h("label", null, "Intention"), intention),
    h("div.field", null, h("label", null, "Priorities"), ...prios),
    h("div.field", null, h("label", null, "To-do"), todoList, h("button.btn.ghost", { onclick: () => addTodo() }, "+ Add a to-do")),
  );
  return {
    el,
    read: () => ({
      intention: intention.value,
      priorities: prios.map((p) => p.value).filter((v) => v.trim()),
      todos: todos.map((t) => ({ id: t.id, text: t.input.value, done: t.done })).filter((t) => t.text.trim()),
      notes: plan.notes,
    }),
  };
}

// ---------------------------------------------------------------------------
// Check-in
// ---------------------------------------------------------------------------

export function checkin(ctx: Ctx): TickScreen {
  const el = h("section.screen.fill");
  let inner: TickScreen | null = null;
  let mode = "";

  const replyReady = (s: StateSnapshot) => {
    const last = s.session?.checkins.at(-1);
    return Boolean(last && Date.parse(last.at) >= ctx.checkinStartedAt - 1000);
  };

  const render = () => {
    const s = ctx.state;
    if (!s?.session) return;
    const want = replyReady(s) ? "reply" : "write";
    if (want === mode) {
      inner?.update?.(ctx);
      if (want === "reply") renderReply(s.session);
      return;
    }
    mode = want;
    inner?.unmount?.();
    inner = null;
    clear(el);
    if (want === "write") {
      inner = writePanel(ctx, {
        purpose: "checkin",
        prompt: s.session.plan.intention ? `Intention: ${s.session.plan.intention}` : undefined,
        extras: [h("button.btn.ghost", { onclick: () => ctx.send({ type: "checkin.back" }) }, "Skip this time")],
      });
      el.appendChild(inner.el);
    } else renderReply(s.session);
  };

  const renderReply = (sess: Session) => {
    const c = sess.checkins.at(-1)!;
    clear(el);
    put(el, 
      h(
        "div.screen",
        null,
        h("div.hero", null, h("h1", null, "Noted.")),
        checkinCard(c),
        h("p.mute", null, `Intention: ${sess.plan.intention}`),
        h("button.btn.primary.huge.wide", { onclick: () => ctx.send({ type: "checkin.back" }) }, "Back to work"),
      ),
    );
  };

  render();
  return { el, update: render, unmount: () => inner?.unmount?.() };
}

// ---------------------------------------------------------------------------
// Wrap-up
// ---------------------------------------------------------------------------

export function wrapup(ctx: Ctx): TickScreen {
  const el = h("section.screen.fill");
  let inner: TickScreen | null = null;
  let mode = "";
  const render = () => {
    const s = ctx.state;
    const sess = s?.session;
    if (!sess) return;
    const want = sess.wrapup ? "summary" : "write";
    if (want === mode) {
      inner?.update?.(ctx);
      return;
    }
    mode = want;
    inner?.unmount?.();
    inner = null;
    clear(el);
    if (want === "write") {
      inner = writePanel(ctx, {
        purpose: "wrapup",
        prompt: `Intention was: ${sess.plan.intention}`,
        extras: [h("button.btn.ghost", { onclick: () => ctx.send({ type: "wrapup.close" }) }, "Skip wrap-up")],
      });
      el.appendChild(inner.el);
      return;
    }
    const done = sess.plan.todos.filter((t) => t.done).length;
    put(el, 
      h(
        "div.screen",
        null,
        h("div.hero", null, h("h1", null, "Session closed.")),
        h("div.coach", null, sess.wrapup!.summary),
        h("p.mute", null, `${fmtTime(sess.startedAt)} – ${fmtTime(Date.now())} · ${sess.checkins.length} check-ins · ${done}/${sess.plan.todos.length} to-dos done`),
        h("button.btn.primary.huge.wide", { onclick: () => ctx.send({ type: "wrapup.close" }) }, "Close the day"),
      ),
    );
  };
  render();
  return { el, update: render, unmount: () => inner?.unmount?.() };
}

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

export function history(ctx: Ctx): Screen {
  const list = h("div");
  const el = h("section.screen", null, h("div.hero", null, h("h1", null, "History")), list, nav("history"));
  const load = async () => {
    if (!ctx.client) return;
    try {
      const sessions = await ctx.client.api<Session[]>("/api/sessions?limit=60");
      clear(list);
      if (!sessions.length) put(list, h("p.mute", null, "No sessions yet."));
      for (const s of sessions) list.appendChild(sessionDetails(ctx, s));
    } catch (err) {
      put(list, h("p.mute", null, `Could not load history: ${(err as Error).message}`));
    }
  };
  void load();
  return { el };
}

function sessionDetails(ctx: Ctx, s: Session): HTMLElement {
  const inks = s.transcript.filter((t) => t.inkFile).map((t) => t.inkFile!);
  for (const c of s.checkins) if (c.inkFile) inks.push(c.inkFile);
  if (s.wrapup?.inkFile) inks.push(s.wrapup.inkFile);
  const emergencies = s.events.filter((e) => e.kind === "emergency_unlock");
  return h(
    "details.hist",
    null,
    h("summary", null, h("span", null, h("strong", null, fmtDate(s.startedAt)), " · ", s.plan.intention || "(no intention)"), h("span.mute.small", null, `${fmtTime(s.startedAt)}${s.endedAt ? "–" + fmtTime(s.endedAt) : " (open)"} · ${s.checkins.length} check-ins`)),
    h("div.stack", { style: { marginTop: "10px" } },
      s.plan.priorities.length ? h("ol.plist", null, s.plan.priorities.map((p, i) => h("li", null, h("span.n", null, String(i + 1)), p))) : null,
      s.plan.todos.length ? h("div", null, s.plan.todos.map((t) => h("div.todo", { class: t.done ? "todo done" : "todo" }, h("span", null, (t.done ? "☑ " : "☐ ") + t.text)))) : null,
      ...s.checkins.map((c) => checkinCard(c)),
      s.wrapup ? h("div.coach", null, s.wrapup.summary) : null,
      emergencies.length ? h("p.mute.small", null, `Emergency unlocks: ${emergencies.map((e) => `${fmtTime(e.at)} — ${e.detail ?? ""}`).join("; ")}`) : null,
      inks.length && ctx.client ? h("div.thumbs", null, inks.map((f) => h("a", { href: ctx.client!.inkUrl(f), target: "_blank" }, h("img", { src: ctx.client!.inkUrl(f), loading: "lazy", alt: "handwritten page" })))) : null,
    ),
  );
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

export function settings(ctx: Ctx): Screen {
  const el = h("section.screen");
  let built = false;

  const build = (cfg: PublicConfig) => {
    built = true;
    const num = (v: number, min = 0) => h("input", { type: "number", value: String(v), min: String(min) }) as HTMLInputElement;
    const text = (v: string, placeholder = "") => h("input", { type: "text", value: v, placeholder }) as HTMLInputElement;
    const lines = (v: string[], placeholder = "") => h("textarea", { value: v.join("\n"), placeholder }) as HTMLTextAreaElement;
    const check = (v: boolean) => h("input", { type: "checkbox", checked: v }) as HTMLInputElement;
    const select = (v: string, opts: string[]) => {
      const s = h("select") as HTMLSelectElement;
      for (const o of opts) s.appendChild(h("option", { value: o, selected: o === v }, o));
      return s;
    };
    const field = (label: string, input: HTMLElement, hint?: string) => h("div.field", null, h("label", null, label), input, hint ? h("span.mute.small", null, hint) : null);

    const dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    const days = dayNames.map((d, i) => ({ i, cb: check(cfg.schedule.days.includes(i)), d }));
    const start = h("input", { type: "time", value: cfg.schedule.start }) as HTMLInputElement;
    const end = h("input", { type: "time", value: cfg.schedule.end }) as HTMLInputElement;
    const tz = text(cfg.schedule.timezone, Intl.DateTimeFormat().resolvedOptions().timeZone);
    const interval = num(cfg.checkin.intervalMinutes, 5);
    const warning = num(cfg.checkin.warningSeconds, 10);
    const snooze = num(cfg.checkin.snoozeMinutes, 1);
    const maxQ = num(cfg.gate.maxQuestions, 0);
    const allow = lines(cfg.allowlist.bundleIds, "us.zoom.xos\ncom.apple.iCal");
    const ics = lines(cfg.calendar.icsUrls, "https://calendar.google.com/calendar/ical/…/basic.ics");
    const selfEmails = lines(cfg.calendar.selfEmails, "you@example.com");
    const reqAtt = check(cfg.calendar.requireAttendees);
    const pre = num(cfg.calendar.preRollMinutes);
    const post = num(cfg.calendar.postRollMinutes);
    const poll = num(cfg.calendar.pollMinutes, 1);
    const passMin = num(cfg.meetingPass.manualMinutes, 5);
    const passDay = num(cfg.meetingPass.manualPerDay, 0);
    const emHold = num(cfg.emergency.holdSeconds, 1);
    const emMin = num(cfg.emergency.unlockMinutes, 1);
    const emChars = num(cfg.emergency.minReasonChars, 0);
    const maxHours = num(cfg.session.maxHours, 1);
    const brainProv = select(cfg.brain.provider, ["anthropic", "mock"]);
    const model = text(cfg.brain.model);
    const voiceProv = select(cfg.voice.provider, ["text", "elevenlabs", "gemini-live"]);
    const elAgent = text(cfg.voice.elevenlabsAgentId, "agent id from the ElevenLabs dashboard");
    const gemModel = text(cfg.voice.geminiModel);
    const penOnly = check((() => { try { return localStorage.getItem("twelve.penOnly") === "1"; } catch { return false; } })());

    const save = () => {
      try {
        localStorage.setItem("twelve.penOnly", penOnly.checked ? "1" : "0");
      } catch {
        /* ignore */
      }
      const patch = {
        schedule: { days: days.filter((d) => d.cb.checked).map((d) => d.i), start: start.value, end: end.value, timezone: tz.value.trim() },
        checkin: { intervalMinutes: Number(interval.value), warningSeconds: Number(warning.value), snoozeMinutes: Number(snooze.value) },
        gate: { maxQuestions: Number(maxQ.value) },
        allowlist: { bundleIds: allow.value.split("\n").map((x) => x.trim()).filter(Boolean) },
        calendar: {
          icsUrls: ics.value.split("\n").map((x) => x.trim()).filter(Boolean),
          selfEmails: selfEmails.value.split("\n").map((x) => x.trim()).filter(Boolean),
          requireAttendees: reqAtt.checked,
          preRollMinutes: Number(pre.value),
          postRollMinutes: Number(post.value),
          pollMinutes: Number(poll.value),
        },
        meetingPass: { manualMinutes: Number(passMin.value), manualPerDay: Number(passDay.value) },
        emergency: { holdSeconds: Number(emHold.value), unlockMinutes: Number(emMin.value), minReasonChars: Number(emChars.value) },
        session: { maxHours: Number(maxHours.value) },
        brain: { provider: brainProv.value as "anthropic" | "mock", model: model.value.trim() },
        voice: { provider: voiceProv.value as "text" | "elevenlabs" | "gemini-live", elevenlabsAgentId: elAgent.value.trim(), geminiModel: gemModel.value.trim() },
      };
      ctx.send({ type: "config.update", config: patch });
      toast("Saved.");
    };

    clear(el);
    put(el, 
      h("div.hero", null, h("h1", null, "Settings")),
      h("div.card.stack", null, h("h2", null, "Gate schedule"),
        h("div.row", null, ...days.map((d) => h("label.todo", null, d.cb, h("span", null, d.d)))),
        h("div.grid2", null, field("Gated from", start), field("Until", end)),
        field("Time zone", tz, "IANA name, e.g. America/Los_Angeles. Empty = the Mac's zone."),
      ),
      h("div.card.stack", null, h("h2", null, "Check-ins"),
        h("div.grid2", null, field("Every (minutes)", interval), field("Warning before lock (seconds)", warning), field("Snooze (minutes)", snooze)),
        field("Clarifying questions the coach may ask before unlocking", maxQ),
        field("Session auto-ends after (hours)", maxHours),
      ),
      h("div.card.stack", null, h("h2", null, "Meetings"),
        field("Calendar ICS links (one per line)", ics, "Google: calendar settings → “Secret address in iCal format”. Outlook: “Publish calendar” → ICS link."),
        field("Your e-mail addresses (one per line)", selfEmails, "So an event counts as a meeting only when someone else is invited."),
        h("label.todo", null, reqAtt, h("span", null, "Only events with other attendees count as meetings")),
        h("div.grid2", null, field("Unlock minutes before", pre), field("Keep unlocked minutes after", post), field("Refresh calendar every (minutes)", poll)),
        field("Apps that stay usable in meeting mode (bundle ids, one per line)", allow, "Find an id with: osascript -e 'id of app \"Zoom\"'"),
        h("div.grid2", null, field("Manual meeting pass length (minutes)", passMin), field("Manual passes per day", passDay)),
      ),
      h("div.card.stack", null, h("h2", null, "Emergency unlock"),
        h("div.grid2", null, field("Hold the button for (seconds)", emHold, "The Mac app defaults to 30 s."), field("Unlocks for (minutes)", emMin), field("Reason must be at least (characters)", emChars)),
      ),
      h("div.card.stack", null, h("h2", null, "Coach"),
        h("div.grid2", null, field("Reads handwriting with", brainProv, "mock = offline, for trying the flow"), field("Model", model)),
        h("div.grid2", null, field("Voice", voiceProv, "Needs ELEVENLABS_API_KEY or GEMINI_API_KEY on the Mac."), field("ElevenLabs agent id", elAgent), field("Gemini Live model", gemModel)),
      ),
      h("div.card.stack", null, h("h2", null, "This tablet"),
        h("label.todo", null, penOnly, h("span", null, "Pen only (ignore fingers while writing)")),
        h("p.mute.small", null, `Paired with ${ctx.client?.conn.serverUrl ?? "—"}`),
      ),
      h("div.row", null, h("button.btn.primary", { onclick: save }, "Save"), twoTap("Unpair this tablet", "Tap again to unpair", "ghost", () => { ctx.client?.close(); saveConnection(null); location.href = "/"; })),
      nav("settings"),
    );
  };

  const update = () => {
    if (!built && ctx.state) build(ctx.state.config);
    else if (!built) {
      clear(el);
      put(el, h("p.mute", null, "Connecting…"), nav("settings"));
    }
  };
  update();
  return { el, update };
}
