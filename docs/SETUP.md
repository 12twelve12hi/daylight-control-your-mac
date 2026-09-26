# Setup

## 1. The Mac (server + gate)

Requirements: macOS 13+, Node 20+ (`brew install node`), Xcode Command Line
Tools (`xcode-select --install`) for the gate app.

```sh
git clone https://github.com/12twelve12hi/twelve && cd twelve
mkdir -p ~/.twelve
cat > ~/.twelve/env <<'EOF'
ANTHROPIC_API_KEY=sk-ant-...
EOF
./scripts/install-mac.sh
```

What the installer does:

1. `npm install && npm run build`.
2. Writes `~/.twelve/run-server.sh` (sources `~/.twelve/env`, runs the server)
   and installs `~/Library/LaunchAgents/com.twelve.server.plist` (port 7712,
   restarts on crash, logs to `~/Library/Logs/twelve/server.log`).
3. Builds `apps/mac/TwelveGate` with `swift build -c release`, wraps it into
   `/Applications/TwelveGate.app`, ad-hoc signs it, installs
   `com.twelve.gate.plist` (starts at login, restarts on exit).

The first server start writes `~/.twelve/config.json` with a random pairing
token and the defaults from `SPEC.md` (weekdays 08:00–18:00 in the Mac's time
zone, 60-minute check-ins, and so on). Edit it there or from the Daylight's
Settings screen.

No API key yet? Set `"brain": { "provider": "mock" }` in `config.json` (or run
`npm start -w packages/server -- --mock`) to walk through the whole flow with a
deterministic stand-in that parses typed text and treats ink as a valid plan.

### Trying it without locking yourself out

`./scripts/install-mac.sh --no-gate` installs only the server. The Daylight app
and the dashboard at `http://127.0.0.1:7712/` work fully; nothing on the Mac is
shielded until you install the gate.

### Restarting, logs, uninstall

```sh
launchctl kickstart -k gui/$UID/com.twelve.server   # after changing ~/.twelve/env
launchctl kickstart -k gui/$UID/com.twelve.gate
tail -f ~/Library/Logs/twelve/server.log
./scripts/uninstall-mac.sh          # keeps ~/.twelve
./scripts/uninstall-mac.sh --purge  # removes the journal too
```

## 2. The Daylight DC-1

1. On the Mac, click **12** in the menu bar → **Open Daylight pairing page**
   (or open `http://127.0.0.1:7712/pair`). It shows a QR code and the same link
   in text, e.g. `http://192.168.1.20:7712/?token=…`.
2. On the DC-1, scan the QR code or type the link into Chrome. The app stores
   the token and drops it from the address bar.
3. Chrome menu → **Add to Home screen** (or **Install app**). Open it from the
   home screen: it runs full-screen with the pen.
4. Optional: build `apps/android` (see its README) for a launcher-style
   kiosk wrapper. The PWA is the supported path; the wrapper is polish.

Networking: both devices must reach each other. Same Wi-Fi works; a network
with client isolation (many offices, cafés) does not. Install
[Tailscale](https://tailscale.com) on both, then use the Mac's `100.x.y.z`
address; the pairing page lists it first when present.

Pen notes: the DC-1's Wacom EMR pen reports pressure, which the canvas uses for
stroke width. Fingers are ignored for 1.5 s after any pen contact (palm
rejection). Settings → *Pen only* ignores fingers entirely. A dead pen never
locks you out: **Type instead** on every writing screen.

## 3. Calendar (meeting mode)

See [`CALENDAR.md`](CALENDAR.md). Short version: paste your Google or Outlook
ICS link into Settings → Meetings, add your own e-mail address, save.

## 4. Voice (optional)

See [`VOICE.md`](VOICE.md).

## 5. Config reference (`~/.twelve/config.json`)

| Key | Default | Meaning |
|-----|---------|---------|
| `schedule.days` | `[1,2,3,4,5]` | 0 = Sunday … 6 = Saturday |
| `schedule.start` / `end` | `08:00` / `18:00` | Gated window (local time; overnight windows allowed) |
| `schedule.timezone` | `""` | IANA zone; empty = the Mac's |
| `checkin.intervalMinutes` | `60` | Time between check-ins |
| `checkin.warningSeconds` | `120` | Countdown banner before the shield |
| `checkin.snoozeMinutes` | `15` | One snooze per check-in |
| `gate.maxQuestions` | `2` | Clarifying questions before unlock |
| `allowlist.bundleIds` | Zoom, Calendar, Finder, FaceTime | Apps usable in meeting mode |
| `calendar.icsUrls` | `[]` | ICS feeds to poll |
| `calendar.selfEmails` | `[]` | Your addresses (for the attendee rule) |
| `calendar.requireAttendees` | `true` | Only events with someone else count |
| `calendar.preRollMinutes` / `postRollMinutes` | `2` / `2` | Meeting mode starts/ends this much around the event |
| `calendar.pollMinutes` | `5` | Refresh interval |
| `meetingPass.manualMinutes` / `manualPerDay` | `60` / `1` | Manual pass fallback |
| `emergency.holdSeconds` | `30` | Hold time (the Mac app currently uses its own 30 s default) |
| `emergency.unlockMinutes` | `30` | How long an emergency unlock lasts |
| `emergency.minReasonChars` | `10` | Reason length required |
| `session.maxHours` | `8` | Sessions auto-end |
| `brain.provider` / `model` | `anthropic` / `claude-opus-5` | Ink reading + coaching |
| `voice.provider` | `text` | `text`, `elevenlabs`, `gemini-live` |
| `pairing.token` | random | Never edit from a client |

Environment variables: `ANTHROPIC_API_KEY`, `TWELVE_HOME`, `TWELVE_PORT`,
`TWELVE_HOST`, `TWELVE_BRAIN=mock`, `ELEVENLABS_API_KEY`, `GEMINI_API_KEY`.

## 6. REST for scripts and automations

All endpoints take `?token=` or `Authorization: Bearer <token>`.

```
GET  /healthz                      no auth
GET  /api/state                    the same snapshot the clients get
GET  /api/sessions?limit=30
GET  /api/config   PUT /api/config (partial JSON)
POST /api/command                  any client message, e.g. {"type":"gate.arm"}
GET  /api/ink/<session>/<n>.png
GET  /api/voice/session
POST /api/voice/tools/<name>       get_plan | update_plan | confirm_plan | submit_checkin | back_to_work | end_session
```
