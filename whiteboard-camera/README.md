# Daylight Whiteboard Camera

A macOS menu-bar app, "Daylight", that publishes a virtual camera called "Daylight Camera". In a call it shows your webcam untouched; the moment you touch the pen to your Daylight DC-1 the picture slides into Studio Split: your whiteboard on the left two thirds, you on the right third. Lift the pen for 90 seconds and it slides back. Three ink sources are built so they can be compared: the web whiteboard the Mac serves, the native "Daylight Ink" Android app, and a mirror of the tablet screen.

Binding documents: `SPEC.md` (behaviour), `docs/ARCHITECTURE.md` (how), `docs/PROTOCOL.md` (bytes), `docs/LOOSE_ENDS.md` (open items).

## Status

All six components of `docs/IMPLEMENTATION-PLAN.md` are merged and wired (Integrator-sync-4): `DaylightKit` (protocol codec, governor, spring, layout, canvas, settings, failure text, RFC 6455 framing, mirror parsers; 170 tests on Linux and macOS), the Daylight app core (webcam passthrough, Metal compositor, 30 Hz pipeline with the idle rule, web server, ink router, saving, onboarding, Allow panel, Settings, Diagnostics, hotkeys, `--self-test`), the camera extension and its host-side sink client, the web whiteboard (pen-only ink, chip, offline ring; 46 Playwright tests), the Daylight Ink Android app with the overlay pills (70 JVM tests), and mirror mode (adb policy, scrcpy 4.1 session, VideoToolbox decode, getevent stylus watcher). `make mac-test` runs 118 hosted tests and `make mac-smoke` runs the self-test on every push. Nothing has run on the owner's hardware yet: the virtual camera appears in Zoom only on a Developer ID signed and notarized build (`docs/LOOSE_ENDS.md` A1), and every tablet fact in LOOSE_ENDS section D needs the DC-1. `docs/STATUS.md` has the per-component account, the UNVERIFIED list with fallbacks, the owner's next steps and the exact CI commands; `docs/handoff/` has each component's own report.

## Layout

| Path | What |
|---|---|
| `mac/project.yml` | XcodeGen spec: app `com.twelve.daylight` + camera extension `com.twelve.daylight.camera` |
| `mac/Daylight/` | the menu-bar app: `Sources/{App,Onboarding,Settings,Pipeline,Camera,Ink,Server,Mirror,Contracts}` |
| `mac/DaylightCameraExtension/` | the CMIOExtension system extension (provider, device, source and sink streams, 90 Hz sink consumer, viewers property, cream placeholder) |
| `mac/DaylightKit/` | Foundation-only Swift package: protocol codec, spring, layout, canvas model, HTTP and WebSocket framing, mirror parsers; tests run on Linux and macOS |
| `web/` | Vite + TypeScript whiteboard page, Node unit tests, Playwright suite against a Node fake Mac |
| `android/` | "Daylight Ink" Gradle project (AGP 8.13.2, Kotlin 2.3.10, Gradle 8.14.5): canvas, chip, discovery, overlay pills, JVM tests |
| `protocol/` | `gen_golden.py` (the Python struct oracle) and the canonical golden vectors |
| `scripts/`, `Makefile` | every CI step is a make target |
| `docs/` | `ARCHITECTURE.md`, `PROTOCOL.md`, `IMPLEMENTATION-PLAN.md`, `LOOSE_ENDS.md`, `STATUS.md`, `handoff/` |

## How it builds

There is no Mac or Android SDK on the development machine; GitHub Actions is the compiler. Every push runs:

| Job | Runner | Does |
|---|---|---|
| `golden` | ubuntu | regenerates the golden vectors and fails on drift between the four copies |
| `web` | ubuntu | `make web` (npm ci, typecheck, vite build) and `make web-test` (node tests, Playwright with Chromium) |
| `android` | ubuntu | `make android` (`./gradlew testDebugUnitTest assembleDebug`), uploads the debug APK |
| `kit-linux` | ubuntu, `swift:6.4-noble` container | `make kit-test` (`swift test` for DaylightKit) |
| `mac` | macos-15 (needs the four jobs above) | downloads the debug APK, `make fetch-tools` (pinned adb and scrcpy-server into `Resources/Vendor`), `make embed-apk` (into `Resources/Apk`, served as `/daylight-ink.apk`), `make web`, `make mac-generate` (XcodeGen), `make kit-test`, `make mac-debug` (unsigned build, uploads `Daylight-unsigned.zip`), `make mac-test` (the macOS-only `DaylightTests` bundle hosted by Daylight.app), `make mac-smoke` (`Daylight --self-test --perf-log` from the Release build under a 120 s timeout), then `make mac-release`, which signs and notarizes only when the signing secrets exist and otherwise prints what is missing |

A `v*` tag push runs the same workflow with the notarization path armed (it still needs the secrets). Locally, `make help` lists the targets and `make doctor` says which of them can run on this machine. `make web web-test` and `make golden-check` work anywhere with Node and Python 3; `make kit-test` needs a Swift toolchain; `make android` needs an Android SDK; the `mac-*` targets need Xcode and XcodeGen.

An unsigned build can show the menu bar item and the preview window, but macOS loads a camera extension only when it is signed with a Developer ID and notarized. The owner checklist for that lives in `docs/LOOSE_ENDS.md` item A1 and `docs/handoff/c-camera-extension-and-host-sink-client.md` section 7 (folded into `docs/SIGNING.md` at M6).

## License

License: to be chosen by the owner (`docs/LOOSE_ENDS.md` A14). Until then this repository carries no `LICENSE` file. Third-party components bundled by the Mac app are listed in `THIRD_PARTY_NOTICES.md`.

## Writing rules

No em-dashes. LivePaper is a transflective LCD. The backlight is DC dimming.
