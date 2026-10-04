# What is new (2026-10-04)

Your morning page: everything that changed overnight, since the phase 3 integration (commit 26014a3). Four teams worked tonight: the Android emulator, the Mac windows on the CI runner, a fourth adversarial review with a cross-language fuzz test, and the "whiteboard too small in a group call" research. Everything below is built and green in CI; none of it has run on your Mac or the DC-1 yet. Each feature names the exact menu or setting and the `docs/TESTING-CHECKLIST.md` session that exercises it.

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming.

## (a) What you can see now, without any hardware

Every CI run now launches both real apps and photographs every screen. Five minutes, no tablet, no signing (`docs/OWNER-NEXT-STEPS.md` step 0b):

```
gh run list --workflow whiteboard-camera --branch claude/daylight-whiteboard-camera-tzxfjb --limit 3
gh run download <run id> -n mac-screenshots -n android-screenshots
```

Or in the browser, logged in to GitHub: Actions > whiteboard-camera > the newest green run > Artifacts at the bottom of the page.

| Artifact | What is in it |
|---|---|
| `mac-screenshots` | The Mac app on the macos-15 runner, in `light/` and `dark/`: the Welcome window, the menu bar item and its submenus (among them "Share the whiteboard"), all nine Settings tabs at the top and the bottom, the preview, Diagnostics and the Allow panel. The same test fails CI when a window is off screen, a control leaves its window or overlaps another, or a menu item or Settings label that the owner docs quote is not in the app as written (59 strings). |
| `android-screenshots` | Daylight Ink on an emulated Android 13 tablet at the DC-1's 1200x1600 and 200 dpi: onboarding, the whiteboard empty and with a stroke, the toolbar, Settings and "This tablet", the overlay permission screen and the pills, the screen-share prompt, connected to a stand-in Mac, and the screen after the system killed and restored the app. 25 instrumented tests ran on it. |

`docs/SCREENSHOTS.md` lists every file. What the pictures cannot show: a real webcam, the virtual camera in a call, the pen hardware, the LivePaper transflective LCD and the DC-dimmed backlight.

## (b) Features, where to find them, and which checklist session tries them

| Feature | Where you find it | Checklist |
|---|---|---|
| **New tonight: the share window.** In a call with many people your camera tile is small (as little as 180p); a shared window is the big main picture for everyone. "Daylight Whiteboard" shows only the page, at the canvas aspect, redrawn only when it changes. Works on the unsigned build | menu bar > "Share the whiteboard" > "Show share window" (also "How to share it in a call..." and "Share settings..."). Settings > Share: "Open the share window when the whiteboard slides in", "Keep the share window above other windows", "Hide the share window's title bar", and a "Show share window" button. Then share the window "Daylight Whiteboard" in Zoom (Command-Shift-S), Meet, Teams, Slack or Webex | Session 7 (7.1 to 7.9); OWNER-NEXT-STEPS step 8c |
| **New tonight, needs your answer: the Zoom second-camera check.** Whether Zoom offers Daylight Camera as a second camera decides whether the next build adds a camera made only of the page (no window to share) | signed build, in Zoom: Share Screen > Advanced > "Content from 2nd Camera" (newer Zoom: "Second camera"), Share, then "Switch Camera" until "Daylight Camera". Three answers in your note: offered or not, how many clicks, sharp, not mirrored and full size on a second device | 7.7 |
| **New tonight, not visible yet: follow the pen.** The math that magnifies the area you write in (`FollowRegion` in DaylightKit, with hysteresis and springs) is built and tested; it is not wired into the camera picture yet | nothing to set | none yet |
| Mirror over Wi-Fi, no cable and no USB debugging: Daylight Ink shares the tablet screen itself | Mac: Settings > Mirror > "Transport" > "Wi-Fi (Daylight Ink screen stream)", then menu bar > "Ink source" > "Mirror the tablet". Tablet: Daylight Ink > Settings > "Share screen with your Mac", then "Start now" | Session 4b; OWNER-NEXT-STEPS step 4b |
| Where Daylight's adb comes from | Settings > Mirror > "adb source": "Bundled (default)", "Download on first use", "Use installed adb" (Homebrew or Android Studio, platform-tools 35 or newer); a new choice applies at once | 4.19 to 4.21 |
| Overlay mode (optional, off by default): the board full frame, you cut out of your background in a corner square. Tonight's review fixed five defects in it (below) | Settings > Overlay > "Enable overlay mode"; then menu bar > "Whiteboard now (Overlay)" or Ctrl+Opt+Cmd+O | Session 6; OWNER-NEXT-STEPS step 8b |
| One file to send back after a test, now also with the self-test lines when it hangs | menu bar > "Export diagnostics...", tick "Run self-test first" when something misbehaved, Export. The zip lands in Documents > Daylight Camera and Finder shows it. Tablet facts: web page "?" > "This tablet" > "Send facts to Mac"; Daylight Ink > Settings > "This tablet" > "Send facts to Mac" | 1.16 and the end of every session; `docs/FEEDBACK.md` (new section 6 for the share window) |

## (c) What running the real apps on CI found, and fixed

Until tonight CI built the APK and the Mac app and ran their unit tests, but nothing had ever launched them. Running them found defects you would have hit first:

