# Daylight Whiteboard Camera

A macOS menu-bar app, "Daylight", that publishes a virtual camera called "Daylight Camera". In a call it shows your webcam untouched; the moment you touch the pen to your Daylight DC-1 the picture slides into Studio Split: your whiteboard on the left two thirds, you on the right third. Lift the pen for 90 seconds and it slides back. Three ink sources are built so they can be compared: the web whiteboard the Mac serves, the native "Daylight Ink" Android app, and a mirror of the tablet screen.

Binding documents: `SPEC.md` (behaviour), `docs/ARCHITECTURE.md` (how), `docs/PROTOCOL.md` (bytes), `docs/LOOSE_ENDS.md` (open items).

## Status

Milestone M0, skeleton. Everything compiles and the protocol codecs pass the shared golden vectors on all three platforms; the camera extension publishes a solid cream 1920x1080 frame at 30 fps; the menu-bar app has a menu and a preview placeholder; the web page draws pen strokes locally; the Android app shows a pen-only placeholder canvas. Nothing ships to a user yet. See `docs/ARCHITECTURE.md` section 12 for the milestone plan.

## Layout

| Path | What |
|---|---|
| `mac/project.yml` | XcodeGen spec: app `com.twelve.daylight` + camera extension `com.twelve.daylight.camera` |
| `mac/Daylight/` | the menu-bar app (AppKit status item, preview placeholder) |
| `mac/DaylightCameraExtension/` | the CMIOExtension system extension (provider, device, source and sink streams, cream placeholder) |
| `mac/DaylightKit/` | Foundation-only Swift package: protocol codec, spring, layout, canvas model, HTTP and WebSocket framing, mirror parsers; tests run on Linux and macOS |
| `web/` | Vite + TypeScript whiteboard page, Node golden tests, Playwright smoke test |
| `android/` | "Daylight Ink" Gradle project (AGP 8.13.2, Kotlin 2.3.10, Gradle 8.14.5), JVM golden test |
| `protocol/` | `gen_golden.py` (the Python struct oracle) and the canonical golden vectors |
| `scripts/`, `Makefile` | every CI step is a make target |

## How it builds

There is no Mac or Android SDK on the development machine; GitHub Actions is the compiler. Every push runs:

| Job | Runner | Does |
|---|---|---|
| `golden` | ubuntu | regenerates the golden vectors and fails on drift between the four copies |
| `web` | ubuntu | `make web` (npm ci, typecheck, vite build) and `make web-test` (node tests, Playwright with Chromium) |
| `android` | ubuntu | `make android` (`./gradlew testDebugUnitTest assembleDebug`), uploads the debug APK |
| `kit-linux` | ubuntu, `swift:6.4-noble` container | `make kit-test` (`swift test` for DaylightKit) |
| `mac` | macos-15 | `make web`, `make mac-generate` (XcodeGen), `make kit-test`, `make mac-debug` (unsigned build, uploads `Daylight-unsigned.zip`), then `make mac-release`, which signs and notarizes only when the signing secrets exist and otherwise prints what is missing |

Locally, `make help` lists the targets and `make doctor` says which of them can run on this machine. `make web web-test` and `make golden-check` work anywhere with Node and Python 3; `make kit-test` needs a Swift toolchain; `make android` needs an Android SDK; the `mac-*` targets need Xcode and XcodeGen.

An unsigned build can show the menu bar item and the preview window, but macOS loads a camera extension only when it is signed with a Developer ID and notarized. The owner checklist for that lives in `docs/SIGNING.md` (to be written in M1) and `docs/LOOSE_ENDS.md` item A1.

## Writing rules

No em-dashes. LivePaper is a transflective LCD. The backlight is DC dimming.
