# The email to send yourself

Copy everything below the line into an email to yourself, so the plan lives on the MacBook and not only on the Daylight. Same content as [`NEXT-STEPS.md`](NEXT-STEPS.md), with every link in one place.

---

**Subject: Twelve — next steps to get it running on the MacBook**

Hey future me,

Twelve is built and merged. This is the one email to open on the MacBook when you sit down to try it. Do one step at a time. If you only have ten minutes, do Step 1.

## LINKS
- Repo (public): https://github.com/12twelve12hi/daylight-control-your-mac
- The step-by-step guide (same as below, with more detail): https://github.com/12twelve12hi/daylight-control-your-mac/blob/master/docs/NEXT-STEPS.md
- Setup + config reference: https://github.com/12twelve12hi/daylight-control-your-mac/blob/master/docs/SETUP.md
- Calendar (Google/Outlook ICS → meeting mode): https://github.com/12twelve12hi/daylight-control-your-mac/blob/master/docs/CALENDAR.md
- Voice scaffold (ElevenLabs / Gemini Live, later): https://github.com/12twelve12hi/daylight-control-your-mac/blob/master/docs/VOICE.md
- The spec with every decision: https://github.com/12twelve12hi/daylight-control-your-mac/blob/master/SPEC.md
- Screenshots of every state: README, section "What it looks like": https://github.com/12twelve12hi/daylight-control-your-mac#what-it-looks-like
- Merged PRs: https://github.com/12twelve12hi/daylight-control-your-mac/pull/1 and https://github.com/12twelve12hi/daylight-control-your-mac/pull/2
- Anthropic API key: https://console.anthropic.com
- Tailscale (only if the Daylight can't reach the Mac on Wi-Fi): https://tailscale.com
- The Claude Code session that built this (to resume with full context): https://claude.ai/code/session_011G3Z5g5B9dSV4ujwzWH8K7

## STEP 0 · Get the Mac ready (10 min, once)
- brew install node   (or https://nodejs.org)
- xcode-select --install   (only needed for Step 4)
- git clone https://github.com/12twelve12hi/daylight-control-your-mac && cd daylight-control-your-mac
- Get an Anthropic API key (needed in Step 3).
Done when: node --version prints a number.

## STEP 1 · See the whole ritual with nothing at stake (10 min)
- npm install && npm run build
- npm start -w packages/server -- --mock
- Open http://127.0.0.1:7712/pair in Safari, click the link under the QR code.
- Plan & unlock → Type instead → "intention: try this thing" → I'm done → Looks right, unlock my Mac.
- Check in now → type something → Back to work → Done for now (tap twice) → Skip wrap-up.
Done when: the History tab shows a session. Nothing locks yet.
If stuck: copy the terminal error into Claude Code: "the Twelve server fails to start with this error: …"

## STEP 2 · Pair the Daylight (5 min)
- Same server running, both devices on the same Wi-Fi.
- On the Mac open http://127.0.0.1:7712/pair, scan the QR with the Daylight (or type the link into Chrome on it).
- Chrome menu → Add to Home screen. Open it from the home screen. Do the ritual with the pen.
Done when: your handwriting shows as a thumbnail in History.
If the Daylight can't reach the Mac: Tailscale on both, use the 100.x link from the pairing page.

## STEP 3 · Turn on the real coach (5 min)
- Ctrl-C the server.
- mkdir -p ~/.twelve && echo 'ANTHROPIC_API_KEY=sk-ant-...' > ~/.twelve/env
- set -a; source ~/.twelve/env; set +a
- npm start -w packages/server      (no --mock)
- Write a real, messy plan by hand.
Done when: the review page shows what you actually wrote, split into intention and priorities.
If it can't read the page: terminal shows 401 (bad key) or a billing message. Write bigger and darker.

## STEP 4 · Build the Mac app — the one step that may need a fix (20 min)
The Swift app was written and reviewed but never compiled. Expect a nit or two.
- cd apps/mac/TwelveGate && swift build
- Errors? Paste into Claude Code: "fix the Swift compile errors in apps/mac/TwelveGate: …". Rebuild.
- ./scripts/bundle.sh && open build/TwelveGate.app
- A "12" appears in the menu bar. Inside work hours (default weekdays 08:00–18:00) the shield appears if no plan is active.
- Practise the escape once on purpose: hold the shield button 30 s, type a reason, unlock. Then plan on the Daylight and watch the shield lift for real.
- Quit it from the menu bar.
Done when: you've seen the shield, escaped it, and unlocked it properly.

## STEP 5 · Make it automatic (5 min)
- ./scripts/install-mac.sh   (installs server + gate app as login agents)
- On the Daylight → Settings: set a small gated window for the first day, e.g. tomorrow 09:00–11:00. Save.
Done when: tomorrow at 09:00 the shield appears and the morning starts on the Daylight.
Regret it: ./scripts/uninstall-mac.sh   (journal stays)

## STEP 6 · Calendar meetings (5 min)
- Google Calendar → Settings → your calendar → "Secret address in iCal format". Copy.
- Daylight → Settings → Meetings: paste it, add your own e-mail, Save.
- Test with a fake event 5 min out with one other invitee; the shield turns into meeting mode. Delete the event after.
- Allowlist the apps you need in meetings (Zoom is there). Bundle ids: osascript -e 'id of app "Slack"'
Done when: a real meeting lets you use Zoom without planning first.

## STEP 7 · Live with it for a week, then tune
Check-ins too often → 90 min. Coach asks too much → questions: 1. Window too long → shorten it.
Write down what annoys you. That list is the next job for Claude Code.

## LATER, ONLY IF YOU WANT
- Voice (ELEVENLABS_API_KEY or GEMINI_API_KEY in ~/.twelve/env, see docs/VOICE.md). Untested against the live services; budget an hour.
- Android wrapper (apps/android in Android Studio). The web app is enough.

## ESCAPE HATCHES, gentlest first
1. On the shield: hold the button 30 s, write one line, get 30 minutes. Logged, no shame.
2. From the Daylight: Settings → shrink the window, or Disarm outside it.
3. From any browser on the network: http://<mac-ip>:7712/?token=<token>  (token is in ~/.twelve/config.json)
4. Terminal (Spotlight still opens above the shield): launchctl bootout gui/$UID/com.twelve.gate
5. Nuclear: ./scripts/uninstall-mac.sh

## WHAT TO SAY TO CLAUDE CODE WHEN SOMETHING BREAKS
- "The Twelve server fails to start with this error: …"
- "Fix the Swift compile errors in apps/mac/TwelveGate: …"
- "On the Daylight, when I tap X, Y happens instead of Z."
- "Read SPEC.md and change the check-in to …"

Pen before screen. You built the gate; now walk through it.
