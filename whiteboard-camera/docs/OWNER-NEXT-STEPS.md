# Owner next steps: from zero to Daylight Camera in a call

This is the one page to open first. It walks from "I have a Mac without Xcode and a tablet in a box" to "Zoom shows my whiteboard when I touch the pen", in order, with a time estimate per step, what done looks like, and what to do when a step fails. Everything else in `docs/` is reference; this page tells you when to open which one.

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

## What you have and what you do not, in one paragraph

Every component is built and green in CI (`docs/STATUS.md`), but nothing has run on real hardware. Two things only you can do: sign the Mac app with your Apple Developer account (without it the virtual camera cannot appear in any call; the unsigned build still shows everything in a preview window), and put the DC-1 next to the Mac to confirm the tablet facts the code guessed (`docs/LOOSE_ENDS.md` section D). You need no Xcode at any point: GitHub Actions builds, signs and notarizes; your Mac only needs Keychain Access, Terminal and the `gh` command.

Order of the day, and why: try the web whiteboard first (nothing to install on the tablet, works from the unsigned build in the preview window), then Daylight Ink over USB (one click installs it), then mirror mode (needs USB debugging on the tablet), then mirror over Wi-Fi (no USB debugging: Daylight Ink shares the tablet screen itself). Signing can run in parallel; it is 30 minutes of clicking in Apple's portal and then CI does the rest.

| Step | What | Time | Needs |
|---|---|---|---|
| 0 | Install the tools on the Mac | 10 min | the Mac, internet |
| 1 | Download the unsigned build and open the preview | 10 min | the Mac |
| 2 | Pair the web whiteboard | 10 min | the DC-1 on the same Wi-Fi |
| 3 | Pair Daylight Ink over USB | 10 min | a USB-C cable, USB debugging on the DC-1 |
| 4 | Try mirror mode | 10 min | the same cable |
| 4b | Try mirror over Wi-Fi (no USB debugging) | 10 min | Daylight Ink from step 3, the same Wi-Fi |
| 5 | Signing in Apple's portal and the eight secrets | 30 min | your Apple Developer account, `gh` |
| 6 | The first notarized build | 25 min, mostly waiting | step 5 |
| 7 | Install the signed app and approve the camera extension | 10 min | step 6 |
| 8 | Pick Daylight Camera in Zoom, Meet or FaceTime | 5 min | step 7 |
| 8b | Try overlay mode (optional) | 10 min | step 1 (the preview window is enough) |
| 9 | Run the testing checklist and paste the facts | 60 to 90 min | everything above |

---

## Step 0: install the tools on the Mac (10 min)

Done looks like: `gh auth status` prints your GitHub login and `gh run list --limit 1` prints a run.

1. Install Homebrew if the Mac does not have it (brew.sh shows the one-line installer), then `brew install gh`.
2. `gh auth login` in Terminal, choose GitHub.com, HTTPS, log in through the browser.
3. `cd` into a clone of the repository (`git clone https://github.com/12twelve12hi/daylight-control-your-mac.git`, then `cd daylight-control-your-mac`). The build branch is `claude/daylight-whiteboard-camera-tzxfjb`: `git checkout claude/daylight-whiteboard-camera-tzxfjb`. The same code is also published standalone at https://github.com/12twelve12hi/whiteboard-camera-draw, where `main` runs the same CI; the commands on this page use the monorepo, and either repository's green run gives you the same artifacts.
4. `gh run list --workflow whiteboard-camera --branch claude/daylight-whiteboard-camera-tzxfjb --limit 3` lists the latest runs. A green one is what you download in step 1.

If it fails: `gh` says "not logged in" (run `gh auth login` again); `gh run list` says the workflow does not exist (you are in the wrong folder; the workflow file is `.github/workflows/whiteboard-camera.yml` at the monorepo root).

Optional, for later: the `adb` you need for the tablet is bundled inside the app at `Daylight.app/Contents/Resources/Vendor/adb`; you do not need Android Studio or Homebrew's platform-tools, and a second adb on the Mac is one of the failure rows (24). Settings > Mirror > "adb source" can instead use "Download on first use" (Google's platform-tools 37.0.0 after you accept the Android SDK License once) or "Use installed adb" (the one from Homebrew or Android Studio, platform-tools 35 or newer); the default "Bundled (default)" needs nothing. A new choice applies the next time Daylight starts; `docs/SETUP.md` section 2.3 "adb source" has the details.

