# Twelve

**Your Daylight gatekeeps your Mac.** During work hours the Mac is shielded
until you have written, by hand on your Daylight DC-1, what the session is for
and what matters most. An AI reads the ink, asks at most two short questions,
and unlocks the Mac. Every hour it pauses you for a two-minute written
check-in. When your calendar says you are in a meeting, the shield steps aside
for the apps you allowlisted. No scores, no shame: the point is to put pen and
paper before the screen, and to keep the real goal in view.

The full design, including every decision from the planning interview and the
state machine, is in [`SPEC.md`](SPEC.md).

```
┌──────────────┐   Wi-Fi / Tailscale   ┌──────────────────────────────┐
│ Daylight DC-1│ ◀───── WebSocket ────▶ │ Mac                          │
│  PWA (ink)   │                        │  twelve-server (Node, :7712) │
└──────────────┘                        │   ├─ Claude reads the ink    │
                                        │   ├─ calendar (ICS) → meetings│
                                        │   └─ session state + timers  │
                                        │  TwelveGate.app (menu bar)   │
                                        │   └─ shield / allowlist / banner
                                        └──────────────────────────────┘
```

## What it looks like

The Daylight screens are real captures from the end-to-end run at the DC-1's
1600×1200 resolution (mock coach, so the "handwriting" is scribbles). The Mac
images are renderings of the AppKit layout in `apps/mac/TwelveGate`, because
the app could not be run in the environment this was built in. Regenerate all
of them with `npm run screenshots`.

### The gate

<table>
<tr>
<td width="50%"><img src="docs/screenshots/mac-01-shield-gated.png" alt="Mac shield: Your Mac is waiting for your Daylight"><br><sub><b>Mac, work hours, no plan yet.</b> Full-screen shield on every display; Dock, menu bar, Cmd-Tab and force-quit are off. The hold button at the bottom is the emergency exit.</sub></td>
<td width="50%"><img src="docs/screenshots/02-home-gated.png" alt="Daylight home: Your Mac is waiting"><br><sub><b>Daylight, same moment.</b> One big button. Meeting pass and arm/disarm live here too.</sub></td>
</tr>
<tr>
<td><img src="docs/screenshots/01-pairing-page.png" alt="Pairing page with QR code"><br><sub><b>Pairing.</b> Served only on the Mac itself; scan it once from the Daylight.</sub></td>
<td><img src="docs/screenshots/mac-06-menu-bar.png" alt="Mac menu bar item"><br><sub><b>Mac menu bar.</b> Status, next check-in, pairing page, dashboard. Quit is disabled while locked.</sub></td>
</tr>
</table>

### Planning by hand

<table>
<tr>
<td width="50%"><img src="docs/screenshots/03-plan-by-hand.png" alt="Plan page with ink"><br><sub><b>Plan.</b> Faint headings for intention, priorities and to-dos; pressure-sensitive pen, eraser, undo, and a keyboard fallback.</sub></td>
<td width="50%"><img src="docs/screenshots/04-review.png" alt="Review of the plan the coach read"><br><sub><b>Review.</b> The transcription, the coach's reply, and the plan as editable fields. One button unlocks the Mac.</sub></td>
</tr>
<tr>
<td><img src="docs/screenshots/05-review-question.png" alt="Coach asks what the session is for"><br><sub><b>The gate question.</b> No intention on the page, so the coach asks once. Answer by writing or typing. At most two questions, ever.</sub></td>
<td><img src="docs/screenshots/06-dashboard-working.png" alt="Dashboard while working"><br><sub><b>Working.</b> The Daylight becomes the container for the session: intention on top, priorities, to-dos, next check-in.</sub></td>
</tr>
</table>

### The hourly check-in

<table>
<tr>
<td width="50%"><img src="docs/screenshots/mac-04-checkin-banner.png" alt="Mac banner with countdown"><br><sub><b>Mac, two minutes before.</b> A floating countdown you can snooze once.</sub></td>
<td width="50%"><img src="docs/screenshots/07-checkin-warning.png" alt="Daylight dashboard with check-in countdown"><br><sub><b>Daylight, same countdown.</b> Check in early or snooze from here.</sub></td>
</tr>
<tr>
<td><img src="docs/screenshots/mac-02-shield-checkin.png" alt="Mac shield: Check-in time"><br><sub><b>Mac, countdown over.</b> Shielded until the check-in is written.</sub></td>
<td><img src="docs/screenshots/08-checkin-write.png" alt="Check-in writing page"><br><sub><b>Check-in.</b> Where am I, what happened, stuck on, next step.</sub></td>
</tr>
<tr>
<td><img src="docs/screenshots/09-checkin-reply.png" alt="Coach reply to a check-in"><br><sub><b>The reply.</b> Two or three sentences tied to the intention, one concrete step if you were stuck. Then back to work.</sub></td>
<td><img src="docs/screenshots/10-meeting-mode.png" alt="Meeting mode on the Daylight"><br><sub><b>Meeting mode.</b> A calendar meeting (or a manual pass) lifts the shield for allowlisted apps and pauses check-ins.</sub></td>
</tr>
</table>

### Meetings, wrap-up, the exit

