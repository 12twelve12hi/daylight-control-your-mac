# What is new (2026-10-03)

What changed since you last looked: phase 2 (mirror without a cable, a choice of adb) and phase 3 (Overlay mode, one-click diagnostics, tablet facts), plus two hardening rounds behind them. Everything below is built and green in CI and none of it has run on your Mac or the DC-1 yet. Each line names the exact menu or setting and the `docs/TESTING-CHECKLIST.md` rows that exercise it.

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming.

## Phase 2

| What | Where you find it | Checklist |
|---|---|---|
| Mirror over Wi-Fi without USB debugging or a cable: Daylight Ink shares the tablet screen itself | Mac: Settings > Mirror > "Transport" > "Wi-Fi (Daylight Ink screen stream)", then menu bar > "Ink source" > "Mirror the tablet". Tablet: Daylight Ink > Settings > "Share screen with your Mac", then "Start now" in the Android prompt; "Stop sharing" or the notification's Stop ends it | Session 4b (4b.1 to 4b.15); OWNER-NEXT-STEPS step 4b |
| The board slides in when your handwriting changes the mirrored screen (Wi-Fi transport without the USB pen stream); tuned for 2 to 4 px strokes since hardening round 3 | Settings > Mirror > "Change threshold: N canvas cells" (default 7) | 4b.3, 4b.5 |
| Where Daylight's adb comes from | Settings > Mirror > "adb source": "Bundled (default)", "Download on first use" (asks once for Google's Android SDK License), "Use installed adb" (Homebrew or Android Studio, platform-tools 35 or newer). A new choice applies at once | 4.19 to 4.21 |
| Fixes you would otherwise trip over: Cancel on the tablet's share prompt, then "Share screen with your Mac" again, now streams at once; Wi-Fi decode errors recover by themselves; quitting Daylight releases the tablet's screen share | nothing to set | 4b.10, 4b.12 |

## Phase 3

| What | Where you find it | Checklist |
|---|---|---|
| Overlay mode (optional, off by default): the board full frame, you cut out of your background in a corner square. While it is off nothing of it runs or shows | Settings > Overlay > "Enable overlay mode"; then Settings > General > "Layout when engaging" > "Overlay", or menu bar > "Whiteboard now (Overlay)", or Ctrl+Opt+Cmd+O. The Overlay tab also has "Segmentation quality", "Smoothing", "Edge softness", "Amber outline", "Size", "Position" and "Opacity" | Session 6 (6.1 to 6.13); OWNER-NEXT-STEPS step 8b |
| One file to send back after a test | menu bar > "Export diagnostics..." (tick "Run self-test first" when something misbehaved), Export. You get `diagnostics-<yyyy-MM-dd-HH-mm>.zip` in Documents > Daylight Camera, revealed in Finder. `docs/FEEDBACK.md` lists what is inside and what is removed (IP addresses cut to their last number, Wi-Fi names, tokens, paths outside Daylight's folders) | 1.16; "Where the results go" at the end of the checklist |
| Tablet facts go to the Mac instead of being copied by hand | web page: "?" > "This tablet" > "Send facts to Mac". Daylight Ink: Settings > "This tablet" > "Send facts to Mac". The tablet answers "Sent to your Mac." | 2.7, 2.19, 3.7, 3.16, 4b.14, 4b.15 |
| The perf log says where its lines go | Settings > Advanced > "Perf log (one line per second, kept for Diagnostics and the export)" | 1.15, 6.11 |

## The two steps that are still yours

1. Add the four file secrets. The repository already holds `DAYLIGHT_TEAM_ID`, `DAYLIGHT_DEVELOPER_ID_P12_PASSWORD`, `ASC_API_KEY_ID` and `ASC_API_ISSUER_ID`. Still missing: `DAYLIGHT_DEVELOPER_ID_P12_BASE64`, `DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64`, `DAYLIGHT_EXT_PROVISIONING_PROFILE_BASE64` and `ASC_API_PRIVATE_KEY_BASE64`. Each is a file turned into base64; `docs/SIGNING.md` "Owner checklist" shows how, then run `gh workflow run whiteboard-camera.yml --ref claude/daylight-whiteboard-camera-tzxfjb -f notarize=true` and download `Daylight-dmg`. Until then every CI run prints a warning in the mac job's signing step and uploads only `Daylight-unsigned`.
2. Run the device checklist: `docs/TESTING-CHECKLIST.md`, one session at a time (Sessions 1 to 4b and 6 work on the unsigned build; Session 5 needs the signed one). Tap "Send facts to Mac" where a row says so, finish with menu bar > "Export diagnostics...", and send the zip back with one sentence per surprise.
