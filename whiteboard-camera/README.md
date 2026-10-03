# Daylight Whiteboard Camera

A macOS menu-bar app, "Daylight", that publishes a virtual camera called "Daylight Camera". In a call it shows your webcam untouched; the moment you touch the pen to your Daylight DC-1 the picture slides into Studio Split: your whiteboard on the left two thirds, you on the right third. Lift the pen for 90 seconds and it slides back. Pin it to keep it, Clear to save and return.

## Status

Every component is built, wired and green in CI (`docs/STATUS.md`): the DaylightKit Swift package (233 tests on Linux and macOS), the Daylight app (161 hosted tests plus a `--self-test` smoke run on every push), the camera extension, the web whiteboard (53 Playwright and 23 Node tests), the Daylight Ink Android app (72 JVM tests) and mirror mode. Nothing has run on the owner's hardware yet: the virtual camera appears in a call only on a Developer ID signed and notarized build (`docs/SIGNING.md`), and the tablet facts in `docs/LOOSE_ENDS.md` section D wait for the DC-1. A review round of 60 findings has been folded in (`docs/STATUS.md` section 7).

## The three ink sources

| Source | Tablet side | What crosses the wire | Try it |
|---|---|---|---|
| Web whiteboard | Chrome on the DC-1 opens a page the Mac serves at `http://<mac>:7788`; nothing to install | pen strokes, a few bytes per sample | first: zero install |
| Daylight Ink | a small Android app: native pen input, front-buffer wet ink, self-reconnecting over Bonjour, floating Pin and Clear pills | pen strokes | second: one click over USB installs it; the recommended daily default |
| Mirror | the tablet's own screen (any app, for example the SolOS note app) mirrored over USB debugging with the bundled adb and scrcpy-server | H.264 video of the screen plus the pen's input events | third: needs USB debugging; the only way to put another app on camera |

`docs/COMPARE.md` compares them honestly and says how to measure.

## Start here

1. `docs/OWNER-NEXT-STEPS.md`: the single page for the owner, step 0 to the first call, with the ADHD-friendly checklist at the end.
2. `docs/SETUP.md`: install and configure the Mac and the tablet for each source, networking, every setting in plain words, logs, uninstall.
3. `docs/SIGNING.md`: the Apple-side procedure without Xcode, the eight GitHub secrets, what success and every failure look like.
4. `docs/COMPARE.md`: strokes versus video, the recommendation per use case, the measurement plan.
5. `docs/TESTING-CHECKLIST.md`: the device run in five sessions, each row with the cue or log line that confirms it and the LOOSE_ENDS row the result goes to.
6. `docs/PERFORMANCE.md`: what the self-test and the perf log measure, the budgets, the runner numbers, the owner's blanks.
7. `docs/ARCHITECTURE.md` (section 18 first), `SPEC.md`, `docs/PROTOCOL.md`: the binding documents for anyone changing code. `docs/LOOSE_ENDS.md` holds every open item; `docs/handoff/` each component's own report.

## Layout

| Path | What |
|---|---|
| `mac/project.yml` | XcodeGen spec: app `com.twelve.daylight` + camera extension `com.twelve.daylight.camera` |
| `mac/Daylight/` | the menu-bar app: `Sources/{App,Onboarding,Settings,Pipeline,Camera,Ink,Server,Mirror,Contracts}` |
| `mac/DaylightCameraExtension/` | the CMIOExtension system extension (provider, device, source and sink streams, 90 Hz sink consumer, viewers property, cream placeholder) |
| `mac/DaylightKit/` | Foundation-only Swift package: protocol codec, governor, spring, layout, canvas model, settings, failure text, HTTP and WebSocket framing, mirror parsers; tests run on Linux and macOS |
| `web/` | Vite + TypeScript whiteboard page, Node unit tests, Playwright suite against a Node fake Mac |
| `android/` | "Daylight Ink" Gradle project (AGP 8.13.2, Kotlin 2.3.10, Gradle 8.14.5): canvas, chip, discovery, overlay pills, JVM tests |
| `protocol/` | `gen_golden.py` (the Python struct oracle) and the canonical golden vectors |
| `scripts/`, `Makefile` | every CI step is a make target (`make help`, `make doctor`) |
| `docs/` | the documents above |

## How it builds

There is no Mac or Android SDK on the development machine; GitHub Actions is the compiler (`.github/workflows/whiteboard-camera.yml` at the monorepo root, its standalone twin in `whiteboard-camera/.github/workflows/ci.yml`). Every push runs five jobs: `golden` (the protocol vectors never drift between the four copies; the script gates), `web` (`make web`, `make web-test`), `android` (`make android`, uploads the debug APK), `kit-linux` (`swift test` in a `swift:6.4-noble` container) and `mac` (macos-15: fetch the pinned adb and scrcpy-server, embed the APK and the web build, generate the project, build unsigned, run the hosted tests and the self-test, upload `Daylight-unsigned.zip`, then `make mac-release`, which signs, exports, notarizes and staples only when the eight secrets exist). A `v*` tag or a `workflow_dispatch` with `notarize` ticked produces `Daylight.dmg`.

## License

To be chosen by the owner (`docs/LOOSE_ENDS.md` A14); until then this repository carries no `LICENSE` file. Third-party components bundled by the Mac app are listed in `THIRD_PARTY_NOTICES.md`.

## Writing rules

No em-dashes. LivePaper is a transflective LCD. The backlight is DC dimming. VRR is 45 to 90 Hz.
