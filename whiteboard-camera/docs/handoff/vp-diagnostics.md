# VP Diagnostics: the diagnostics export and tablet facts (phase 3, 2026-10-03)

Ticket: one click produces one file the owner sends back after the device test. Owner guide: `docs/FEEDBACK.md`. Contract: PROTOCOL 15. Failure rows: SPEC 13.3 rows 44 to 47.

## 1. Owner-facing text

- Mac menu bar > "Export diagnostics..." opens an alert with the checkbox "Run self-test first" (off by default), Export and Cancel. Rows 44 ("Saving diagnostics: <step>..."), 45 ("Diagnostics saved as <file> in Documents > Daylight Camera. Send this file back after the test."), 46 ("The diagnostics file was saved without <part>: <reason>.", once per missing command part: the unified log, the extension status, the self-test), 47 ("Could not save the diagnostics file: <reason>. Use Diagnostics > Copy diagnostics instead."). Finder reveals the zip.
- Web page "?" card > "This tablet" > "Send facts to Mac"; Daylight Ink Settings > "This tablet" > "Send facts to Mac". Results, identical on both: "Sent to your Mac.", "Your Mac did not accept the facts (<code>). Update Daylight on your Mac." (404, 405), "Could not reach your Mac. Check the connection and tap again." (network error, 5 s timeout), "Your Mac refused the facts (<code>)." (other). Daylight Ink adds "Connect to your Mac first." (no Mac known, nothing sent) and "Sending to your Mac." while in flight.
- TESTING-CHECKLIST: every paste step is now "tap Send facts to Mac, then Export diagnostics once at the end"; row ids kept in the "Answers" column; 1.16 is the export step.

## 2. What was built (and where)

| Part | Files | Commit |
|---|---|---|
| FailureText rows 44 to 47, SPEC 13.3 | `DaylightKit/.../FailureText.swift`, tests, `SPEC.md` | c7c4d14 |
| PROTOCOL 15 (tablet facts over HTTP) | `docs/PROTOCOL.md` | 21a570f |
| Store-only zip (CRC-32 writer and reader), `Redactor`, bounded `CommandRunning`, `DiagnosticsExporter` | `mac/Daylight/Sources/App/Export/{ZipArchive,Redactor,CommandRunner,TabletFactsStore,DiagnosticsExporter}.swift` | ba97839, 21edaa0, c32357b |
| `POST /api/facts` with a bounded body read (16384 bytes, 10 s), validation as a pure `ApiRoutes` function | `Server/ApiRoutes.swift`, `Server/WebServer.swift` | 82d819e |
| Menu item, alert, wiring, self-test probe, Diagnostics `tablet facts:` line | `App/DiagnosticsExport.swift`, `MenuBar.swift`, 4 lines in `AppDelegate.swift`, `SelfTest.swift`, `Diagnostics.swift` | f40f448 |
| Web button, pressure tracker, fake Mac route | `web/src/facts.ts`, `web/src/main.ts`, `web/tests/{fake-mac.mjs,facts.spec.ts,unit/facts.test.ts}` | cfe43d3 |
| Daylight Ink button | `android/.../ui/SettingsFacts.kt`, 4 lines in `ui/SettingsActivity.kt`, `SettingsFactsTest.kt` | e6ceee2, 5e0ff52 |
| Owner guide and checklist | `docs/FEEDBACK.md`, `docs/TESTING-CHECKLIST.md` | 67ed8fa |

Decisions recorded:
- The zip always goes to `~/Documents/Daylight Camera` (the sessions default, `SessionSaver.defaultRoot()`), even when the owner moved the save folder, because row 45 names that place; the chosen save folder's paths stay readable in the export.
- The self-test runs as a child process (`Daylight --self-test`, 120 s, 1 MiB output) so a hang or crash cannot take the running app down and no second pipeline, listener or Metal device is built inside it.
- `Telemetry` writes no perf file; `perf-log.txt` holds the in-memory `perf` lines (the last 200) and is listed as missing when the perf log is off.
- The facts store is memory only (`TabletFactsStore.shared`, serial queue `com.twelve.daylight.facts`), 16 senders, oldest evicted.
- A rejected facts POST whose body is at most 16384 bytes is read and dropped before the answer, so the tablet sees the status instead of a reset.
- Cross-site safety: `Content-Type` must be `application/json` (a cross-site page cannot send that without a preflight, and the listener never answers OPTIONS) and an `Origin` header, when present, must name the listener.

## 3. Device facts and CI facts

- Run 37160970105 on c32357b: golden, web, android, kit-linux, mac (`make mac-debug`, `make mac-test` all passed, `make mac-smoke` self-test PASS, the signing step warned and passed) and mac-26 all green. The smoke probe wrote 9 files in 1.4 s on the runner: `log show` and `systemextensionsctl list` both answer on macos-15 and macos-26 runners; `/usr/bin/unzip -t` and `ditto -x -k` accept the archive.
- Xcode 16.4 gave up type-checking one DOS date packing expression in `ZipArchive.swift` (run 37160376039, `make mac-debug` red); split into statements in 21edaa0. Add to ARCHITECTURE 18's toolchain list: keep bit packing and ternaries inside string interpolations as separate statements.
- Android: `JSONObject.keySet()` is absent from the android.jar stub on the unit-test classpath; use `keys()` (run 37158623614 red, fixed in 5e0ff52).
- Web: run 37158623614, the web job ran 36 Node unit tests and 60 Playwright specs (2 new) green.

## 4. UNVERIFIED items

- `sysctlbyname("hw.model")` for `Mac model:` in `system.txt`; falls back to "unknown". The owner confirms by reading `system.txt` in the first export.
- None of the "Send facts to Mac" paths has run on the DC-1 against a real Mac; the first device session (TESTING-CHECKLIST 2.7, 3.7) confirms it. LOOSE_ENDS K1.

## 5. Requests for the integrator and other VPs

1. DaylightKit `HTTPRequest.statusText`: add 411 "Length Required" and 415 "Unsupported Media Type" (they go out as `411 Unknown`, `415 Unknown` today; clients read the code correctly). LOOSE_ENDS K2.
2. Settings > Perf log toggle text says "(one line per second in the unified log)" but `Telemetry.emit` prints to stdout and the in-memory ring only: log perf lines through `Logger` (then the export's `unified-log.txt` carries them) or reword the toggle. LOOSE_ENDS K3.
3. Hardening VP (android `InkConnection`): expose or persist a "last reached Mac URL" (set on PENDING or LIVE); `SettingsFacts` keeps it in process memory only, so after a restart of Daylight Ink with no connection it falls back to the typed host. LOOSE_ENDS K4.
4. Optional: move the Daylight Ink facts strings from `SettingsFacts` constants into `ui/Texts.kt` (its owner).
5. Optional: PROTOCOL 15.1 web keys carry `macBuild` only; a `macVersion` key would need a contract change (not needed; the Mac's own `system.txt` has it).

## 6. Red CI runs caused by someone else's files

- 37159335185: kit-linux red in `OverlaySettingsTests.testMissingKeysKeepDefaults` (Presenter Overlay VP); the mac job was skipped.

## 7. Process note

The managers' commits (cfe43d3, e6ceee2, 5e0ff52, ba97839, 82d819e, f40f448, 21edaa0, c32357b) carry the attribution trailers their own harness supplied instead of the charter's pair; published history is not rewritten. The VP's own commits use the charter's trailers.
