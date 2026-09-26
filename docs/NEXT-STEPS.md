# Next steps, one at a time

Rules for this page:

- **Do only the step you are on.** Everything below it can wait.
- Each step says how long it takes, what "done" looks like, and what to do if it goes wrong.
- If you only have ten minutes today, do **Step 1**. That is a real win.
- You cannot lock yourself out. The escape hatches are at the bottom, read them once.

---

## Step 0 · Get the Mac ready (10 min, one time)

- [ ] Install Node: `brew install node` (or from nodejs.org).
- [ ] Install the Xcode command line tools: `xcode-select --install` (you only need this for Step 4).
- [ ] Clone the project:
  ```sh
  git clone https://github.com/12twelve12hi/daylight-control-your-mac
  cd daylight-control-your-mac
  ```
- [ ] Get an Anthropic API key from https://console.anthropic.com (keys page). You need it in Step 3, not before.

**Done when:** `node --version` prints a number and the folder exists.

---

## Step 1 · See the whole ritual with nothing at stake (10 min)

Runs the brain with a fake coach. Nothing locks. You use the Mac's own browser as a stand-in for the Daylight.

- [ ] In the project folder:
  ```sh
  npm install
  npm run build
  npm start -w packages/server -- --mock
  ```
- [ ] Open http://127.0.0.1:7712/pair in Safari. Click the link under the QR code.
- [ ] Tap **Plan & unlock the Mac**. Scribble with the mouse, or tap **Type instead** and type a line like `intention: try this thing`. Tap **I'm done**, then **Looks right, unlock my Mac**.
- [ ] Tap **Check in now**, type a check-in, **Back to work**. Tap **Done for now** twice, **Skip wrap-up**.

**Done when:** the History tab shows a session with your check-in.
**If stuck:** the terminal shows the error. Copy it into Claude Code with "the Twelve server fails to start with this error".

---

## Step 2 · Pair the Daylight (5 min)

Same server still running. Mac and Daylight on the same Wi-Fi.

- [ ] Open http://127.0.0.1:7712/pair on the Mac. Scan the QR code with the Daylight's camera, or type the link into Chrome on the Daylight.
- [ ] In Chrome on the Daylight: menu → **Add to Home screen**. Open it from the home screen.
- [ ] Do the ritual again, this time with the pen.

**Done when:** your actual handwriting shows up as a thumbnail in History.
**If the Daylight cannot reach the Mac:** the Wi-Fi may isolate devices. Install Tailscale on both and use the `100.x` link from the pairing page.

---

## Step 3 · Turn on the real coach (5 min)

- [ ] Stop the server (Ctrl-C). Put the key where the server reads it:
  ```sh
  mkdir -p ~/.twelve
  echo 'ANTHROPIC_API_KEY=sk-ant-...' > ~/.twelve/env
  set -a; source ~/.twelve/env; set +a
  npm start -w packages/server
  ```
  (no `--mock` this time)
- [ ] Write a real plan by hand on the Daylight. Messy is fine.

**Done when:** the review page shows what you actually wrote, structured into intention and priorities.
**If the coach says it cannot read the page:** check the terminal for a 401 (bad key) or a billing message. Rewriting bigger and darker also helps.

---

## Step 4 · Build the Mac app, the one step that may need a fix (20 min)

The Swift app was written and reviewed but never compiled. Expect a nit or two.

- [ ] Build it:
  ```sh
  cd apps/mac/TwelveGate
  swift build
  ```
- [ ] Errors? Paste them into Claude Code with: *"fix the Swift compile errors in apps/mac/TwelveGate"*. Rebuild.
- [ ] Bundle and run it by hand, before making it automatic:
  ```sh
  ./scripts/bundle.sh
  open build/TwelveGate.app
  ```
  A **12** appears in the menu bar. Because it is inside work hours (default weekdays 08:00–18:00), the shield appears if no plan is active.
- [ ] Practise the escape once, on purpose: hold the button on the shield for 30 seconds, type a reason, unlock. Then plan on the Daylight and watch the shield lift for real.
- [ ] Quit it from the menu bar (Quit is enabled once unlocked).

**Done when:** you have seen the shield appear, escaped it, and then unlocked it properly.
**If the shield appears and the Daylight cannot connect:** hold the emergency button. Nothing else needed.

---

## Step 5 · Make it automatic (5 min)

- [ ] From the project folder:
  ```sh
  ./scripts/install-mac.sh
  ```
  This installs the server and the gate app so they start at login and restart if they crash.
- [ ] On the Daylight → **Settings**: set the gated window to something small for the first day, e.g. tomorrow 09:00–11:00. Save.

**Done when:** tomorrow at 09:00 the shield appears, and the morning starts on the Daylight.
**If you regret it:** `./scripts/uninstall-mac.sh` removes both agents and the app. Your journal stays.

---

## Step 6 · Calendar meetings (5 min)

- [ ] Google Calendar → Settings → your calendar → *Secret address in iCal format*. Copy it.
- [ ] Daylight → Settings → Meetings: paste it, add your own e-mail address, Save.
- [ ] Test: create a calendar event starting in 5 minutes with one other invitee. Watch the shield turn into meeting mode. Delete the event afterwards.
- [ ] Add the apps you need during meetings to the allowlist (Zoom is already there). Bundle ids: `osascript -e 'id of app "Slack"'`.

**Done when:** a real meeting lets you use Zoom without planning first.

---

## Step 7 · Live with it for a week, then tune

Do nothing else for a week. Just use it. Then look at History and adjust in Settings:

- Check-ins too often? Change 60 to 90 minutes.
- Coach asks too much? Set questions to 1.
- Window too long? Shorten it. The gate is for the hours that matter, not all of them.

Write down anything annoying. That list is the next thing to hand to Claude Code.

---

## Later, only if you want

- **Voice**: add `ELEVENLABS_API_KEY` or `GEMINI_API_KEY` to `~/.twelve/env` and follow `docs/VOICE.md`. Untested against the live services; budget an hour.
- **Android wrapper**: `apps/android` in Android Studio, for a launcher-style feel. The web app is enough.
- **Away from home Wi-Fi**: Tailscale on both devices, done.

---

## Escape hatches, in order of gentleness

1. **On the shield:** hold the button 30 s, write one line, you get 30 minutes. Logged, no shame.
2. **From the Daylight:** Settings → shrink the gated window, or tap **Disarm** outside it.
3. **From any browser on the network:** `http://<mac-ip>:7712/?token=<your token>` is the same app. The token is in `~/.twelve/config.json`.
4. **From the Mac's terminal** (Cmd-Space still opens Spotlight above the shield):
   `launchctl bootout gui/$UID/com.twelve.gate` stops the gate app until next login.
5. **Nuclear:** `./scripts/uninstall-mac.sh`.

---

## What to say to Claude Code when something breaks

- *"The Twelve server fails to start with this error: …"*
- *"Fix the Swift compile errors in apps/mac/TwelveGate: …"*
- *"On the Daylight, when I tap X, Y happens instead of Z."*
- *"Read docs/SPEC.md and change the check-in to …"*

The spec (`SPEC.md`) holds every decision, so a fresh session can pick up where this one left off.
