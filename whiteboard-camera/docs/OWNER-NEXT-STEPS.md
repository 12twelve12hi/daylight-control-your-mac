# Owner next steps: from zero to Daylight Camera in a call

This is the one page to open first. It walks from "I have a Mac without Xcode and a tablet in a box" to "Zoom shows my whiteboard when I touch the pen", in order, with a time estimate per step, what done looks like, and what to do when a step fails. Everything else in `docs/` is reference; this page tells you when to open which one.

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

## What you have and what you do not, in one paragraph

Every component is built and green in CI (`docs/STATUS.md`), but nothing has run on real hardware. Two things only you can do: sign the Mac app with your Apple Developer account (without it the virtual camera cannot appear in any call; the unsigned build still shows everything in a preview window), and put the DC-1 next to the Mac to confirm the tablet facts the code guessed (`docs/LOOSE_ENDS.md` section D). You need no Xcode at any point: GitHub Actions builds, signs and notarizes; your Mac only needs Keychain Access, Terminal and the `gh` command.

Order of the day, and why: try the web whiteboard first (nothing to install on the tablet, works from the unsigned build in the preview window), then Daylight Ink over USB (one click installs it), then mirror mode (needs USB debugging on the tablet). Signing can run in parallel; it is 30 minutes of clicking in Apple's portal and then CI does the rest.

| Step | What | Time | Needs |
|---|---|---|---|
| 0 | Install the tools on the Mac | 10 min | the Mac, internet |
| 1 | Download the unsigned build and open the preview | 10 min | the Mac |
| 2 | Pair the web whiteboard | 10 min | the DC-1 on the same Wi-Fi |
| 3 | Pair Daylight Ink over USB | 10 min | a USB-C cable, USB debugging on the DC-1 |
| 4 | Try mirror mode | 10 min | the same cable |
| 5 | Signing in Apple's portal and the eight secrets | 30 min | your Apple Developer account, `gh` |
| 6 | The first notarized build | 25 min, mostly waiting | step 5 |
| 7 | Install the signed app and approve the camera extension | 10 min | step 6 |
| 8 | Pick Daylight Camera in Zoom, Meet or FaceTime | 5 min | step 7 |
| 9 | Run the testing checklist and paste the facts | 60 to 90 min | everything above |

---

## Step 0: install the tools on the Mac (10 min)

Done looks like: `gh auth status` prints your GitHub login and `gh run list --limit 1` prints a run.

1. Install Homebrew if the Mac does not have it (brew.sh shows the one-line installer), then `brew install gh`.
2. `gh auth login` in Terminal, choose GitHub.com, HTTPS, log in through the browser.
3. `cd` into a clone of the repository (`git clone https://github.com/12twelve12hi/daylight-control-your-mac.git`, then `cd daylight-control-your-mac`). The build branch is `claude/daylight-whiteboard-camera-tzxfjb`: `git checkout claude/daylight-whiteboard-camera-tzxfjb`.
4. `gh run list --workflow whiteboard-camera --branch claude/daylight-whiteboard-camera-tzxfjb --limit 3` lists the latest runs. A green one is what you download in step 1.

If it fails: `gh` says "not logged in" (run `gh auth login` again); `gh run list` says the workflow does not exist (you are in the wrong folder; the workflow file is `.github/workflows/whiteboard-camera.yml` at the monorepo root).

Optional, for later: the `adb` you need for the tablet is bundled inside the app at `Daylight.app/Contents/Resources/Vendor/adb`; you do not need Android Studio or Homebrew's platform-tools, and a second adb on the Mac is one of the failure rows (24).

---

## Step 1: download the unsigned build and open the preview (10 min)

This build cannot install the virtual camera (that needs signing, step 5). It shows the menu bar item, the Welcome window, the preview window of what the camera would show, the web page, the Allow panel, saving and hotkeys. It is enough for steps 2 to 4.

Done looks like: a camera icon in the menu bar, a preview window showing your webcam, a "Welcome to Daylight" window whose first row reads "This is an unsigned test build. The virtual camera cannot be installed on this Mac. Use Daylight > Preview window to see the output."