---

## Step 1: download the unsigned build and open the preview (10 min)

This build cannot install the virtual camera (that needs signing, step 5). It shows the menu bar item, the Welcome window, the preview window of what the camera would show, the web page, the Allow panel, saving and hotkeys. It is enough for steps 2 to 4.

Done looks like: a camera icon in the menu bar, a "Welcome to Daylight" window whose first row reads "This is an unsigned test build. The virtual camera cannot be installed on this Mac. Use Daylight > Preview window to see the output.", and, once you have clicked "Allow camera access", the preview window showing your webcam.

1. Find the run id of the latest green run from step 0, then `gh run download <run id> -n Daylight-unsigned` (or in the browser: Actions > whiteboard-camera > the run > Artifacts > `Daylight-unsigned`). You get `Daylight-unsigned.zip`. Download from the monorepo's runs (`12twelve12hi/daylight-control-your-mac`) or from the standalone repository `12twelve12hi/whiteboard-camera-draw` (`gh run download` with `-R 12twelve12hi/whiteboard-camera-draw`); both build the same code.
2. Double-click the zip. Drag `Daylight.app` into `/Applications` (not required for the unsigned build, but it is where the signed one must live, so start the habit).
3. Open it. macOS refuses an unsigned app on the first double-click. Either right-click `Daylight.app` > Open, or go to System Settings > Privacy & Security, scroll down to the message about Daylight and click Open Anyway, or in Terminal `xattr -dr com.apple.quarantine /Applications/Daylight.app` (recursive, so the bundled adb loses the flag too) and open it normally.
4. The preview window opens by itself on unsigned builds, cream and empty at first: the first launch does not ask for camera access on its own. In the Welcome window click "Allow camera access", then Allow in the macOS prompt; the preview shows your webcam within a second. macOS 26 and 15 may also ask whether Daylight may find devices on the local network: Allow (it is how the tablet finds the Mac).
5. The menu bar icon is a camera. Closing the Welcome window with its red button only hides it until the next launch; "Done" finishes it (enabled on an unsigned build as soon as the camera row is not blocked), and menu bar > "Setup again" reopens it any time.

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

Optional one-time step for better ink over Wi-Fi: the page's "?" button opens a card with a `chrome://flags/#unsafely-treat-insecure-origin-as-secure` line and the origin to paste; it stays optional and offered, never required (LOOSE_ENDS A5, confirmed 2026-10-03).

---

## Step 3: pair Daylight Ink over USB (10 min)

Why second: the same stroke protocol as the web page, but native: unbuffered pen input, the wet ink is drawn in the front buffer, and the app reconnects by itself every day without a browser. Also the one that gives you the floating Pin and Clear pills for mirror mode.

Done looks like: the Daylight Ink app opens on the tablet by itself, its chip reads "Camera", and writing engages the board exactly as in step 2.

1. Tablet, once: Settings > About > tap Build number seven times; Settings > Developer options > USB debugging on. If SolOS lists "Disable adb authorization timeout", turn it on (LOOSE_ENDS D6; without it Android forgets the Mac after 7 days).
2. Plug the tablet into the Mac. The tablet asks "Allow USB debugging?": tick "Always allow from this computer", tap Allow.
3. Mac: menu bar > "Ink source" > "Daylight Ink app". Open the Welcome window (menu bar > "Setup again" if it is closed), go to the "Your Daylight" row: it reads "A Daylight is on USB (<serial>). Set up over USB does everything for the chosen ink source." Click "Set up over USB". The Mac installs the APK, grants the two permissions, forwards the port and opens the app with the Mac's address.
4. Tablet: the app opens. On the first run it shows "Welcome to Daylight Ink": the first row reads "Looking for your Mac... Enter its address if this takes long" and switches to "Connected to ..." by itself over the cable. The Mac granted the two permissions over USB, so the overlay row already reads "Allowed" and the notifications row "Allowed"; only without the cable do you tap "Open the permission screen" (pick Daylight Ink, switch on "Allow display over other apps", press Back) and "Allow notifications". Tap "Start writing". Over USB there is no Allow panel on the Mac: a cable connection is trusted. With Settings > Mirror > "Pin and Clear in mirror mode" at its default "Both", the floating "Pin" and "Clear" pills also appear at the top of the tablet; they are meant for mirror mode and Daylight Ink > Settings > "Hide the pills" removes them.
5. Write one word: the chip reads "LIVE", the preview slides, the ink is under the pen at once.
6. Unplug the cable, keep Wi-Fi on: the app reconnects over Bonjour within about 10 s and the Mac asks "Allow 'Daylight Ink on <model>' to draw on Daylight Camera?" once. Click "Allow". From now on the app reconnects by itself, cable or not.

