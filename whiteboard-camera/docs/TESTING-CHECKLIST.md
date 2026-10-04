# Testing checklist: the device run

Everything the code could not prove without hardware, as atomic steps grouped into seven sessions (Session 4b is mirror over Wi-Fi, Session 6 is the optional Overlay mode) you can do on different days. Each row says what you do, what you see (or the exact log line), how long it takes, and which `docs/LOOSE_ENDS.md` row it answers (D1 to D23, E2 and so on, G rows), or "note" when a tick is enough. You never paste lines into LOOSE_ENDS: on a 📋 row you tap "Send facts to Mac" on the tablet (the web page's "?" card, or Daylight Ink > Settings > "This tablet"), and at the end of the day you choose menu bar > "Export diagnostics..." once and send back the zip it reveals in Finder. `docs/FEEDBACK.md` says what is inside and which file answers each D row. Results that surprise you: a sentence in your note, sent with the zip.

Prerequisites per session are at the top of each one. Sessions 1 to 4b and 6 run on the unsigned build (the preview window stands in for the camera); session 5 needs the signed, notarized build of `docs/SIGNING.md`. Legend: 🟢 setup, ✍️ draw something, 🟡 make it fail on purpose, 🟣 confirm a file or a value, 📋 a fact the export collects (tap "Send facts to Mac" where the row says so; Export diagnostics once at the end), ⏱️ a timed wait.

Rows marked "proved in CI, confirm on device" already pass on an emulated Android 13 tablet at 1200x1600 and 200 dpi in the `android-emulator` CI job (`docs/SCREENSHOTS.md` has the pictures of every run); on the DC-1 you only confirm them.

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

How to read the log while you test: Terminal, `log stream --predicate 'subsystem == "com.twelve.daylight"' --level info`. Or menu bar > "Diagnostics..." (the last 200 lines are at the bottom). The failure rows named below are SPEC 13.3 rows; SPEC lists 1, 12, 13, 19, 21, 22, 28 and 33 as the ones to trigger on purpose on day one.

---

## Session 1: Mac only (⏱️ about 20 minutes, unsigned or signed build, no tablet needed)

Prerequisites: Daylight installed per `docs/SETUP.md`; a webcam; the preview window open.

| # | | Step | You see, or the log line | ⏱️ | Answers |
|---|---|---|---|---|---|
| 1.1 | 🟡 | Open `Daylight.app` from Downloads (a copy) before the one in Applications | "Move Daylight to your Applications folder, then open it from there." with "Reveal in Finder" (row 1) | 30 s | note |
| 1.2 | 🟢 | Open from Applications: the Welcome window, "Allow camera access", Allow | the preview fills within a second of Allow (G7) | 1 min | note |
| 1.3 | 🟡 | Deny camera access once (System Settings > Privacy & Security > Camera > Daylight off), reopen Daylight | "Camera access is off for Daylight." with "Open System Settings" (row 3); switch it back on | 1 min | note |
| 1.4 | 🟢 | Read the menu bar | the version line, "Open http://<ip>:7788 on your Daylight" lines, "Ink source", "Hold", "Keep whiteboard", "Clear", "Camera", "Whiteboard now (Studio Split)", "Whiteboard now (Whiteboard Only)", "Preview window", "Settings...", "Diagnostics...", "Export diagnostics...", "Setup again", "Quit Daylight"; no "Whiteboard now (Overlay)" (Overlay is off by default, Session 6) | 30 s | note |
| 1.5 | 🟡 | Quit Daylight; Terminal `nc -l 7788`; launch Daylight | menu: "Port 7788 is in use. Daylight is using 7789." (row 16); log `NWListener failed:`; stop `nc` afterwards | 1 min | note (E22) |
| 1.6 | ⏱️ | Wait 60 s with no tablet connected | menu: "Nobody has connected yet. Same Wi-Fi? Office networks often block this: use USB or Tailscale." (row 18) | 1 min | note |
| 1.7 | ✍️ | Press Ctrl+Opt+Cmd+D from the camera state | the preview slides to Studio Split without ink; press again: back to the camera | 30 s | note |
| 1.8 | ✍️ | Press Ctrl+Opt+Cmd+W | Whiteboard Only: paper centred, cream margins, no presenter; again: camera | 30 s | note |
| 1.9 | ✍️ | Ctrl+Opt+Cmd+K | menu "Keep whiteboard" ticked and the board up; Ctrl+Opt+Cmd+Esc returns | 30 s | note |
| 1.10 | 🟣 | Settings > Hotkeys: bind Ctrl+Opt+Cmd+C to a second action | the second one reads "Already used by Clear" (G6); "Reset to defaults" | 1 min | G6 |
| 1.11 | 🟣 | Settings > General: change "Return to camera after" while the board is up (via 1.7) | the board stays up; the new timeout applies after the next return (G13) | 1 min | G13 |
| 1.12 | 🟡 | Unplug the external webcam (or cover the built-in by choosing a USB camera and unplugging it) | menu icon with a slash, preview "No camera found" (row 4), or the fallback camera within a second with a cream card in between (G5); replug: the picture returns | 1 min | G5 |
| 1.13 | 🟣 | Diagnostics: the "first frame:" line; the Welcome window's Camera row | `first frame: <w>x<h> <fourcc> iosurface=<bool> zeroCopy=true`, or `zeroCopy=false` followed by the row 5 text "Camera delivers <w>x<h> <fourcc>; composing every frame"; the Camera row reads "Using <your webcam>." | 30 s | E4, E5 |
| 1.14 | ⏱️ | Signed build with the extension connected: close every viewer and the preview, wait 60 s | webcam LED off; Diagnostics "Webcam capture is paused because no app is viewing Daylight Camera (LED off). It restarts within a second when a call starts." (row 33); log `capture stopped: viewers=0 preview=hidden`; open FaceTime: picture back within a second | 2 min | note (E11) |
| 1.15 | 🟣 | Terminal: quit Daylight, `/Applications/Daylight.app/Contents/MacOS/Daylight --self-test --perf-log` | one line per probe, `self-test: PASS`; the Metal device name and the first command buffer time | 1 min | PERFORMANCE.md |
| 1.16 | 📋 | Menu bar > "Export diagnostics..." (tick "Run self-test first" once), Export | "Diagnostics saved as diagnostics-<date-time>.zip in Documents > Daylight Camera. Send this file back after the test." (row 45) and Finder shows the zip; this is the one file you send back at the end of every session | 1 min | your notes |

---

## Session 2: web whiteboard (⏱️ about 25 minutes)

Prerequisites: "Ink source" > "Web whiteboard"; the DC-1 on the same Wi-Fi (USB with debugging on for 2.17).

| # | | Step | You see, or the log line | ⏱️ | Answers |
|---|---|---|---|---|---|
| 2.1 | 🟢 | Type the menu-bar URL into Chrome on the tablet | the cream page with "Tap to start" | 1 min | D8 later |
| 2.2 | 🟢 | Tap once | Chrome goes full screen; chip "Looking for your Mac" under a second, then "Look at your Mac" | 30 s | note |
| 2.3 | 🟢 | Mac: "Allow" in the floating panel (Zoom keeps focus); or let it time out after 60 s and use the menu item "Allow Chrome on Daylight" (row 19) | chip "Camera"; log `client <id> pending` before, allowed after | 1 min | E14 (focus) |
| 2.4 | ✍️ | Write one word | chip "LIVE" with an amber dot within a quarter second; the board slides into the preview with your ink | 1 min | note |
| 2.5 | 🟡 | Rest your palm, swipe a finger | nothing drawn, no slide (D9) | 1 min | D9 |
| 2.6 | 🟡 | Hover the pen 5 mm above the glass and move | nothing drawn | 30 s | note |
| 2.7 | 📋 | Press the pen side button in the air, then draw a stroke; tap "?" > "Send facts to Mac" | nothing drawn by the side button; the card says "Sent to your Mac."; the export's `tablet-facts.json` holds `firstPenPointerdown` (`daylight-web first pen pointerdown button=<n> buttons=<n> pressure=<p> ...`) and `pressureMin`, `pressureMax` | 2 min | D3, D4 |
| 2.8 | ✍️ | "Highlight", draw across the word | an amber band under the black ink on the tablet and in the preview | 30 s | note |
| 2.9 | ✍️ | "Erase", drag across part of the word | the touched strokes vanish on both sides; the first erase burst is one frame per sample (G14) | 30 s | note |
| 2.10 | ✍️ | "Undo", then "Redo" | the stroke vanishes on the Mac first, then on the tablet; Redo brings it back; the buttons grey out when empty | 1 min | note |
| 2.11 | ⏱️ | Stop drawing and wait | at 85 s chip "Returning in 5" with the dot breathing in step with the amber divider; at 90 s "Returning", then "Camera" | 2 min | note |
| 2.12 | ✍️ | Draw, tap the chip; wait 2 minutes; tap again | "KEEP WHITEBOARD" in black; the board stays; then "LIVE" with a fresh 90 s | 3 min | note |
| 2.13 | ✍️ | Hold the chip for one second | the picture slides back; chip "Camera" | 30 s | note |
| 2.14 | 🟣 | Draw, tap "Clear"; then draw, tap "New page" while LIVE | Clear blanks both sides and returns (unless pinned); `page-01.png` and `page-01.json` appear under `~/Documents/Daylight Camera/<date>/<time>/`; New page saves the page you were on at once (its `-2` copy, see 2.15) and keeps the board up on a blank `page-02`, written on the next trigger | 1 min | E23 |
| 2.15 | 🟣 | Draw, Clear, draw, Clear | `page-01.png` and `page-01-2.png` (the second Clear after a cleared page picks `-2`) | 1 min | note |
| 2.16 | 🟡 | Wi-Fi off on the tablet for 5 s while writing, then on | chip "Looking for your Mac" then "Camera" or "LIVE"; the strokes from the gap arrive on the Mac after the reconnect | 1 min | note |
| 2.17 | 🟣 | Draw, reload the page, draw again, tap the page's "Undo" twice | the page hides its own stroke first and never loses it (G2) | 1 min | G2 |
| 2.18 | 🟢 | Chrome menu > Add to Home screen > Add; close Chrome; tap the icon; tap Start | the page opens full screen | 1 min | D8 (`displayMode`) |
| 2.19 | 📋 | Tap "?", then "Send facts to Mac" (again after launching from the Home screen icon, so both display modes are sent) | "Sent to your Mac."; the export's `tablet-facts.json` holds `chromeVersion`, `devicePixelRatio`, `viewport`, `displayMode`, `secureContext`, `wakeLockState`, `fullscreenState` | 1 min | D8 |
| 2.20 | 🟣 | USB: cable in, Welcome window > "Set up over USB" with Web whiteboard selected | Chrome opens `http://localhost:7788` (or the bound port) on the tablet with no Allow prompt; "?" shows `secure true`, `wake lock true held`, `coalesced true` | 2 min | D10 (which app opened the URL) |
| 2.21 | 🟣 | Optional: try the muted `http://<hostname>.local:7788` line in Chrome | does it load? | 1 min | D8 (`.local`) |
| 2.22 | 🟣 | Optional (LOOSE_ENDS A5): "?" card, copy the `chrome://flags` line and the origin, paste in Chrome, Enabled, Relaunch | "?" shows `secure true` afterwards | 2 min | A5 |
| 2.23 | ⏱️ | Leave the tablet alone for its screen-timeout period while LIVE | with `wake lock true held` the screen stays on; otherwise note it | 3 min | D8 |

---

## Session 3: Daylight Ink (⏱️ about 25 minutes)

Prerequisites: "Ink source" > "Daylight Ink app"; a USB-C cable with USB debugging on, or Wi-Fi for path B.

| # | | Step | You see, or the log line | ⏱️ | Answers |
|---|---|---|---|---|---|
| 3.1 | 🟢 | Path A: cable in, Welcome window > "Set up over USB" | the app opens on the tablet within a few seconds; chip "Camera" with no Allow prompt | 2 min | D15 (`canDrawOverlays=true`) |
| 3.2 | 🟢 | Path B (no cable): web page "?" > "Download Daylight Ink", Install, allow the source, open | "Welcome to Daylight Ink"; the first row switches from "Looking for your Mac... Enter its address if this takes long" to connected by itself on the same Wi-Fi; else type the Mac's address | 3 min | E15, D11; proved in CI, confirm on device (onboarding text, manual address to Connected (fake Mac)) |
| 3.3 | 🟢 | "Open the permission screen" > Daylight Ink > "Allow display over other apps" > Back; "Allow notifications"; "Start writing" | the row reads "Allowed"; the canvas appears | 2 min | note; proved in CI, confirm on device (permission screen and back, "Allowed") |
| 3.4 | 🟢 | Wi-Fi path: "Allow" on the Mac | chip "Camera" | 30 s | note |
| 3.5 | ✍️ | Write one word | ink under the pen immediately (front buffer); chip "LIVE" within a quarter second; the board in the preview | 1 min | note |
| 3.6 | 🟡 | Palm, finger, hover, side button in the air | nothing drawn | 1 min | note; proved in CI, confirm on device (finger draws nothing (injected events)) |
| 3.7 | 📋 | Settings > "This tablet" > "Send facts to Mac" (after a stroke and a side-button press) | "Sent to your Mac."; `tablet-facts.json` holds `pressureRange` (`normalised 0..1` or `raw ADC`) and `sideButton` (`BUTTON_STYLUS_PRIMARY` or `SECONDARY`) | 1 min | D3, D4 |
| 3.8 | ✍️ | Flip the pen (eraser end) or tap "Erase", rub across the word | the touched strokes vanish on both sides | 30 s | note |
| 3.9 | ✍️ | "Highlight", then "Undo", "Redo" | amber under black; undo on the Mac first, then the tablet; Redo back; both grey out when empty | 1 min | note |
| 3.10 | ⏱️ | Stop drawing and wait | "Returning in 5" at 85 s with the breathing dot; "Returning" then "Camera" at 90 s | 2 min | note |
| 3.11 | ✍️ | Tap the chip; wait 2 minutes; tap; hold one second | "KEEP WHITEBOARD"; board stays; "LIVE"; back to "Camera" | 3 min | note |
| 3.12 | 🟣 | "Clear"; then "New page" while LIVE | Clear blanks both sides and returns unless pinned; New page keeps the board up | 1 min | note |
| 3.13 | 🟣 | Settings > "Front buffer (lowest latency wet ink)" off, back out, draw; back on, draw | the canvas reloads on the way back (android-04, G14); compare the wet-ink lag; "This tablet" shows `frontBuffer=available (...)` or `fallback to the dry view (...)` | 2 min | D14 |
| 3.14 | 🟣 | Settings > "Send every pen sample at once (A/B against per-frame batching)" on; draw; compare | smoothness on the tablet and the Mac's `perf` line | 2 min | COMPARE.md |
| 3.15 | 🟡 | Wi-Fi off for 5 s while writing, then on | chip "Looking for your Mac" then "Camera" or "LIVE" within about 10 s (strokes from the gap stay on the tablet only) | 1 min | note |
| 3.16 | 📋 | Settings > "This tablet" > "Send facts to Mac" | "Sent to your Mac."; `tablet-facts.json` holds `model`, `release`, `display`, `density`, `tiramisuExt`, `canDrawOverlays` | 1 min | D2, D11, D15 |
| 3.17 | 🟢 | Settings > "Show the pills now" (or "Ink source" > "Mirror the tablet" on the Mac with pills on) | two pills "Pin" and "Clear" top centre of the tablet; log `pills window added: TOP y=24 row=48px` then `pills frame x=<n> y=24 h=<n>`; "Pin" shows "KEEP" when pinned; "Hide the pills" removes them | 3 min | D5; proved in CI, confirm on device (Pin and Clear in the top strip) |
| 3.18 | 🟣 | Over USB from the Mac's adb: `adb shell am start-foreground-service -n com.twelve.daylight.ink/.overlay.OverlayService --es pills top` | the pills appear without opening the app | 1 min | D15 |
| 3.19 | 🟣 | Settings > "Start the pills at boot" on; reboot the tablet | the pills come back by themselves (A12 opt-in) | 3 min | A12 |
| 3.20 | 🟢 | Next day: open the app | it reconnects with no prompt (Bonjour, then 127.0.0.1:7788, then the remembered host) | 1 min | note |
| 3.21 | ⏱️ | Wait 8 days after 3.1 (or check Developer options) | does "Disable adb authorization timeout" exist and did the authorisation survive? | 1 min | D6 |

Logcat, when a row needs it: `/Applications/Daylight.app/Contents/Resources/Vendor/adb logcat -s DaylightInk.facts DaylightInk.ink DaylightInk.net DaylightInk.overlay`.

---

## Session 4: mirror mode (⏱️ about 25 minutes)

Prerequisites: USB debugging on, the cable, "Always allow from this computer" accepted; the SolOS note app on the tablet.

| # | | Step | You see, or the log line | ⏱️ | Answers |
|---|---|---|---|---|---|
| 4.1 | 🟢 | "Ink source" > "Mirror the tablet"; open "Diagnostics..." | within 2 s `mirror.status: mirroring <serial> 1200x1600` and `mirror.session.deviceModel: <Build.MODEL>` | 1 min | D2 |
| 4.2 | ✍️ | Pen on the note app | the preview slides to Studio Split with the tablet picture in the board slot, top strip cropped; log `engage probe: pen contact at <t> (mirror)` and `first decoded frame at <t>` | 1 min | D12 |
| 4.3 | ⏱️ | Lift the pen, wait 90 s | the picture slides back; `~/Documents/Daylight Camera/<date>/<time>/mirror-<HH-mm-ss>.png` appears, cropped like the picture | 2 min | note |
| 4.4 | ✍️ | Double press the pen side button; then hold it for a second | menu "Keep whiteboard" ticked; then Clear and return (unless pinned); Settings > Mirror > "Swap: double press = Clear, long press = Pin" exchanges them | 1 min | D1 (`BTN_STYLUS` seen) |
| 4.5 | 🟣 | Settings > Mirror > "Pin and Clear in mirror mode" > "Pen side button"; then "Both" | the whole screen mirrored (top inset 0); then the strip cropped again | 1 min | note |
| 4.6 | 🟣 | Settings > Mirror > "Floating pills" or "Both": look at the preview | the pills are on the tablet and absent from the camera picture; if visible, raise the Top crop | 1 min | D5 |
| 4.7 | 🟣 | Rotate the tablet | Diagnostics `mirror.session.size: 1600x1200`; the same region stays cropped (landscape top inset 72) | 1 min | note |
| 4.8 | 📋 | Diagnostics `mirror.pen.node` (`mirror.pen.status` reads "no pen node among [...]" when row 28 fired) and the log line `getevent -pl devices: [...]` and `pen node /dev/input/eventN "<name>" pressureMax=<n> keys=[...] abs=[...]` | nothing to copy: `diagnostics.txt` and `unified-log.txt` in the export hold all three | 1 min | D1 |
| 4.9 | 📋 | Diagnostics `mirror.decoder.hardware`, `mirror.decoder.outOfOrder`, `mirror.adb.mode`, `mirror.adb.executable` | hardware true/false/unknown (E26); out-of-order stays 0 (D13); the adb mode (shared or private) and which path is in use (E24) | 1 min | D13, E24, E26 |
| 4.10 | 🟡 | Unplug the cable while mirroring; replug | status `no device` within 2 s, the board lifts the pen and the idle timer runs; replug: mirroring resumes with no tap | 2 min | note |
| 4.11 | 🟡 | Decline the RSA prompt once (revoke in Developer options > Revoke USB debugging authorizations, replug, tap Deny) | "Tap Allow on your Daylight (tick Always allow)." (row 22); then allow again | 1 min | note |
| 4.12 | 🟡 | Toggle USB debugging off and on while plugged | "The Daylight is connected but not responding. Unplug and plug again." (row 23) or row 21 "No Daylight found over USB. Is USB debugging on?" | 1 min | note |
| 4.13 | 🟡 | Settings > Mirror > "Mirror over Wi-Fi after a USB session" on; unplug | the mirror continues over Wi-Fi, or "Plug in once to re-enable Wi-Fi mirroring." (row 32); log `remembered <ip> for Wi-Fi mirroring; adbd now listens on 5555`; reboot the tablet and try again | 3 min | C2 |
| 4.14 | 🟡 | Start another adb first (Android Studio, or Homebrew's `adb start-server`), then Daylight | menu row 24 "Another adb is running (Android Studio?)..."; `mirror.adb.mode` reads `private tcp:localhost:27180 (...)`; is the tablet still visible? | 2 min | C5 |
| 4.15 | 🟡 | Pull the cable mid-frame and replug quickly | status "Recovering video..." until the next key frame (row 27), at most 12 s before the server restarts | 1 min | note |
| 4.16 | 🟣 | Welcome window > "Set up over USB" with Web whiteboard selected, then with Daylight Ink app selected | the tablet opens `http://localhost:7788` (or the bound port); then the APK installs, the app opens with the Mac's address, the pills service starts | 2 min | D10, D15 |
| 4.17 | 🟣 | After quitting Daylight: `adb shell ps -A \| grep getevent` with the bundled adb | no leftover `getevent` (or note it; harmless) | 1 min | D12 |
| 4.18 | ⏱️ | Mirror for 30 minutes; Activity Monitor memory for Daylight before and after | the resident set does not grow (app-12, G14); budget under 180 MB | 30 min | G14, PERFORMANCE.md |
| 4.19 | 🟢 | Settings > Mirror > "adb source": "Bundled (default)" (a new source applies at once, no relaunch); mirror as in 4.1 | the row under the picker shows `.../Daylight.app/Contents/Resources/Vendor/adb, platform-tools 37.0.0 (bundled)`; Diagnostics `mirror.adb.source: bundled` and the same path | 2 min | H1 |
| 4.20 | 🟣 | "adb source": "Download on first use"; Cancel on "Download adb from Google?", then choose it again and Accept; mirror (no relaunch needed); then Wi-Fi off, quit and reopen, mirror again | Cancel shows row 39; Accept shows "Downloading adb..." then `~/Library/Application Support/Daylight/platform-tools/adb, platform-tools 37.0.0`; Diagnostics `mirror.adb.source: download`; mirroring works, also offline | 4 min | H1 |
| 4.21 | 🟣 | "adb source": "Use installed adb" (needs `brew install android-platform-tools` or Android Studio, installed before you choose it); mirror | the row shows the path found (for example `/opt/homebrew/bin/adb, 1.0.41 (37.0.0-...)`), or row 42 or 43 with the reason (with Ink source on "Mirror the tablet" the menu shows the same sentence as a red line, never `launchFailed(...)`); Diagnostics `mirror.adb.source: installed`, `mirror.adb.version`; mirroring works; set "Bundled (default)" back afterwards | 3 min | H1 |

---

## Session 4b: mirror over Wi-Fi without USB debugging (⏱️ about 25 minutes plus one 60-minute battery run)

Prerequisites: Daylight Ink installed and allowed (Session 3), the tablet and the Mac on the same Wi-Fi, the cable unplugged, USB debugging may stay off. On the Mac, "Ink source" > "Mirror the tablet" and Settings > Mirror > "Transport" > "Wi-Fi (Daylight Ink screen stream)" ("Transport" is the first row of the Mirror tab, which scrolls; if the tab looks cut off at the top, note it in LOOSE_ENDS J). The tablet logs everything under `adb logcat -s DaylightInk.mirror` (only if you happen to have adb) and shows the same facts in Daylight Ink > Settings > "This tablet".

| # | | Step | You see, or the log line | ⏱️ | Answers |
|---|---|---|---|---|---|
| 4b.1 | 🟢 | Daylight Ink > Settings > "Share screen with your Mac" | the Android screen-capture prompt; write down its exact wording on SolOS; tap "Start now". The state line reads "Ready. The Mac starts the picture when it needs it" and the notification "Sharing screen with your Mac" appears | 2 min | D19; proved in CI, confirm on device (Android 13 prompt, "Start now" streams) |
| 4b.2 | 🟢 | Look at the Mac (Diagnostics...) | within 2 s `mirror.wifi.tabletState` reads streaming, `mirror.wifi.streamSize: 1200x1600`, `mirror.wifi.engageSource: frame difference`; the tablet reads "Sharing with your Mac"; the menu shows row 37 once as information | 1 min | note |
| 4b.3 | ✍️ | Open the SolOS note app, write one word from the camera state | the board slides in after the ink appears (within about half a second of the first stroke); note roughly how late (Session 4 measures it), and whether a still page, the clock or a blinking cursor ever starts it. Then lift the pen and wait 90 s: the board returns | 3 min | D20 |
| 4b.4 | ⏱️ | Leave the page still for 30 s; watch `mirror.wifi.fps` | the tablet fps stays above 0 (about 4 repeat frames a second) and "The tablet's screen stream paused. Reconnecting..." (row 36) never appears | 1 min | D21 |
| 4b.5 | 🟡 | Scroll a long page or play an animation in the note app without the pen | does the board slide in by mistake? If yes, raise Settings > Mirror > "Change threshold" and note the value that stops it | 3 min | D20 |
| 4b.6 | 🟣 | Tap the pills: Pin, then Clear | Pin keeps the board; Clear saves and returns; the pills are absent from the camera picture (top 96 px crop) | 1 min | D5 |
| 4b.7 | 🟣 | Rotate the tablet | the picture comes back upright within about 2 s; `mirror.wifi.streamSize: 1600x1200` | 1 min | note |
| 4b.8 | 🟣 | Plug the cable in with USB debugging on (if you have it), write again | `mirror.wifi.engageSource: pen (USB getevent)`; the slide starts as fast as Session 4 | 2 min | note |
| 4b.9 | 🟡 | Mac: switch "Ink source" to "Daylight Ink app", then back to "Mirror the tablet" | the tablet reads "Ready..." while away and streams again on return with no new prompt | 1 min | note |
| 4b.10 | 🟡 | Tap "Stop" in the tablet notification | the Mac shows the stream ended; the tablet reads "Sharing stopped on this tablet" | 1 min | note |
| 4b.11 | 🟡 | Close Daylight Ink (swipe it away), keep the Mac on Mirror with Wi-Fi transport | the notification "Your Mac wants to mirror this screen. Tap to allow." appears (if the pills service keeps a connection); tap it, then "Start now"; the picture resumes. If nothing appears, the Mac shows "Open Daylight Ink on your Daylight to mirror over Wi-Fi." (row 38) | 2 min | D22 |
| 4b.12 | 🟡 | Share again and tap "Cancel" in the Android prompt | the Mac shows "Daylight Ink was not allowed to share the tablet screen. On the tablet open Daylight Ink > Settings > Share screen with your Mac and choose Start now." (row 34) | 1 min | note; proved in CI, confirm on device (tablet side: Cancel leaves the app healthy) |
| 4b.13 | 🟡 | Lock the tablet screen while sharing, unlock | does sharing end ("Sharing stopped on this tablet")? | 1 min | D19 |
| 4b.14 | 📋 | Daylight Ink > Settings > "This tablet" > "Send facts to Mac" while streaming (`mirrorEncoders`, `mirrorEncoder`, `mirrorStream` in `tablet-facts.json`); the Mac side, `mirror.wifi.bitrate`, `mirror.wifi.fps`, `mirror.wifi.decodeLatencyMs`, is in `diagnostics.txt` | the encoder name, the measured fps and bit rate, the decode latency | 2 min | D21 |
| 4b.15 | ⏱️ | Battery and heat: charge to 100 percent, stream while writing for 60 minutes, note the percentage; then "Send facts to Mac" (`mirrorThermalMax`) | the drop per hour; thermal 3 or more means the frame rate was halved | 60 min | D23, COMPARE 2.1 |

---

## Session 5: the signed camera (⏱️ about 15 minutes, signed and notarized build only)

Prerequisites: `Daylight.dmg` from a `v*` tag or a notarize run (`docs/SIGNING.md`); FaceTime and Zoom installed.

| # | | Step | You see, or the log line | ⏱️ | Answers |
|---|---|---|---|---|---|
| 5.1 | 🟡 | Open the app from the mounted DMG or Downloads first | "Move Daylight to your Applications folder, then open it from there." (row 1 or 7) | 30 s | note |
| 5.2 | 🟢 | Drag to Applications, eject, open from Applications; Welcome row "Install Daylight Camera" (the request is submitted at launch, no Install click) | "Approve 'Daylight Camera' in System Settings > General > Login Items & Extensions > Camera Extensions, then click Check again." (row 12); log `requestNeedsUserApproval` | 1 min | E13 |
| 5.3 | 🟢 | "Open System Settings" | lands on Camera Extensions (or where?); switch Daylight Camera on, password | 1 min | E13 |
| 5.4 | 🟢 | "Check again" | the row turns green within 2 s; log `sink connected: device=<id> sink=<id> capacity=1 directions=[a, b]` | 30 s | E2 (`directions=`) |
| 5.5 | 🟣 | Terminal `systemextensionsctl list` | `com.twelve.daylight.camera` with `[activated enabled]` | 30 s | note |
| 5.6 | 🟣 | Log line `CMIOObjectAddPropertyListenerBlock(dlvw) on stream <id> -> <status>` | the status; later, whether `viewers=` changes arrive faster than one second after FaceTime starts | 30 s | E3 |
| 5.7 | 🟡 | Quit Daylight; FaceTime > Video > Daylight Camera | the cream card "Daylight is not running. Open Daylight from the menu bar." within a second | 30 s | E28 (CoreText sentence drawn) |
| 5.8 | 🟢 | Open Daylight again while FaceTime shows the card | the webcam replaces the card within 2 s; log `viewers=1` | 30 s | note |
| 5.9 | ⏱️ | Close FaceTime | `viewers=0` within 1 s; LED off 60 s later; reopen FaceTime: picture back within a second | 2 min | note |
| 5.10 | 🟢 | Zoom (Settings > Video > Camera > Daylight Camera) and FaceTime together | log `viewers=2`; both show the same picture | 1 min | note |
| 5.11 | 🟣 | Diagnostics: "sink:" and "extension:" lines; the Welcome window's Camera row | `sink: connected`, `extension: connected`, the `capture:` line with `viewers=`; the Camera row reads "Using <your webcam>.", never Daylight Camera (app-03, G14) | 30 s | G14 |
| 5.12 | 🟡 | Row 13 on purpose: `systemextensionsctl uninstall <TEAMID> com.twelve.daylight.camera` (unverified subcommand; else trash and reinstall the app), relaunch Daylight | "Daylight Camera is installed but not found yet. Retrying..." then after 30 s "Open Zoom or FaceTime once, or restart your Mac."; approve again: connected without a relaunch | 2 min | note (`systemextensionsctl uninstall` spelling) |
| 5.13 | 🟢 | Install the next build (a newer notarized run) over the running one while FaceTime shows the picture | FaceTime keeps showing frames without relaunching Daylight (G1); or the log notice `sink connected but N pushes in a row were dropped with viewers=` means quit and reopen Daylight | 3 min | G1 |
| 5.14 | 🟡 | Zoom shows black after the update | quit and reopen Zoom (row 15) | 30 s | note |
| 5.15 | 🟣 | Terminal `spctl -a -vv /Applications/Daylight.app` | `accepted`, `source=Notarized Developer ID` | 30 s | G8 |
| 5.16 | 📋 | `release-logs` of the run: `profile-check.txt`, `signed-flag.txt`, `notarytool-submit.json`, `codesign-vendor-adb.txt` | anything surprising; `codesign -dvv /Applications/Daylight.app/Contents/Resources/Vendor/adb` shows a Developer ID signature and `Timestamp=` | 2 min | G, B6 |
| 5.17 | 🟣 | Activity Monitor, the `com.twelve.daylight.camera` process, while a call is on and nothing is drawn | near zero CPU (the 90 Hz consume timer only while the sink is started) | 1 min | E1 |

---

## Session 6: Overlay mode (optional, v2) (⏱️ about 20 minutes, unsigned or signed build, no tablet needed)

Prerequisites: Daylight running with a webcam and the preview window open, in a normally lit room. For 6.11 quit Daylight and start it from Terminal with `/Applications/Daylight.app/Contents/MacOS/Daylight --perf-log`. Overlay is SPEC 6.7; the hotkey works from the camera state without a tablet.

| # | | Step | You see, or the log line | ⏱️ | Answers |
|---|---|---|---|---|---|
| 6.1 | 🟣 | Before enabling anything: read the menu bar, Settings > Hotkeys and Settings > General > "Layout when engaging"; press Ctrl+Opt+Cmd+O | no "Whiteboard now (Overlay)" item, no Overlay row in Hotkeys, only "Studio Split" and "Whiteboard Only" in the picker; the hotkey does nothing (off by default, invisible) | 1 min | note |
| 6.2 | 🟢 | Settings > Overlay > switch on "Enable overlay mode" | "Whiteboard now (Overlay)" appears after "Whiteboard now (Whiteboard Only)"; Hotkeys lists Overlay as Ctrl+Opt+Cmd+O; the picker offers "Overlay" | 1 min | note |
| 6.3 | ✍️ | Press Ctrl+Opt+Cmd+O from the camera state | the board slides in from the left; the menu status reads "Overlay" | 30 s | note |
| 6.4 | 🟣 | Look at the cutout once the slide has settled | a square in the bottom-right corner, about 28 percent of the picture height (302 of 1080 px), 32 px from the edges, showing the middle of your camera picture with the background removed; the board is fully readable behind it | 1 min | E31 |
| 6.5 | 🟣 | Press Ctrl+Opt+Cmd+O twice more and watch the slide both ways | the cutout starts as the full camera picture and shrinks into the corner without stretching your face (no pop at the first frame); the second press returns to the camera the same way | 1 min | note |
| 6.6 | 🟣 | Settings > Overlay: switch on the amber outline; try Size, Position and Opacity | an amber ring follows your outline; the square changes size, corner and transparency at once | 2 min | E31 |
| 6.7 | 🟣 | Sit still for 30 s, then wave a hand near your face | the edge does not flicker while still; the hand shows when it is in the square | 1 min | E31 |
| 6.8 | 🟡 | Dim the room (or step out of view) with the board up | the square shows your whole camera picture as a plain rectangle; Diagnostics shows "Overlay is showing your whole camera picture because it cannot separate you from the background (too dark, or nobody in view)." (row 49) and the log `overlay: mask coverage <fraction> below 0.01; showing the camera rectangle`; light back on: the cutout returns | 2 min | E31 |
| 6.9 | 🟡 | Cover the camera lens completely for 5 s with the board up (a failure on purpose; if segmentation keeps succeeding on a covered lens, note that instead) | either the rectangle of 6.8, or after 15 failed frames the board switches to Studio Split and the menu shows the line "Overlay mode could not find you in the camera picture, so Daylight is showing Studio Split. Turn Overlay off and on in Settings > Overlay to try again." (row 48), log `overlay: segmentation failed <n> frames in a row: <error>`; toggling "Enable overlay mode" off and on brings Overlay back | 2 min | note |
| 6.10 | 🟣 | Settings > Overlay > Segmentation quality: Fast, then Balanced, then Accurate | edges get cleaner with each step; the picture keeps moving smoothly | 2 min | E31 |
| 6.11 | 📋 | With `--perf-log`, hold the board up in Overlay for 20 s at each quality | one `perf overlay seg_ms=... mask_age_ms=... seg_dropped=... state=...` line per second next to the usual `perf` line; right after the third quality, menu bar > "Export diagnostics..." (`perf-log.txt` keeps the last 200 perf lines, about 100 s with Overlay on, so export before anything else) | 3 min | E30, PERFORMANCE.md |
| 6.12 | 🟣 | Diagnostics or the log during Overlay | no line saying the mask had to be copied (if there is one, note it) | 30 s | E29 |
| 6.13 | 🟢 | Settings > Overlay > switch off "Enable overlay mode"; return to the camera and wait 10 s | the Overlay menu item, the Hotkeys row and the picker choice are gone; Ctrl+Opt+Cmd+O does nothing; the `perf overlay` lines stop and the passthrough `perf` line reads as before Overlay (same fields, our code under 0.1 ms per frame) | 1 min | note |

---

## Where the results go

- Facts with a row id: nothing to edit by hand. Tap "Send facts to Mac" where a row says so, then menu bar > "Export diagnostics..." once at the end and send the zip (`docs/FEEDBACK.md`); the engineers write the values into `docs/LOOSE_ENDS.md` from it.
- Decisions: A2 (macOS 26 on the M5 Max), A3 (package name), A4 (three defaults), A5 (the Chrome flag stays optional), A14 (Apache-2.0) were applied on 2026-10-03 (`docs/STATUS.md` "Owner decisions applied"); the adb source choice of A6 is the engineering ticket H1 in `docs/LOOSE_ENDS.md`. A new decision goes in a new row of section A.
- Numbers: `docs/PERFORMANCE.md` section "Owner's Mac" and `docs/COMPARE.md` section 2.
- Anything that surprised you: one sentence with the step number, sent with the zip (the export already holds the Diagnostics report and the last two hours of the log).
- Checked rows that match the expectation: nothing to write; the tick is the record. Keep this file's boxes ticked in your working copy or a printout.