**Daylight Ink on the emulated tablet (all fixed, each with a test):**
- It crashed on every launch on Android 13, the DC-1's version (the window insets were read before the screen existed).
- The whiteboard canvas was 0 pixels tall: a toolbar and no place to write.
- Its buttons were invisible to accessibility (TalkBack silent, no test could press them).
- Ink vanished on rotation; strokes and the chosen tool were lost when the activity was recreated (for example by the front-buffer setting), and a recreate could open the onboarding twice.
- A stray start of the screen-share service without consent could crash.
- Also fixed: a second "Send facts to Mac" tap while sending is ignored, and the codec now rejects the four malformed message kinds the fuzz test found (an unreadable answer from the Mac now shows "Update Daylight on your Mac" instead of hanging at connecting).

**The Mac windows on the runner's small screen (all fixed, each guarded by a check that fails CI):**
- The Settings window opened half off a small screen, so the last tabs could not be clicked.
- Nine tabs (Share is new) did not fit; Settings is now 720 points wide.
- Advanced and Overlay rows ran past the right edge; labels now wrap.
- The Mirror crop view drew over the "Quality" row and the footnote.
- Saving was split into misaligned columns, and Saving and Share floated in the middle of the window.
- The hotkey fields were 40 points tall with the chord at the bottom, and VoiceOver read them as dimmed.

**Review 4 (adversarial review of the phase 3 code, all fixed with tests):** Overlay no longer spends work on a fallback nobody sees, reports its failure once (also when it fails at launch), flushes its texture cache, and never blends a stale mask (no ghost silhouette); after a "Segmentation quality" change the menu no longer keeps the fallback line. The facts route closes silent connections after 10 s, answers 413 for an oversized length and keeps control characters out of the log. The diagnostics export redacts IPv6 addresses in two more places, names a crash "killed by signal N", never rewrites ordinary numbers, and never leaves a half-written zip.

## (d) The two steps that are still yours

1. **Add the four file secrets.** The repository holds `DAYLIGHT_TEAM_ID`, `DAYLIGHT_DEVELOPER_ID_P12_PASSWORD`, `ASC_API_KEY_ID` and `ASC_API_ISSUER_ID`. Still missing: `DAYLIGHT_DEVELOPER_ID_P12_BASE64`, `DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64`, `DAYLIGHT_EXT_PROVISIONING_PROFILE_BASE64` and `ASC_API_PRIVATE_KEY_BASE64`. Each is a file turned into base64; `docs/SIGNING.md` "Owner checklist" shows how. Then `gh workflow run whiteboard-camera.yml --ref claude/daylight-whiteboard-camera-tzxfjb -f notarize=true` and download `Daylight-dmg`. Until then every run's mac job prints a signing warning and uploads only `Daylight-unsigned`. The signed build is what makes Daylight Camera appear in calls and what the Zoom second-camera check (7.7) needs.
2. **Run the device checklist.** `docs/TESTING-CHECKLIST.md`, one session at a time: Sessions 1 to 4b, 6 and 7 work on the unsigned build; Session 5 and row 7.7 need the signed one. Rows marked "proved in CI, confirm on device" already pass on the emulator. Tap "Send facts to Mac" where a row says so, finish with menu bar > "Export diagnostics...", and send the zip with one sentence per surprise and the three 7.7 answers.

## (e) The research behind tonight

`docs/product/` holds the product research of the night: why a camera tile stays small and what can be big instead (`TOO-SMALL.md`), the frictions of drawing in a video call, a drawing deep dive, ideas and reusable code from other projects, anti-patterns, what lies beyond drawing, and a roadmap proposal. Start with `docs/product/CEO-SYNTHESIS.md`, the one-page synthesis of all of it.

## (f) Later the same day: the signed build and phase 5A, part one (2026-10-04, evening)

- **Your notarized app exists.** Run 37224601354 produced `Daylight-dmg`: signed, notarized by Apple in 21 seconds, stapled, `spctl` says `accepted, source=Notarized Developer ID` (LOOSE_ENDS SG). The first submission of the day took Apple 31 to 42 minutes, longer than the script waited; the script now submits and waits in two calls (75 minutes), keeps the signed DMG as `Daylight-dmg-pending` when Apple is slow, and a `whiteboard-camera-notary` workflow finishes it later from two ids (SIGNING.md "A slow notarization").
- **Bolder ink on camera (D58).** Every stroke on the live outputs is at least 2.5 output px wide at 1080p (highlighter 6.0); the tablet, the JSON and the saved PNG keep the true widths. No setting.
- **Follow the pen (D59), off by default.** Settings > Advanced "Follow the pen on camera": the board zooms in on where you write (up to 2.5 times) and returns to the full page after 30 s without ink, on Clear and on a new page. Measured GPU cost: none (PERFORMANCE.md section 6). Checklist row 7.11.
- **Laser pointer (D60).** A "Laser" tool on the web page and in Daylight Ink; the Mac draws a fading red dot with a short trail on the camera board, never into the page, never saved. One rule on both clients: any pen contact is full intensity, stylus hover half. The Mac draws it only once the second half of phase 5A lands (its one router line lives in a file that half owns).
- **Review round over the new code:** eight findings, all fixed with tests (redo no longer counts as fresh ink for the follow camera, the output frame stays opaque around the dot, ink drawn while the board is hidden keeps its age, the two clients agree at the edges). Handoff: `docs/handoff/vp-ink-legibility.md`, "Review fixes".
- **Not landed yet:** a fresh page for every new call, `session.pdf` next to the page images, menu bar "Copy last page" and "Send today's board...", and the strokes embedded inside each PNG. The session that built them waits for one line from you in its claude.ai/code window: `yes, commit and push to claude/daylight-whiteboard-camera-tzxfjb`. It pushes, CI compiles, and the integrator finishes the rest.