1. Find the run id of the latest green run from step 0, then `gh run download <run id> -n Daylight-unsigned` (or in the browser: Actions > whiteboard-camera > the run > Artifacts > `Daylight-unsigned`). You get `Daylight-unsigned.zip`.
2. Double-click the zip. Drag `Daylight.app` into `/Applications` (not required for the unsigned build, but it is where the signed one must live, so start the habit).
3. Open it. macOS refuses an unsigned app on the first double-click. Either right-click `Daylight.app` > Open, or go to System Settings > Privacy & Security, scroll down to the message about Daylight and click Open Anyway, or in Terminal `xattr -d com.apple.quarantine /Applications/Daylight.app` and open it normally.
4. The first launch asks for camera access: click Allow (the Welcome window also has an "Allow camera access" button). macOS 15 may also ask whether Daylight may find devices on the local network: Allow (it is how the tablet finds the Mac).
5. The preview window opens by itself on unsigned builds and shows your webcam within a second. The menu bar icon is a camera.

If it fails: no menu bar icon at all (open Console.app, search `com.twelve.daylight`, or run `/Applications/Daylight.app/Contents/MacOS/Daylight` from Terminal and read the output); the preview shows a cream "No camera found" card (plug in a webcam or open the lid; failure row 4); the Welcome window says "Camera access is off for Daylight." (System Settings > Privacy & Security > Camera > Daylight on; row 3).

Day-one fallback for a real call before signing is done: the preview window plus OBS. In OBS add a macOS Screen Capture source, choose the window capture method and pick Daylight's preview window, then Start Virtual Camera and choose "OBS Virtual Camera" in Zoom. Clunky, but it lets you test the pen experience in a real meeting on day one. Menu bar > "Preview window" toggles the window; Settings > General > "Preview window floats above other windows" keeps it on top.

---

## Step 2: pair the web whiteboard (10 min, recommended first)

Why first: nothing to install on the tablet; Chrome on the DC-1 opens a page the Mac serves; the ink arrives as strokes (tens of bytes per sample), which is the lowest-latency path and the one that produces a vector record.

Done looks like: the chip at the bottom of the tablet page reads "Camera"; touching the pen slides the preview into Studio Split and the chip reads "LIVE".

1. Mac: menu bar > "Ink source" > "Web whiteboard" (the default). Read the first menu line "Open http://<address>:7788 on your Daylight"; clicking it copies the address. A Tailscale address comes first when you have one; the Wi-Fi address follows.
2. Tablet (same Wi-Fi): open Chrome, type the address exactly, Go. A cream page with "Tap to start" appears. Tap once: Chrome goes full screen.
3. Mac: a floating panel at the top right says "Allow 'Chrome on Daylight' to draw on Daylight Camera? It connected from <ip>." Click "Allow". The tablet chip changes from "Look at your Mac" to "Camera". (If the panel timed out, the menu bar has an item "Allow Chrome on Daylight".)
4. Tablet: write one word with the pen. The preview slides into Studio Split within a quarter second; your ink appears; the chip reads "LIVE" with an amber dot.
5. Tablet: Chrome menu > Add to Home screen > Add. From now on the page is one tap.

If it fails: the page does not load (both devices on the same Wi-Fi? Office and school networks often isolate clients: use USB in step 3, or Tailscale, see `docs/SETUP.md` Networking); the chip stays at "Looking for your Mac" (the Mac shows row 18 after 60 s: "Nobody has connected yet. Same Wi-Fi? Office networks often block this: use USB or Tailscale."); the chip reads "Mac found, socket refused. Tap to retry" (tap it; if it persists, menu bar > "Diagnostics..." and read the listener line); the menu says "Port 7788 is in use. Daylight is using 7789." (type the address with 7789; row 16).

Optional one-time step for better ink over Wi-Fi: the page's "?" button opens a card with a `chrome://flags/#unsafely-treat-insecure-origin-as-secure` line and the origin to paste; this is LOOSE_ENDS A5 and your decision.