<table>
<tr>
<td width="50%"><img src="docs/screenshots/mac-05-meeting-hud.png" alt="Mac meeting-mode HUD"><br><sub><b>Mac in meeting mode.</b> A corner HUD; apps not on the allowlist are hidden as they come forward.</sub></td>
<td width="50%"><img src="docs/screenshots/11-wrapup-summary.png" alt="Wrap-up summary"><br><sub><b>Wrap-up.</b> What got done, what's next, a three-line summary for tomorrow-morning-you.</sub></td>
</tr>
<tr>
<td><img src="docs/screenshots/mac-03-shield-emergency.png" alt="Mac shield with the emergency unlock form"><br><sub><b>Emergency exit.</b> Hold 30 seconds, write why, get 30 minutes. It goes in the journal, no shame.</sub></td>
<td><img src="docs/screenshots/12-emergency-unlock.png" alt="Daylight showing an emergency unlock"><br><sub><b>Daylight, same moment.</b> The unlock and its reason show up here and in History.</sub></td>
</tr>
<tr>
<td><img src="docs/screenshots/13-history.png" alt="History with ink pages"><br><sub><b>History.</b> Every session with its check-ins, summary, and the handwritten pages themselves.</sub></td>
<td><img src="docs/screenshots/14-settings.png" alt="Settings"><br><sub><b>Settings.</b> Schedule, check-in cadence, calendar links, allowlist, emergency rules, coach and voice.</sub></td>
</tr>
<tr>
<td><img src="docs/screenshots/15-home-free.png" alt="Outside work hours"><br><sub><b>Outside work hours.</b> The Mac is free; arm the gate for an off-hours session if you want the ritual.</sub></td>
<td></td>
</tr>
</table>

## What is in the box

| Path | What | Status |
|------|------|--------|
| `packages/server` | The brain: session state machine, WebSocket hub, REST, JSON journal in `~/.twelve`, Claude handwriting reading + coaching, ICS calendar meeting detection, voice-provider scaffold, QR pairing page | Built, 15 unit/integration tests |
| `packages/daylight` | The Daylight app (PWA): pressure-aware ink canvas with palm rejection, plan → review → unlock, dashboard, check-in, wrap-up, history with your ink pages, settings, keyboard fallback, voice hook | Built, 2 end-to-end browser tests |
| `packages/protocol` | Shared TypeScript/Zod contract for everything above | Built |
| `apps/mac/TwelveGate` | Swift menu-bar app: full-screen shield on every display with kiosk presentation options, meeting allowlist mode, check-in banner with snooze, 30-second-hold emergency unlock with a written reason | Written and reviewed, **not compiled here** (no Swift toolchain in the build container) |
| `apps/android` | Optional Kotlin WebView kiosk wrapper for the DC-1 | Scaffolded, **not compiled here** |
| `scripts/` | `install-mac.sh` / `uninstall-mac.sh`, launchd plists | |
| `docs/` | Setup, calendar, voice, and emergency-exit notes | |

## Quick start on the Mac

```sh
git clone https://github.com/12twelve12hi/daylight-control-your-mac && cd daylight-control-your-mac
echo 'ANTHROPIC_API_KEY=sk-ant-...' > ~/.twelve/env     # or leave it out and use the mock brain
./scripts/install-mac.sh
open http://127.0.0.1:7712/pair                        # scan this on the Daylight
```

`install-mac.sh` builds the server and the Daylight app, installs the server
as a LaunchAgent (`com.twelve.server`), compiles `TwelveGate.app` with the Xcode
command line tools and installs it as a second LaunchAgent (`com.twelve.gate`).
Use `--no-gate` to run the server only while you try the flow.

On the Daylight: scan the QR code (or open the printed link in Chrome), then
**Add to Home screen** so it runs full-screen. Details in
[`docs/SETUP.md`](docs/SETUP.md).

To try it without any key or Mac app:

```sh
npm install && npm run build
npm start -w packages/server -- --mock      # http://127.0.0.1:7712/pair
```

## The ritual

1. Work hours start: the Mac shows *"Your Mac is waiting for your Daylight."*
2. On the Daylight, tap **Plan & unlock**. Write under three faint headings:
   *Intention*, *Priorities (up to three)*, *To-do*. Tap **I'm done**.
3. The coach shows what it read as an editable plan. If the intention or a
   priority is missing it asks one short question (two at most). Answer by
   writing or typing.
4. **Looks right, unlock my Mac.** The Daylight becomes the dashboard.
5. After 60 minutes the Mac shows a two-minute countdown, then shields until
   you write a check-in: *Where am I? / What happened? / Stuck on? / Next step.*
   The coach replies in two or three sentences and offers one concrete step if
   you are stuck. One 15-minute snooze per check-in.
6. Calendar meeting in progress? The shield becomes *meeting mode*: only the
   apps on your allowlist stay open, and check-ins wait.
7. **Done for now** opens the wrap-up page; the coach writes a three-line
   summary for tomorrow, and the Mac is gated again.

Emergency exit on the Mac: hold the button on the shield for 30 seconds, write
one line about why, and you get 30 minutes. It is logged in that day's journal.

## Development

```sh
npm install
npm run build        # protocol → daylight → server
npm test             # server unit tests + Playwright e2e (first: npx playwright install chromium)
npm run dev          # server with live reload (tsx watch)
```

Data lives in `~/.twelve/` (override with `TWELVE_HOME`):
`config.json`, `sessions/*.json`, `ink/<session>/*.png`, `daylog/<date>.json`.

## Limits worth knowing

- The shield is a firm gate, not a prison: Spotlight and some system dialogs
  can appear above it, and the emergency exit always works, even offline.
- The Mac app follows the server. If the server is down the Mac keeps its last
  lock mode; restart the server (`launchctl kickstart -k gui/$UID/com.twelve.server`).
- Voice (ElevenLabs Conversational AI, Gemini Live) is scaffolded end to end but
  has not been run against the live services; see [`docs/VOICE.md`](docs/VOICE.md).
- Neither the Swift app nor the Android wrapper could be compiled in the
  environment this was built in. Both were written conservatively and reviewed
  line by line; expect to fix a compiler nit or two on first build.
