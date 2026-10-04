# Sending results back after a device test

One file carries everything the engineers need from a test day: the diagnostics zip. You never paste lines into the docs.

## 1. During the test

- On a step marked 📋 in `docs/TESTING-CHECKLIST.md` that names the tablet, tap "Send facts to Mac":
  - web page: tap "?" (the chip's card), then "Send facts to Mac" under "This tablet";
  - Daylight Ink: Settings > "This tablet" > "Send facts to Mac".
  The tablet answers "Sent to your Mac." The Mac keeps the latest facts from each tablet until it quits, so tap again after anything that changes them (a first pen stroke, a side-button press, a Home screen launch, a Wi-Fi mirror session) and before quitting Daylight.
- If the tablet says "Your Mac did not accept the facts (404). Update Daylight on your Mac.", the Mac runs an older build; install the newest one.
- If it says "Could not reach your Mac. Check the connection and tap again.", the tablet is not connected; get the chip to LIVE (or Daylight Ink's chip to connected) and tap again.

## 2. At the end of the day

1. Mac menu bar > Daylight > "Export diagnostics...".
2. Tick "Run self-test first" if the checklist asks for it or something misbehaved (adds up to two minutes).
3. Export. The menu shows "Saving diagnostics: <step>..." (row 44), then "Diagnostics saved as diagnostics-<yyyy-MM-dd-HH-mm>.zip in Documents > Daylight Camera. Send this file back after the test." (row 45), and Finder opens with the zip selected.
4. Send the zip. Attach it to the message or the issue as it is. If attachments are not possible, paste `MANIFEST.txt` and the files the engineers ask for (they are plain text; the zip opens with a double click).

"The diagnostics file was saved without <part>: <reason>." (row 46) means one part could not be collected in time; the rest is complete and `MANIFEST.txt` says what is missing. "Could not save the diagnostics file: <reason>. Use Diagnostics > Copy diagnostics instead." (row 47) means nothing was written: free some disk space and try again, or paste the Diagnostics window's text.

## 3. What is inside the zip

| File | What it holds | Bounded to |
|---|---|---|
| `MANIFEST.txt` | every file as `- <name> (<n> bytes): <note>`, then a `missing:` section and a `truncated:` section (each reads `- none` when empty) | 64 KiB |
| `diagnostics.txt` | the Diagnostics window's full text (every key: capture, pipeline, governor, listener, clients, `mirror.*`, failures, the last log lines) plus one `tablet facts: <key> received <time> (<n> facts)` line per sender | 1 MiB |
| `system.txt` | `macOS:`, `Mac model:`, `DaylightBuildSigned:`, `CFBundleShortVersionString:` (version), `CFBundleVersion:` (the CI run number), `bundle:`, `in /Applications:`, processors, memory, time zone | 64 KiB |
| `settings.json` | Daylight's Settings as saved; the save folder path (`saveDirectory`) is kept | 256 KiB |
| `unified-log.txt` | `log show --predicate 'subsystem == "com.twelve.daylight"' --last 2h --style compact`, last 2000 lines (newest kept) | 2000 lines, 4 MiB |
| `extension-status.txt` | `systemextensionsctl list` (10 s limit) | 256 KiB |
| `self-test.txt` | the output of `Daylight --self-test`, run as a separate process (120 s limit), only when "Run self-test first" was ticked | 1 MiB |
| `perf-log.txt` | the `perf` lines Daylight keeps in memory (the last 200), present when the perf log is on (Settings, or launched with `--perf-log`) | 512 KiB |
| `vendor.txt` | the adb in use: `adb.source`, `adb.path`, `adb.version`, the Vendor folder's files with sizes and sha256, the bundled adb's version | 64 KiB |
| `clients.json` | the allowed tablets, IP addresses reduced to their last number, client ids to their first 8 characters | 256 KiB |
| `tablet-facts.json` | the latest "Send facts to Mac" from each tablet (web page and Daylight Ink), PROTOCOL 15, as `{"schema":"daylight-tablet-facts-export/1","entries":[{key, source, clientId, sentAt, receivedAt, remoteAddress, allowed, facts}]}` | 16 senders, 1 MiB |

What is never inside: Wi-Fi network names, tokens or keys, full IP addresses, and file paths outside Daylight's own folders (your home folder shows as `~`, except in `settings.json`, where the save folder stays as you chose it). Logs that hit their cap keep their newest part, other files their beginning, and MANIFEST says so. The whole zip stays under 16 MiB; it is a plain (uncompressed) zip that Finder, `unzip` and `ditto` open.

## 4. Which file answers which LOOSE_ENDS section D row

| Row | Fact | File and key |
|---|---|---|
| D1 | Wacom evdev node, ranges, side buttons | `diagnostics.txt` `mirror.pen.node`, `mirror.pen.status`; `unified-log.txt` lines `getevent -pl devices:` and `pen node /dev/input/event` (needs a USB mirror session) |
| D2 | model, Android release, display size and density | `tablet-facts.json` source `ink`: `model`, `release`, `sdk`, `display`, `density`, `densityDpi` |
| D3 | pressure range in Android and in Chrome | `tablet-facts.json`: `ink` `pressureRange`; `web` `pressureMin`, `pressureMax`, `pressureSamples`, `firstPenPointerdown` |
| D4 | which button the side button is | `tablet-facts.json`: `ink` `sideButton`; `web` `firstPenPointerdown` (`button=`, `buttons=`, `pressure=`) |
| D5 | where the overlay pills sit in the mirror | not in the export: an eye test (TESTING-CHECKLIST, Session 4); one sentence in your note |
| D6 | adb authorization timeout on SolOS | not in the export: Developer options; one sentence in your note |
| D7 | stay-awake setting | not in the export (only if A13 is approved) |
| D8 | Chrome version, DPR, viewport, display mode | `tablet-facts.json` source `web`: `chromeVersion`, `userAgent`, `devicePixelRatio`, `viewport`, `displayMode`, `secureContext`, `wakeLockState`, `fullscreenState`; the `.local` try is a sentence in your note |
| D9 | palm rejection and pen cancels | not in the export: what you saw while drawing; one sentence in your note |
| D10 | which app opens `http://` | `unified-log.txt`: the USB "Open on the tablet" `am start` lines |
| D11 | Tethering module extension version | `tablet-facts.json` source `ink`: `tiramisuExt` |
| D12 | getevent latency, getevent exit | `unified-log.txt` (the `-t` stamps against arrival time); `adb shell ps` stays manual |
| D13 | B-frames or reordered PTS | `diagnostics.txt` `mirror.decoder.outOfOrder`; `unified-log.txt` |
| D14 | front-buffer rendering | `tablet-facts.json` source `ink`: `frontBuffer` |
| D15 | overlay permission after USB setup | `tablet-facts.json` source `ink`: `canDrawOverlays` |
| D16 | Activity Monitor numbers, engage latency | `perf-log.txt`, `diagnostics.txt` `pipeline:` and `governor:` lines; Activity Monitor numbers stay a note |
| D17 | OkHttp subprotocol echo | `diagnostics.txt` `clients:` (an "incompatible" Daylight Ink never shows LIVE); the chip text is a note |
| D18 | cleartext `ws://` on SolOS | `diagnostics.txt` `clients:` shows Daylight Ink connected over Wi-Fi |
| D19 | Wi-Fi mirror consent wording, lifetime | `unified-log.txt` `mirror` lines (consent denied is row 34); the prompt's wording is a sentence in your note |
| D20 | frame-differencing engage | `diagnostics.txt` `mirror.wifi.engageSource` and the `mirror.wifi.*` lines; false starts are a note |
| D21 | the tablet's H.264 encoder | `tablet-facts.json` source `ink`: `mirrorEncoders`, `mirrorEncoder`, `mirrorStream`; `diagnostics.txt` `mirror.wifi.fps`, `mirror.wifi.bitrate`, `mirror.wifi.decodeLatencyMs` |
| D22 | START reaching a closed Daylight Ink | `unified-log.txt` (row 38 `mirror stream: no capable Daylight Ink connection` when nothing held the socket) |
| D23 | battery and heat while streaming | `tablet-facts.json` source `ink`: `mirrorThermalMax`; the battery percentage is a note |

## 5. Overlay mode (optional, TESTING-CHECKLIST Session 6)

Overlay is off by default (Settings > Overlay > "Enable overlay mode"). When you try it, export right after the run, because the perf lines are a ring of the last 200.

| Row | Fact | File and key |
|---|---|---|
| E29 | the person mask reaches Metal without a copy | `unified-log.txt` and `diagnostics.txt`: no line `overlay: mask <w>x<h> is not Metal-compatible; copied once per frame` (that line means the copy fallback ran) |
| E30 | segmentation time per quality | `perf-log.txt`: the `perf overlay seg_ms=... mask_age_ms=... seg_dropped=... state=...` lines (one per second while Overlay is enabled and Daylight runs with the perf log on) |
| E31 | matte quality in your room | `unified-log.txt` `overlay:` lines (`overlay: mask coverage <fraction> below 0.01; showing the camera rectangle` is row 49, `overlay: segmentation failed <n> frames in a row: <error>` is row 48); how it looked is a sentence in your note |

## 6. The share window and the Zoom second-camera check (optional, TESTING-CHECKLIST Session 7)

The share window (menu bar > "Share the whiteboard" > "Show share window", Settings > Share) leaves its own lines in the log, so export after the session as usual.

| Row | Fact | File and key |
|---|---|---|
| 7.1 | the window opened, its size and settings | `unified-log.txt` category `share`: `share window shown (<w>x<h> pt, floats=<true or false>, titleBar=<true or false>)`; the same line is in the Diagnostics tail |
| 7.3 to 7.6 (TS-1, TS-2) | whether Zoom lists the window, with and without the title bar; whether a covered window keeps sharing and a minimised one pauses | not in the export: what the second device showed; one sentence per row in your note |
| 7.7 (TS-3) | the Zoom second-camera check on the signed build | not in the export: write three answers in your note: (a) was "Daylight Camera" offered under Share Screen > Advanced > "Content from 2nd Camera" (or "Second camera"), (b) after how many "Switch Camera" clicks, (c) on the second device, was the picture sharp, the right way round (not mirrored) and full size. These three answers decide whether the next build adds a camera made only of the page |
| 7.8 (TS-6) | a "Share" choice on the window's green button with Zoom's "Use Mac System Picker" on | not in the export: yes or no in your note |
| 7.9 (TS-7) | Daylight's CPU with the share window open and closed | not in the export: the two Activity Monitor percentages in your note |