---

## Step 3: pair Daylight Ink over USB (10 min)

Why second: the same stroke protocol as the web page, but native: unbuffered pen input, the wet ink is drawn in the front buffer, and the app reconnects by itself every day without a browser. Also the one that gives you the floating Pin and Clear pills for mirror mode.

Done looks like: the Daylight Ink app opens on the tablet by itself, its chip reads "Camera", and writing engages the board exactly as in step 2.

1. Tablet, once: Settings > About > tap Build number seven times; Settings > Developer options > USB debugging on. If SolOS lists "Disable adb authorization timeout", turn it on (LOOSE_ENDS D6; without it Android forgets the Mac after 7 days).
2. Plug the tablet into the Mac. The tablet asks "Allow USB debugging?": tick "Always allow from this computer", tap Allow.
3. Mac: menu bar > "Ink source" > "Daylight Ink app". Open the Welcome window (menu bar > "Setup again" if it is closed), go to the "Your Daylight" row: it reads "A Daylight is on USB (<serial>). Set up over USB does everything for the chosen ink source." Click "Set up over USB". The Mac installs the APK, grants the two permissions, forwards the port and opens the app with the Mac's address.
4. Tablet: the app opens. On the first run it shows "Welcome to Daylight Ink": the first row reads "Looking for your Mac... Enter its address if this takes long" and should switch by itself; then "Open the permission screen" (pick Daylight Ink, switch on "Allow display over other apps", press Back), "Allow notifications", then "Start writing". Over USB there is no Allow panel on the Mac: a cable connection is trusted.
5. Write one word: the chip reads "LIVE", the preview slides, the ink is under the pen at once.
6. Unplug the cable, keep Wi-Fi on: the app reconnects over Bonjour within about 10 s and the Mac asks "Allow 'Daylight Ink on <model>' to draw on Daylight Camera?" once. Click "Allow". From now on the app reconnects by itself, cable or not.

If it fails: the Mac says "No Daylight found over USB. Is USB debugging on?" (row 21: debugging off, or the cable is charge-only); "Tap Allow on your Daylight (tick Always allow)." (row 22: the RSA prompt is waiting on the tablet); "The Daylight is connected but not responding. Unplug and plug again." (row 23); "Another adb is running (Android Studio?)..." (row 24: Daylight uses its own adb on a private port; a tablet already claimed by the other adb stays invisible until you quit it). No cable at all? Open the web page from step 2, tap "?", tap "Download Daylight Ink", install it (one-time "allow from this source"), open it: it finds the Mac over Bonjour and the Mac shows the Allow panel.

---

## Step 4: try mirror mode (10 min)

Why last: it needs USB debugging, it streams video of the whole tablet screen (about 1 MB/s) instead of strokes, and it produces no vector record. What it buys you: any app on the tablet, for example the SolOS note app, can be the whiteboard.

Done looks like: menu bar > "Diagnostics..." shows `mirror.status: mirroring <serial> 1200x1600`; touching the pen in the note app slides the preview to Studio Split with the tablet screen in the board slot, top strip cropped.

1. Cable in (step 3 already authorised the Mac). Mac: menu bar > "Ink source" > "Mirror the tablet". Wait two seconds.
2. Tablet: open the note app, write. The preview slides within about a tenth of a second; the picture follows a little later (encoder, adb, decoder).
3. Pin and Clear here are the two floating pills "Pin" and "Clear" at the top of the tablet (Daylight starts them over the cable) and the pen's side button: double press = Pin, hold for 0.7 s = Clear and return. Settings > Mirror > "Pin and Clear in mirror mode" picks "Floating pills", "Pen side button" or "Both".
4. The top 96 tablet pixels (where the pills live) are cropped out of the camera picture. If the crop is wrong, Settings > Mirror > Crop, drag the edges over the live picture.

