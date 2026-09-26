# Twelve — spec

Twelve gates your Mac behind a handwritten plan on your Daylight DC-1.
You cannot use the Mac during work hours until you have written an intention and
priorities by hand on the Daylight. An AI reads the ink, asks at most a couple
of short questions, and unlocks the Mac. Every hour it pauses you for a short
written check-in. No shame, no scoring: the point is to keep the real goal in
view and to make the pen-and-paper step come before the screen.

This document is the output of the grill-me session (2026-09-26). Every
decision below was either answered by you or is an explicit assumption you can
change. Config keys in `code font` map to `~/.twelve/config.json`.

## 1. Decisions log

| # | Question | Decision | Where it lives |
|---|----------|----------|----------------|
| 1 | Lock strength | **Firm gate with friction exit.** Full-screen shield on every display, Dock, menu bar, Cmd-Tab, force-quit disabled. Emergency unlock = 30 s press-and-hold plus a written reason, grants 30 min, logged in the session. | Mac app `LockController`, `emergency.holdSeconds`, `emergency.unlockMinutes` |
| 2 | Check-in | **Warn 2 min, then lock.** Every 60 min a banner counts down; then the Mac shields until you write a check-in on the Daylight. One 15 min snooze per check-in. | `checkin.intervalMinutes`, `checkin.warningSeconds`, `checkin.snoozeMinutes` |
| 3 | Server location | **On the Mac.** Node service under launchd, port 7712. Daylight reaches it over Wi-Fi or Tailscale; pairing by QR code. | `packages/server`, `scripts/install-mac.sh` |
| 4 | Daylight app | **PWA now, Android wrapper scaffold.** Full-screen web app in the DC-1 browser installed to the home screen, plus an uncompiled Kotlin WebView kiosk wrapper. | `packages/daylight`, `apps/android` |
| 5 | Schedule | **Work-hours window.** Gated weekdays 08:00–18:00 by default. Outside the window the Mac is free; you can arm the gate from the Daylight for an off-hours session. | `schedule.days`, `schedule.start`, `schedule.end`, `schedule.timezone` |
| 6 | Gate strictness | **Intention + 1 priority.** The AI must read one intention and at least one priority. If missing or vague it asks at most 2 short questions, then unlocks. It never judges plan quality. | `gate.maxQuestions` (2), brain system prompt |
| 7 | Exceptions | **Allowlist + calendar meeting pass.** While locked, allowlisted apps stay usable in *allowlist mode* (all other apps get hidden). A meeting pass is granted automatically when your Google/Outlook calendar shows a meeting in progress; it lifts the shield into allowlist mode for the meeting's duration and pauses check-ins. A manual meeting pass exists as a fallback (60 min, once per day, logged). | `allowlist.bundleIds`, `calendar.icsUrls`, `calendar.*`, `meetingPass.*` |
| 8 | Session end | **You close it from the Daylight.** "Done for now" opens a wrap-up page (what got done, what's next). The AI writes a 3-line summary and the Mac returns to gated. Sessions auto-end after 8 h. | `session.maxHours` |

Assumptions not asked (change freely):

- **AI provider**: Anthropic Claude (`claude-opus-5`) reads the ink and coaches. Pluggable via `brain.provider` (`anthropic` | `mock`).
- **Calendar source**: ICS feed URLs. Google Calendar's "secret address in iCal format" and Outlook's "publish calendar" ICS link both work without OAuth. A `CalendarProvider` interface leaves room for Google API / Microsoft Graph later.
- **Voice**: text conversation is the default. `VoiceProvider` scaffold for ElevenLabs Conversational AI and Gemini Live; each activates when its key is set.
- **Storage**: JSON files in `~/.twelve/` (config, sessions, ink PNGs). One user, one Mac, one Daylight.
- **Keyboard fallback**: the Daylight app has a "type instead" mode so a dead pen never locks you out.

## 2. The ritual (user's view)

1. 08:00, Mac shows the shield: *"Your Mac is waiting for your Daylight."*
2. On the Daylight: **Plan**. A page with three faint headings: *Intention*, *Priorities (up to 3)*, *To-do*. Write by hand. Tap **I'm done**.
3. **Review**. The AI shows what it read, structured. If it needs something ("I see three to-dos but no intention. What is today for?") it asks, you write or type the answer, at most twice.
4. Tap **Looks right, unlock my Mac**. The shield lifts. The Daylight becomes the dashboard: intention on top, priorities, to-dos you can tick, elapsed time, next check-in.
5. 09:00, Mac banner: *"Check-in in 2:00. Finish your thought."* (Snooze 15 min, once.)
6. Shield drops: *"Check-in time. Write where you are on the Daylight."* On the Daylight: *Where am I? / What happened? / Stuck on? / Next step*. The AI answers in two or three sentences, connects it to your intention, suggests the next concrete step if you wrote that you were stuck. Tap **Back to work**.
7. Meetings: when the calendar shows a meeting now, the shield becomes allowlist mode (Zoom, Calendar, whatever you listed) and check-ins wait until it ends.
8. **Done for now**: wrap-up page, AI summary, Mac gated again.

## 3. State machine (server is the source of truth)

```
                  ┌──────────── gate off (outside schedule, not armed) ────────────┐
                  │                                                                 │
   idle ──plan──▶ planning ──ink──▶ reviewing ──confirm──▶ working ──timer──▶ checkin_warn
    ▲                                  │  ▲                    ▲                    │
    │                                  └──┘ (questions ≤ 2)     │ snooze (once)      │ timer
    │                                                           │                    ▼
    │                                                       back to work ◀────── checkin
    │                                                                                
    └──────────────── wrapup ◀──── done for now (from working / checkin) ───────────┘
```

| Phase | Mac lock mode | Daylight screen |
|-------|---------------|-----------------|
| `idle`, gate on | `shield` | Home: "Plan & unlock" |
| `idle`, gate off | `free` | Home: "Arm the gate" |
| `planning` | `shield` | Write (plan template) |
| `reviewing` | `shield` | Review (transcript, plan, AI questions) |
| `working` | `free` | Dashboard |
| `checkin_warn` | `free` + banner | Dashboard with countdown, "Check in now" |
| `checkin` | `shield` | Write (check-in template) then AI reply |
| `wrapup` | `shield` | Write (wrap-up template) then summary |

Overlays that modify the lock mode:

- **Meeting** (calendar or manual pass): any `shield` becomes `allowlist`; check-in timers pause; the phase does not change.
- **Emergency unlock**: any mode becomes `free` for `emergency.unlockMinutes`, then the previous mode returns. Logged as an event on the session (or on a standalone day log when there is no session).
- **Server unreachable**: the Mac keeps its last mode. The emergency exit works offline.

Timers (server side): check-in interval, warning countdown, snooze, meeting-pass expiry, emergency expiry, session max length, schedule boundaries. All timers are wall-clock based and survive a server restart by being recomputed from persisted timestamps.

## 4. Protocol

Transport: one WebSocket per client at `ws://<mac>:7712/ws?token=<pairing token>`. JSON messages `{ "type": ..., ...}`. REST at `/api/*` for the same token. The full typed schema is `packages/protocol/src/index.ts`; Swift and Kotlin mirror the subset they need.

Client → server:

| type | from | payload |
|------|------|---------|
| `hello` | both | `{ role: "mac" \| "daylight", deviceId, version }` |
| `plan.start` | daylight | – (idle → planning) |
| `ink.submit` | daylight | `{ purpose: "plan" \| "reply" \| "checkin" \| "wrapup", png?: base64, strokes?: Stroke[], text?: string }` |
| `plan.confirm` | daylight | `{ plan?: Plan }` (optional edits) |
| `plan.edit` | daylight | `{ plan: Plan }` (during working) |
| `todo.toggle` | daylight | `{ id, done }` |
| `checkin.now` | daylight | – (working / checkin_warn → checkin) |
| `checkin.snooze` | daylight or mac | – |
| `checkin.back` | daylight | – (checkin → working, after the AI reply) |
| `session.end` | daylight | – (→ wrapup) |
| `wrapup.close` | daylight | – (wrapup → idle) |
| `gate.arm` / `gate.disarm` | daylight | – |
| `meeting.pass` | daylight | `{ minutes }` |
| `emergency.unlock` | mac | `{ reason }` |
| `mac.foreground` | mac | `{ bundleId, name }` (for the log; allowlist enforcement is local) |
| `ping` | both | – |

Server → clients:

| type | payload |
|------|---------|
| `state` | full `StateSnapshot`: gate, phase, session, plan, lockMode, timers, meeting, connection status, config subset |
| `ai.message` | `{ role: "assistant", text, questions?: string[] }` (streamed as one message) |
| `ai.busy` | `{ busy: boolean, what: "reading" \| "thinking" }` |
| `error` | `{ code, message }` |
| `pong` | – |

The Mac app only needs `state.lockMode`, `state.shield` (title, body), `state.banner` (text, secondsLeft, canSnooze), `state.allowlist`, and sends `hello`, `emergency.unlock`, `checkin.snooze`, `mac.foreground`, `ping`.

## 5. Data model

```ts
Plan      { intention: string; priorities: string[]; todos: Todo[]; notes?: string }
Todo      { id: string; text: string; done: boolean }
Checkin   { at: ISO; where: string; happened: string; stuck?: string; next: string; aiReply: string; inkFile?: string }
Session   { id; startedAt; endedAt?; plan; transcript: Turn[]; checkins: Checkin[]; events: Event[]; wrapup?: { done: string; next: string; summary: string } }
Event     { at; kind: "emergency_unlock" | "meeting_pass" | "calendar_meeting" | "snooze" | "auto_end" | "arm" | "disarm"; detail?: string }
Config    { schedule; checkin; gate; allowlist; calendar; meetingPass; emergency; session; brain; voice; pairing }
```

Files: `~/.twelve/config.json`, `~/.twelve/sessions/<id>.json`, `~/.twelve/ink/<sessionId>/<n>.png`, `~/.twelve/daylog/<date>.json` (events outside a session).

## 6. AI (the brain)

Two calls, both via `messages.parse` with a Zod schema so the server never guesses at free text:

- **readInk**: input = PNG of the page (2x, white background) + purpose + current plan + prior turns. Output = `{ transcript, plan?, checkin?, wrapup?, questions[], message, complete }`. For `purpose: "plan"`, `complete` is true only when an intention and ≥ 1 priority were read. Questions are capped at `gate.maxQuestions` total per session by the server, not the model.
- **coach** (typed or spoken replies): same schema, text instead of an image.

Model `claude-opus-5`, adaptive thinking (default), `output_config.effort: "medium"` for ink reads (fast), `max_tokens` 4096. System prompt is stable and cached; the plan and turns go in the user message. Tone rules: brief, warm, concrete, never evaluative about the person, never more than one suggestion per reply.

## 7. Calendar → meeting pass

`calendar.icsUrls[]` polled every `calendar.pollMinutes` (5). An event counts as a meeting if it is not all-day, overlaps now ± `calendar.preRollMinutes` (2) / `calendar.postRollMinutes` (2), and either has attendees other than you or `calendar.requireAttendees` is false. Cancelled/declined events are skipped. The current meeting's title is shown on the shield banner and the Daylight dashboard.

## 8. Voice scaffold

`packages/server/src/voice/` exposes `VoiceProvider { kind, configured, sessionCredentials() }`. The PWA asks `GET /api/voice/session`; if a provider is configured it returns what the client needs to open the audio stream (ElevenLabs: signed conversation URL; Gemini Live: ephemeral token). `packages/daylight/src/voice/` holds the matching client stubs. Voice agents change state through `/api/voice/tools/*` webhooks, which map to the same commands as the WebSocket protocol.

## 9. Out of scope for v1 (deliberately)

Phone gating, multiple Macs, on-device handwriting recognition, OAuth calendar sync, Apple Screen Time integration, cloud sync.