If it fails: the Mac says "No Daylight found over USB. Is USB debugging on?" (row 21: debugging off, or the cable is charge-only); "Tap Allow on your Daylight (tick Always allow)." (row 22: the RSA prompt is waiting on the tablet); "The Daylight is connected but not responding. Unplug and plug again." (row 23); "Another adb is running (Android Studio?)..." (row 24: Daylight uses its own adb on a private port; a tablet already claimed by the other adb stays invisible until you quit it); "Set up over USB failed: adb ... install ... failed: <reason>" (the tablet was found but a step after it failed; the reason is Android's, for example `INSTALL_FAILED_OLDER_SDK`: copy the line into LOOSE_ENDS D). The "A Daylight is on USB" sentence can take up to 5 s to appear after you plug in (Daylight lists USB devices every 5 s while the Welcome window is open). No cable at all? Open the web page from step 2, tap "?", tap "Download Daylight Ink", install it (one-time "allow from this source"), open it: it finds the Mac over Bonjour and the Mac shows the Allow panel.

---

## Step 4: try mirror mode (10 min)

Why last: it needs USB debugging, it streams video of the whole tablet screen (about 1 MB/s) instead of strokes, and it produces no vector record. What it buys you: any app on the tablet, for example the SolOS note app, can be the whiteboard.

Done looks like: menu bar > "Diagnostics..." shows `mirror.status: mirroring <serial> 1200x1600`; touching the pen in the note app slides the preview to Studio Split with the tablet screen in the board slot, top strip cropped.

1. Cable in (step 3 already authorised the Mac). Mac: menu bar > "Ink source" > "Mirror the tablet". Wait two seconds.
2. Tablet: open the note app, write. The preview slides within about a tenth of a second; the picture follows a little later (encoder, adb, decoder).
3. Pin and Clear here are the two floating pills "Pin" and "Clear" at the top of the tablet (Daylight starts them over the cable) and the pen's side button: double press = Pin, hold for 0.7 s = Clear and return. Settings > Mirror > "Pin and Clear in mirror mode" picks "Floating pills", "Pen side button" or "Both".
4. The top 96 tablet pixels (where the pills live) are cropped out of the camera picture. If the crop is wrong, Settings > Mirror > Crop, drag the edges over the live picture.

If it fails: "The screen mirror could not start: ..." (row 25; copy the sentence into LOOSE_ENDS); "Pen events not found on this Daylight. Mirror works, but auto-engage and the pen button do not. Use the pills or the Whiteboard hotkey." (row 28: the Wacom input node is not where the code expects; paste the Diagnostics `mirror.pen.status` line (it reads "no pen node among [...]") into LOOSE_ENDS D1); "Pen button events not seen; use the pills." (row 28b). "Recovering video..." means the decoder is waiting for a key frame (row 27); after 12 s without one Daylight restarts the mirror by itself; if the text stays, unplug and replug.

---

## Step 4b: try mirror over Wi-Fi, no USB debugging (10 min, optional)

Why: the same mirror picture without developer options or a cable. Daylight Ink captures the tablet screen itself (Android asks for consent each time sharing starts) and sends it over the Wi-Fi connection it already holds. The board slides in when the screen changes inside the canvas crop, so it starts later than over USB (an estimate of 150 to 300 ms, `docs/COMPARE.md` section 2.1), and the tablet's battery drains faster because nothing charges it.

Done looks like: menu bar > "Diagnostics..." shows `mirror.wifi.tabletState: streaming` and `mirror.wifi.engageSource: frame difference`; writing in the note app slides the preview to Studio Split with the tablet screen in the board slot.

1. Mac: menu bar > "Settings..." > Mirror > "Transport" > "Wi-Fi (Daylight Ink screen stream)". Then menu bar > "Ink source" > "Mirror the tablet". (This is not the older "Mirror over Wi-Fi after a USB session" switch, which still needs USB debugging.)
2. Tablet: open Daylight Ink > Settings. Under "Share this screen with the Mac over Wi-Fi (no cable, no USB debugging)" tap "Share screen with your Mac".
3. Android asks whether Daylight Ink may record or cast the screen; tap "Start now" (write down the exact SolOS wording, LOOSE_ENDS D19). The notification "Sharing screen with your Mac" appears and stays while sharing is ready.
4. Write in the SolOS note app. The Daylight Ink state line reads "Sharing with your Mac" and the board slides in when the ink appears. Pin and Clear are the floating pills.
5. When the call ends, tap "Stop" in the notification.

If it fails: "Daylight Ink was not allowed to share the tablet screen. Tap the Daylight Ink notification on the tablet and choose Start now." (row 34: you tapped Cancel); "Your Daylight could not start its screen encoder. Restart Daylight Ink, or use Mirror over USB." (row 35); "The tablet's screen stream paused. Reconnecting..." (row 36: Wi-Fi congestion or a still screen the encoder stopped repeating, D21); "Open Daylight Ink on your Daylight to mirror over Wi-Fi." (row 38: no Daylight Ink connection announced the capability; open the app). Scrolling or animations that start the board by mistake: raise Settings > Mirror > "Change threshold". The full owner run is `docs/TESTING-CHECKLIST.md` Session 4b.

---

## Step 5: signing in Apple's portal and the eight GitHub secrets (30 min)

The virtual camera is a macOS system extension, and macOS loads one only from an app signed with a Developer ID certificate and notarized by Apple. Everything happens in your browser and Keychain Access; `docs/SIGNING.md` has every click, every failure and its remedy. The short form:

1. Developer ID Application certificate (Keychain Access makes the request file; Apple's portal issues the certificate; export it as a `.p12` with a password).
2. Two App IDs: `com.twelve.daylight` with System Extension and App Groups ticked, `com.twelve.daylight.camera` with App Groups ticked.
3. Two Developer ID provisioning profiles, one per App ID; call them "Daylight Developer ID" and "Daylight Camera Developer ID" (the build reads each profile's name from the file, so the name itself is yours to choose).
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
3. Daylight asks macOS to install the extension by itself at launch, so there is no Install button to click on a fresh launch: the Welcome row "Install Daylight Camera" reads "Installing..." for a moment, macOS shows its own dialog about the camera extension (with an Open System Settings button of its own), and the row changes to "Approve 'Daylight Camera' in System Settings > General > Login Items & Extensions > Camera Extensions, then click Check again." (The row's own "Install" button appears only when nothing is pending, for example after you removed the extension.)
4. Click "Open System Settings". On macOS 26 and macOS 15 the pane is General > Login Items & Extensions > Camera Extensions (if the button lands elsewhere, type "Camera Extensions" in the System Settings search field; on macOS 13 and 14 the switch is under Privacy & Security > Security). Switch Daylight Camera on, enter your password.
5. Back in Daylight click "Check again". Within 2 s the row turns green. If macOS says a restart is needed, the row reads "Restart your Mac once to finish installing Daylight Camera." (row 12b): restart once.
6. Finish the Welcome window: tick "Launch Daylight at login", click "Done".

Tell the integrator whether the "Open System Settings" button landed on the right pane (LOOSE_ENDS E13); the wording above assumes macOS 26 on the M5 Max (LOOSE_ENDS A2, settled 2026-10-03).

If it fails: the row says "Daylight Camera is installed but not found yet. Retrying..." and after 30 s "Open Zoom or FaceTime once, or restart your Mac." (row 13: open FaceTime once); "macOS refused the extension's signature. This build is not notarized." (row 9: you installed a plain-push build; use the tag build); "The camera extension is missing an entitlement (build signing problem)." (row 6: the app profile was made without System Extension ticked; fix the App ID, regenerate the profile, re-set the secret, re-run); "Your Mac's security policy blocks system extensions (MDM or SIP setting)." (row 11: a managed Mac).

---

## Step 8: pick Daylight Camera in Zoom, Meet or FaceTime (5 min)

Done looks like: the call shows your webcam; touching the pen slides it into Studio Split; the camera LED goes off 60 s after you leave the call.

- FaceTime: menu Video > "Daylight Camera". The fastest first test.
- Zoom: Settings > Video > Camera > "Daylight Camera". If Zoom shows a black picture after you updated Daylight, quit and reopen Zoom (row 15).
- Google Meet (Chrome): in the meeting, More options > Settings > Video > Camera > "Daylight Camera". Chrome asks for camera permission the first time.
- Quit Daylight while FaceTime is open: the call shows a cream card "Daylight is not running. Open Daylight from the menu bar." Open Daylight again: your webcam is back within 2 s. This is the extension's own placeholder and the proof that the extension and the app talk.

---

## Step 8b: try overlay mode (10 min, optional)

Why: Overlay keeps the board full width and puts you, cut out of your background, in a small square in a corner (SPEC 6.7). It suits a talk where your face matters but the board should get the whole picture; Studio Split stays better when your face must be large or the room is dark (`docs/COMPARE.md` section 3.1). It is off by default, and while it is off nothing of it runs or shows.

Done looks like: drawing (or Ctrl+Opt+Cmd+O) slides the board in from the left while your full camera picture shrinks into a square in the bottom-right corner, about a quarter of the picture height, with your background removed.

1. Mac: menu bar > "Settings..." > Overlay > switch on "Enable overlay mode".
2. Pick Overlay: either Settings > General > "Layout when engaging" > "Overlay" (then simply draw), or press Ctrl+Opt+Cmd+O at any time (press it again to go back to the camera). The menu bar also gains "Whiteboard now (Overlay)".
3. Look for: a clean edge around your head and shoulders, no flicker when you sit still, your hands showing when you gesture near your face, and the board fully readable behind the square. Try the other Overlay settings if something looks off: Smoothing (less flicker, slower to follow you), Edge softness, the amber outline, Size, Position and Opacity.
4. Look for the two safety nets: dim the room or step out of view and the square shows your whole camera picture as a plain rectangle (row 49); if segmentation fails repeatedly, the board falls back to Studio Split and the menu shows "Overlay mode could not find you in the camera picture, so Daylight is showing Studio Split. Turn Overlay off and on in Settings > Overlay to try again." (row 48).
5. To turn it off: Settings > Overlay > switch off "Enable overlay mode". The Overlay menu item, the hotkey and the "Overlay" choice disappear, and a stored "Overlay" layout engages as Studio Split until you switch it on again.

If you run with `--perf-log`, Overlay adds `perf overlay seg_ms=... mask_age_ms=...` lines; paste one into `docs/LOOSE_ENDS.md` E30. The full owner run is `docs/TESTING-CHECKLIST.md` session "Overlay mode (optional, v2)".

---

## The daily gestures, once everything is paired

| You want | Tablet | Pen side button (mirror mode) | Mac hotkey (Ctrl+Opt+Cmd + key) | Menu bar |
|---|---|---|---|---|
| Board up by drawing | touch the pen | touch the pen | | |
| Keep the board up (pin) | tap the chip ("KEEP WHITEBOARD"), or the "Pin" pill | double press | K | "Keep whiteboard" |
| Clear the page (saves first, returns unless pinned) | toolbar "Clear", or the "Clear" pill | hold 0.7 s | C | "Clear" |
| Back to the camera now | hold the chip 0.6 s | | Esc | "Camera" |
| Board up without drawing | | | D (Studio Split), W (Whiteboard Only), O (Overlay, only while enabled) | "Whiteboard now (Studio Split)", "Whiteboard now (Whiteboard Only)", "Whiteboard now (Overlay)" (only while enabled) |
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
- [ ] 🟢 Unzip, drag to Applications, right-click > Open (or Privacy & Security > Open Anyway). You see: a camera icon in the menu bar, the Welcome window and an empty cream preview window. You feel: nothing else changed on the Mac. ⏱️ 3 minutes
- [ ] 🟢 Welcome window: click "Allow camera access", Allow. You see: the first row reads "This is an unsigned test build..." and the preview shows your face. ⏱️ 1 minute
- [ ] 🟢 Click the menu line "Open http://...:7788 on your Daylight"; type it into Chrome on the tablet; tap "Tap to start". You see: Chrome goes full screen, the chip reads "Look at your Mac". ⏱️ 3 minutes
- [ ] 🟢 Click "Allow" on the Mac's floating panel. You see: the chip reads "Camera". ⏱️ 30 seconds
- [ ] ✍️ Write one word. You see: the preview slides into Studio Split, the ink appears, the chip reads "LIVE" with an amber dot. You feel: the slide is a quarter second, no pop. ⏱️ 1 minute
- [ ] ✍️ Rest your palm, swipe a finger, hover the pen. You see: nothing drawn, no slide. ⏱️ 1 minute
- [ ] ⏱️ Lift the pen and wait 90 s. You see: amber breathing at 85 s, the chip counts "Returning in 5", the camera is back at 90 s. ⏱️ 2 minutes
- [ ] 🟣 Finder: `~/Documents/Daylight Camera/<today>/<time>/page-01.png` and `page-01.json` exist. ⏱️ 1 minute
- [ ] ✍️ Tap the chip. You see: "KEEP WHITEBOARD" in black. Hold the chip for a second. You see: back to "Camera". ⏱️ 1 minute
- [ ] ✍️ Press Ctrl+Opt+Cmd+D. You see: Studio Split without drawing; press it again: camera. ⏱️ 1 minute
- [ ] 📋 Tablet "?" card: copy the "This tablet" facts into LOOSE_ENDS D8. ⏱️ 2 minutes
- [ ] 📋 Chrome console (desktop Chrome `chrome://inspect#devices` over the cable): copy the `daylight-web first pen pointerdown` line into D3 and D4; Daylight Ink's "This tablet" gives the same facts without a console. ⏱️ 3 minutes
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
- [ ] 🟢 Unplug. Mac: Settings > Mirror > "Transport" > "Wi-Fi (Daylight Ink screen stream)". Tablet: Daylight Ink > Settings > "Share screen with your Mac" > "Start now". You see: the notification "Sharing screen with your Mac"; Diagnostics `mirror.wifi.tabletState: streaming`. ⏱️ 2 minutes
- [ ] ✍️ Write in the SolOS note app without the cable. You see: the board slides in shortly after the ink appears. 📋 Write down the prompt wording (D19) and roughly how late the slide feels (D20). Tap "Stop" in the notification afterwards. ⏱️ 3 minutes
- [ ] 🟢 Open `docs/SIGNING.md` and do its checklist (certificate, App IDs, profiles, API key, eight secrets). You see: `gh secret list` shows eight names. ⏱️ 30 minutes
- [ ] 🟢 `gh workflow run whiteboard-camera.yml --ref claude/daylight-whiteboard-camera-tzxfjb -f notarize=true`, then `gh run watch`. You see: every job green, artifacts `release-logs`, `Daylight-signed`, `Daylight-dmg`. ⏱️ 25 minutes (coffee)
- [ ] 🟢 `gh run download <id> -n Daylight-dmg`; quit the old Daylight; open the DMG; drag to Applications; eject; open from Applications. You see: within a few seconds the Welcome row "Install Daylight Camera" reads "Approve 'Daylight Camera' in System Settings > ..." (Daylight submits the install request itself at launch). ⏱️ 3 minutes
- [ ] 🟢 Click "Open System Settings"; switch Daylight Camera on under General > Login Items & Extensions > Camera Extensions; password; back in Daylight click "Check again". You see: the row turns green within 2 s. ⏱️ 3 minutes
- [ ] 🟣 Terminal: `systemextensionsctl list`. You see: `com.twelve.daylight.camera` with `[activated enabled]`. ⏱️ 30 seconds
- [ ] 🟢 FaceTime > Video > "Daylight Camera". You see: your webcam. Touch the pen: the call slides to Studio Split. You feel: this is the whole product. ⏱️ 2 minutes
- [ ] 🟡 Quit Daylight while FaceTime is open. You see: a cream card "Daylight is not running. Open Daylight from the menu bar." Reopen Daylight: your webcam is back within 2 s. ⏱️ 1 minute
- [ ] ⏱️ Close FaceTime and wait 60 s. You see and feel: the webcam LED goes off. Open FaceTime again: the picture is back within a second. ⏱️ 2 minutes
- [ ] 🟢 Optional: Settings > Overlay > "Enable overlay mode", then Ctrl+Opt+Cmd+O. You see: the board slides in and your camera picture shrinks into a cut-out square in the bottom-right corner. Switch it off again afterwards if you prefer Studio Split. ⏱️ 5 minutes
- [ ] 📋 Tell the integrator whether the "Open System Settings" button landed on the right pane (LOOSE_ENDS E13). The decisions A2 (macOS 26), A3, A4, A5, A6 and A14 are already settled (2026-10-03). ⏱️ 1 minute
- [ ] 📋 Then run `docs/TESTING-CHECKLIST.md`, one session at a time (Mac only, web, Daylight Ink, mirror with the adb source rows 4.19 to 4.21, mirror over Wi-Fi in Session 4b, signed camera). ⏱️ 90 to 120 minutes, in pieces