If it fails: "The screen mirror could not start: ..." (row 25; copy the sentence into LOOSE_ENDS); "Pen events not found on this Daylight. Mirror works, but auto-engage and the pen button do not. Use the pills or the Whiteboard hotkey." (row 28: the Wacom input node is not where the code expects; paste the Diagnostics `mirror.pen.status` line (it reads "no pen node among [...]") into LOOSE_ENDS D1); "Pen button events not seen; use the pills." (row 28b). "Recovering video..." for more than 12 s means the decoder is waiting for a key frame; unplug and replug.

---

## Step 5: signing in Apple's portal and the eight GitHub secrets (30 min)

The virtual camera is a macOS system extension, and macOS loads one only from an app signed with a Developer ID certificate and notarized by Apple. Everything happens in your browser and Keychain Access; `docs/SIGNING.md` has every click, every failure and its remedy. The short form:

1. Developer ID Application certificate (Keychain Access makes the request file; Apple's portal issues the certificate; export it as a `.p12` with a password).
2. Two App IDs: `com.twelve.daylight` with System Extension and App Groups ticked, `com.twelve.daylight.camera` with App Groups ticked.
3. Two Developer ID provisioning profiles named exactly "Daylight Developer ID" and "Daylight Camera Developer ID".
4. One App Store Connect API Team Key (for notarization): download the `.p8` once, note the Key ID and the Issuer ID.
5. Eight `gh secret set` commands with the names `DAYLIGHT_TEAM_ID`, `DAYLIGHT_DEVELOPER_ID_P12_BASE64`, `DAYLIGHT_DEVELOPER_ID_P12_PASSWORD`, `DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64`, `DAYLIGHT_EXT_PROVISIONING_PROFILE_BASE64`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_PRIVATE_KEY_BASE64`.

Done looks like: `gh secret list` shows the eight names.

If it fails: `docs/SIGNING.md` section "Every failure and its remedy".

---

## Step 6: the first notarized build (25 min, mostly waiting)

1. Start it one of two ways: `gh workflow run whiteboard-camera.yml --ref claude/daylight-whiteboard-camera-tzxfjb -f notarize=true`, or tag the release: `git tag v0.1.0 && git push origin v0.1.0` (the version file already says `0.1.0`).
2. Watch: `gh run watch` (or Actions in the browser). The Linux jobs take 1 to 3 minutes, the mac job about 10 minutes plus the notarization wait (usually under 5 minutes, up to 30).
3. Done looks like: every job green and three extra artifacts on the run: `release-logs`, `Daylight-signed`, `Daylight-dmg`. Download `Daylight-dmg`: `gh run download <run id> -n Daylight-dmg`.

If it fails: the mac job's "Signed and notarized build" step prints the reason in its first lines (`mac-release: ERROR: ...`) and the `release-logs` artifact holds `archive.log`, `export.log`, `profile-check.txt`, `signed-flag.txt`, `notarytool-submit.err` and `notarization-log.json`. Match the message against `docs/SIGNING.md` "Every failure and its remedy". A plain push to the branch (without the tag or the notarize input) signs but does not notarize, and that build's extension fails on the Mac with row 9 ("macOS refused the extension's signature. This build is not notarized."): always install from a tag or a notarize run.

---

## Step 7: install the signed app and approve the camera extension (10 min)

Done looks like: `systemextensionsctl list` in Terminal shows `com.twelve.daylight.camera` as `[activated enabled]`, and the Welcome row "Install Daylight Camera" reads "Daylight Camera is installed and connected."

1. Quit the unsigned Daylight (menu bar > "Quit Daylight"). Open `Daylight.dmg`, drag Daylight to Applications (replace the old one). Eject the DMG.
2. Open Daylight from `/Applications` (never from Downloads or the DMG itself: row 1 "Move Daylight to your Applications folder, then open it from there."). The first launch of a notarized app checks with Apple online; be on the internet.
3. The Welcome window row "Install Daylight Camera" shows "Click Install to add the Daylight Camera extension." Click "Install". macOS now wants your approval; the row changes to "Approve 'Daylight Camera' in System Settings > General > Login Items & Extensions > Camera Extensions, then click Check again."
4. Click "Open System Settings". On macOS 15 and macOS 26 the pane is General > Login Items & Extensions > Camera Extensions (if the button lands elsewhere, type "Camera Extensions" in the System Settings search field; on macOS 13 and 14 the switch is under Privacy & Security > Security). Switch Daylight Camera on, enter your password.
5. Back in Daylight click "Check again". Within 2 s the row turns green. If macOS says a restart is needed, the row reads "Restart your Mac once to finish installing Daylight Camera." (row 12b): restart once.
6. Finish the Welcome window: tick "Launch Daylight at login", click "Done".

Tell the integrator which macOS the M5 Max runs (LOOSE_ENDS A2) and whether the "Open System Settings" button landed on the right pane (LOOSE_ENDS E13).

If it fails: the row says "Daylight Camera is installed but not found yet. Retrying..." and after 30 s "Open Zoom or FaceTime once, or restart your Mac." (row 13: open FaceTime once); "macOS refused the extension's signature. This build is not notarized." (row 9: you installed a plain-push build; use the tag build); "The camera extension is missing an entitlement (build signing problem)." (row 6: the app profile was made without System Extension ticked; fix the App ID, regenerate the profile, re-set the secret, re-run); "Your Mac's security policy blocks system extensions (MDM or SIP setting)." (row 11: a managed Mac).

---

## Step 8: pick Daylight Camera in Zoom, Meet or FaceTime (5 min)

Done looks like: the call shows your webcam; touching the pen slides it into Studio Split; the camera LED goes off 60 s after you leave the call.

- FaceTime: menu Video > "Daylight Camera". The fastest first test.
- Zoom: Settings > Video > Camera > "Daylight Camera". If Zoom shows a black picture after you updated Daylight, quit and reopen Zoom (row 15).
- Google Meet (Chrome): in the meeting, More options > Settings > Video > Camera > "Daylight Camera". Chrome asks for camera permission the first time.
- Quit Daylight while FaceTime is open: the call shows a cream card "Daylight is not running. Open Daylight from the menu bar." Open Daylight again: your webcam is back within 2 s. This is the extension's own placeholder and the proof that the extension and the app talk.

---

## The daily gestures, once everything is paired

| You want | Tablet | Pen side button (mirror mode) | Mac hotkey (Ctrl+Opt+Cmd + key) | Menu bar |
|---|---|---|---|---|
| Board up by drawing | touch the pen | touch the pen | | |
| Keep the board up (pin) | tap the chip ("KEEP WHITEBOARD"), or the "Pin" pill | double press | K | "Keep whiteboard" |
| Clear the page (saves first, returns unless pinned) | toolbar "Clear", or the "Clear" pill | hold 0.7 s | C | "Clear" |
| Back to the camera now | hold the chip 0.6 s | | Esc | "Camera" |
| Board up without drawing | | | D (Studio Split), W (Whiteboard Only) | "Whiteboard now (Studio Split)", "Whiteboard now (Whiteboard Only)" |
| New page (saves the old one, board stays) | toolbar "New page" | | | |
| Force a layout, no idle return | | | | "Hold" > "Camera" / "Studio Split" / "Whiteboard Only" / "Auto" |

Lift the pen and the board returns to the camera after 90 s; the divider breathes amber from 85 s and the chip counts "Returning in 5". Touching the pen during the countdown or the slide cancels the return. Hotkeys are in Settings > Hotkeys; pressing the active layout hotkey again returns to the camera.

Where sessions are saved: `~/Documents/Daylight Camera/<yyyy-MM-dd>/<HH-mm-ss>/page-01.png` plus `page-01.json` (the strokes), one pair per page; mirror sessions write `mirror-<HH-mm-ss>.png`. Saved on return, on Clear, on New page, every 60 s while drawing, on Hold: Camera and on quit. Settings > Saving changes the folder.

Switching ink sources: menu bar > "Ink source" > "Web whiteboard" / "Daylight Ink app" / "Mirror the tablet". It applies at once; a tablet on the other source shows "Ink source is <web / Daylight Ink / mirror> on the Mac" instead of silently not drawing.

---

## Uninstall (5 min)

1. Menu bar > "Settings..." > General > switch off "Launch at login". Menu bar > "Quit Daylight".
2. Drag `/Applications/Daylight.app` to the Trash. macOS removes the camera extension with the app; `systemextensionsctl list` no longer shows `com.twelve.daylight.camera` (a restart may be asked).
3. Optional leftovers: `~/Library/Application Support/Daylight/` (the allowed tablets in `clients.json` and a copy of adb), `defaults delete com.twelve.daylight` (the settings), and your pages in `~/Documents/Daylight Camera/`.
4. Tablet: Settings > Apps > Daylight Ink > Uninstall (or, over the cable, `adb uninstall com.twelve.daylight.ink` with Daylight's adb at `Daylight.app/Contents/Resources/Vendor/adb` before you trash the app); remove the home screen icon; Developer options > USB debugging off if you no longer want it.

---

## 📋 ADHD-friendly checklist (tick in order; ⏱️ about 3 hours in total, split over a day)

🟢 = setup, ✍️ = draw something, 🟡 = make it fail on purpose, 🟣 = confirm a file or a fact, 📋 = paste a line into `docs/LOOSE_ENDS.md`

- [ ] 🟢 `brew install gh`, `gh auth login`, clone, `git checkout claude/daylight-whiteboard-camera-tzxfjb`. You see: `gh auth status` prints your login. ⏱️ 10 minutes
- [ ] 🟢 `gh run list --workflow whiteboard-camera --branch claude/daylight-whiteboard-camera-tzxfjb --limit 3`, pick a green run, `gh run download <id> -n Daylight-unsigned`. You see: `Daylight-unsigned.zip` in the folder. ⏱️ 3 minutes
- [ ] 🟢 Unzip, drag to Applications, right-click > Open (or Privacy & Security > Open Anyway). You see: a camera icon in the menu bar and the preview window with your face. You feel: nothing else changed on the Mac. ⏱️ 3 minutes
- [ ] 🟢 Welcome window: click "Allow camera access", Allow. You see: the first row reads "This is an unsigned test build..." and the preview is live. ⏱️ 1 minute
- [ ] 🟢 Click the menu line "Open http://...:7788 on your Daylight"; type it into Chrome on the tablet; tap "Tap to start". You see: Chrome goes full screen, the chip reads "Look at your Mac". ⏱️ 3 minutes
- [ ] 🟢 Click "Allow" on the Mac's floating panel. You see: the chip reads "Camera". ⏱️ 30 seconds
- [ ] ✍️ Write one word. You see: the preview slides into Studio Split, the ink appears, the chip reads "LIVE" with an amber dot. You feel: the slide is a quarter second, no pop. ⏱️ 1 minute
- [ ] ✍️ Rest your palm, swipe a finger, hover the pen. You see: nothing drawn, no slide. ⏱️ 1 minute
- [ ] ⏱️ Lift the pen and wait 90 s. You see: amber breathing at 85 s, the chip counts "Returning in 5", the camera is back at 90 s. ⏱️ 2 minutes
- [ ] 🟣 Finder: `~/Documents/Daylight Camera/<today>/<time>/page-01.png` and `page-01.json` exist. ⏱️ 1 minute
- [ ] ✍️ Tap the chip. You see: "KEEP WHITEBOARD" in black. Hold the chip for a second. You see: back to "Camera". ⏱️ 1 minute
- [ ] ✍️ Press Ctrl+Opt+Cmd+D. You see: Studio Split without drawing; press it again: camera. ⏱️ 1 minute
- [ ] 📋 Tablet "?" card: copy the "This tablet" facts into LOOSE_ENDS D8 and the `first pen pointerdown` line into D3 and D4. ⏱️ 2 minutes
- [ ] 🟢 Tablet: Developer options > USB debugging on; plug in; "Always allow from this computer", Allow. ⏱️ 3 minutes
- [ ] 🟢 Mac: "Ink source" > "Daylight Ink app"; Welcome window > "Set up over USB". You see: the app opens on the tablet by itself, its chip reads "Camera". ⏱️ 2 minutes
- [ ] 🟢 Tablet: "Open the permission screen" > Daylight Ink > "Allow display over other apps" > Back; "Allow notifications"; "Start writing". ⏱️ 2 minutes
- [ ] ✍️ Write one word in Daylight Ink. You see: ink under the pen at once, chip "LIVE", the board in the preview. ⏱️ 1 minute
- [ ] 🟣 Unplug the cable. You see: within 10 s the chip reads "Camera" again and the Mac shows the Allow panel once; click "Allow". ⏱️ 1 minute
- [ ] 📋 Daylight Ink > Settings > "This tablet": copy `model=`, `pressureRange=`, `sideButton=`, `frontBuffer=`, `tiramisuExt=`, `canDrawOverlays=` into LOOSE_ENDS D2, D3, D4, D14, D11, D15. ⏱️ 2 minutes
- [ ] 🟢 Plug in; "Ink source" > "Mirror the tablet"; menu bar > "Diagnostics...". You see: `mirror.status: mirroring <serial> 1200x1600` within 2 s. ⏱️ 1 minute
- [ ] ✍️ Write in the SolOS note app. You see: the preview slides, the tablet screen is in the board slot, the pills row at the top of the tablet is not in the picture. ⏱️ 1 minute
- [ ] ✍️ Double press the pen side button. You see: menu "Keep whiteboard" ticked. Hold it 0.7 s. You see: the board clears and returns. ⏱️ 1 minute
- [ ] 📋 Diagnostics: copy `mirror.pen.node` (or `mirror.pen.status` when no pen node was found), the `getevent -pl devices:` line and `mirror.session.deviceModel` into LOOSE_ENDS D1 and D2. ⏱️ 2 minutes
- [ ] 🟢 Open `docs/SIGNING.md` and do its checklist (certificate, App IDs, profiles, API key, eight secrets). You see: `gh secret list` shows eight names. ⏱️ 30 minutes
- [ ] 🟢 `gh workflow run whiteboard-camera.yml --ref claude/daylight-whiteboard-camera-tzxfjb -f notarize=true`, then `gh run watch`. You see: every job green, artifacts `release-logs`, `Daylight-signed`, `Daylight-dmg`. ⏱️ 25 minutes (coffee)
- [ ] 🟢 `gh run download <id> -n Daylight-dmg`; quit the old Daylight; open the DMG; drag to Applications; eject; open from Applications. You see: the Welcome row "Install Daylight Camera" with an "Install" button. ⏱️ 3 minutes
- [ ] 🟢 Click "Install", then "Open System Settings"; switch Daylight Camera on under General > Login Items & Extensions > Camera Extensions; password; back in Daylight click "Check again". You see: the row turns green within 2 s. ⏱️ 3 minutes
- [ ] 🟣 Terminal: `systemextensionsctl list`. You see: `com.twelve.daylight.camera` with `[activated enabled]`. ⏱️ 30 seconds
- [ ] 🟢 FaceTime > Video > "Daylight Camera". You see: your webcam. Touch the pen: the call slides to Studio Split. You feel: this is the whole product. ⏱️ 2 minutes
- [ ] 🟡 Quit Daylight while FaceTime is open. You see: a cream card "Daylight is not running. Open Daylight from the menu bar." Reopen Daylight: your webcam is back within 2 s. ⏱️ 1 minute
- [ ] ⏱️ Close FaceTime and wait 60 s. You see and feel: the webcam LED goes off. Open FaceTime again: the picture is back within a second. ⏱️ 2 minutes
- [ ] 📋 Tell the integrator: which macOS runs on the M5 Max (LOOSE_ENDS A2), and the six decisions A3, A4, A5, A6, A14 (one line each). ⏱️ 5 minutes
- [ ] 📋 Then run `docs/TESTING-CHECKLIST.md`, one session at a time (Mac only, web, Daylight Ink, mirror, signed camera). ⏱️ 60 to 90 minutes, in pieces
