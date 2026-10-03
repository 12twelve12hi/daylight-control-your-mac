# Handoff: component A, DaylightKit

Owner of this file: the DaylightKit agent. Paths owned: `mac/DaylightKit/Sources/DaylightKit/{Protocol,Governor,Spring,Layout,Canvas,HTTP,Settings,Session,Util}/`, the matching test folders under `mac/DaylightKit/Tests/DaylightKitTests/`, `protocol/gen_golden.py`, `protocol/golden/`, and this file. Proven by the `kit-linux` job (Swift 6.4 in the `swift:6.4-noble` container, language mode 5) and the `make kit-test` step of the `mac` job (Xcode 16.4).

Writing rules apply: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming; VRR is 45 to 90 Hz.

---

## 1. What was built

The kit imports Foundation only (`grep -rn "^import" mac/DaylightKit/Sources` shows nothing else; Dispatch is used through Foundation's re-export in `Locked` tests only). Nothing in it logs, allocates a thread or knows about Apple frameworks. Every number in SPEC sections 5, 6, 11, 12 and 13.3 has a test before the code that uses it.

### 1.1 The section 3.5 fixes (first commits, so B, C and F compile against the frozen surface)

| File | What changed |
|---|---|
| `Settings/Settings.swift` | Every SPEC 11 key with the plan 3.3 property names and types; `HotkeyAction`, `HotkeyBinding`, `MirrorPinClearMode`, `PillsPosition`, `AdbServerMode`; `Settings.defaults`; `validated()` clamps 15...600, 0...30, 300...2400, 10...600, 15...600, `preWarningSeconds <= idleTimeoutSeconds - 1`, a port under 1024 becomes 7788, missing hotkeys come back as defaults. `holdMode` is omitted from `CodingKeys`. Decoding tolerates missing and unknown keys (every absent key keeps its default) so an older blob loads after an upgrade. `mirrorPillsEnabled` and `layout` are gone. |
| `Settings/FailureText.swift` | 35 cases in SPEC 13.3 row order with the plan 3.4 names; `sentence(_:_:)` is the "Owner sees (exact)" column, `logLine(_:_:)` the "Log line" column, both with in-order `<...>` substitution; `Case.row` gives the row label; `followUp(.sinkDeviceNotFound)` is the "after 30 s" sentence of row 13; row 12 defaults its one argument to `approvalPathModern` (`approvalPathLegacy` is the 13 and 14 wording). Row 16 has two shapes: two arguments give "Port 7788 is in use. Daylight is using 7789.", one argument gives the "Quit the other app..." form. Row 17 (nothing visible) returns an empty sentence and a real log line. |
| `Layout/StudioLayout.swift` | `frame(progress:layout:orientation:canvasAspect:breath:)` with every SPEC 6 rectangle; `amberBreath` mixes InkBlack toward Amber; `CanvasOrientation.aspect`, `.zoneWidth`, `init(width:height:)`; `passthrough()` divider colour is InkBlack at alpha 0. |
| `Session/SessionFiles.swift` | `<root>/Daylight Camera/<yyyy-MM-dd>/<HH-mm-ss>/`; `startsNewSession(lastInkAt:now:)` for the 10-minute gap; `uniqueURL` keeps working for names without an extension. |
| `Canvas/PageDocument.swift` | The SPEC 12 schema (`schema`, `app`, `canvas`, `session`, `page`, `strokes[]` with `[x, y, pressure, tMs]` point arrays); helpers `isoString`, `colorString`, `colorValue`, `toolName`, `tool(named:)`, `strokeValues()`. |
| `Canvas/StrokeStore.swift` | `start(_:scale:)`, `append`, `commit`, `commitAll`, `cancel`, `erase`, `undo`, `redo`, `clear`, `newPage`, `markSaved`, `document(...)`, `committedCount`, `hasInk`, `isDirty`, `pageAspect`, `stroke(id:)`. |
| `Canvas/Geometry.swift`, `Canvas/CatmullRom.swift` | New: point-to-segment and segment-to-segment distance, the eraser hit test; the Catmull-Rom to Bezier control points with the research note's formula, verified against the basis-matrix form. |
| `Protocol/Identity.swift` | Label at most 64 UTF-8 bytes (longer rejected), clientId non-empty and at most 64 bytes; `mayControl(_:)` for the PROTOCOL 8 role rule. |
| `HTTP/WebSocketFrame.swift` | Real RFC 6455 `parse`: 7, 16 and 64-bit lengths, mask required, reserved bits, control frames at most 125 bytes and never fragmented, `maxPayload` checked from the header before the payload arrives (`.oversize`); `encodeMasked` for test clients; `closeCode`; `WebSocketMessageAssembler` for fragment reassembly (`WebSocketError.badContinuation` added). |
| `HTTP/HTTPRequest.swift` | `statusText` for 403, 405, 413, 426 and a few more; `maxHeadLength` 16 KiB with `HTTPError.headTooLarge`; `isWebSocketUpgrade` also requires `Connection: upgrade`; `webSocketKey`, `webSocketVersion`; a `[UInt8]` overload of `parse`. |
| `Governor/Clock.swift` | `SystemClock.now()` is `ProcessInfo.processInfo.systemUptime` (monotonic); `ManualClock.set(_:)`. |
| `Governor/GovernorEvent.swift` | `InkSource`, `LayoutStyle`, `HoldMode` are `Codable`; `HoldMode.forcedLayout`; `InkSource.displayName` ("web", "Daylight Ink", "mirror") and `.jsonName`; `GovernorConfig(settings:)`. |
| `Governor/GovernorOutput.swift` | `GovernorOutput.stateReport(clientFlags:inkSource:pageIndex:strokeCount:undoDepth:redoDepth:)` builds the 20-byte STATE (pinned and pre-warning bits from the governor, the rest from the caller; counts saturate at 65535); `breathWeight(secondsSincePreWarning:)`. |
| `Governor/EngageGovernor.swift` | The full SPEC 5.2 table (section 1.2 below). |

### 1.2 EngageGovernor

A pure value. `handle(_:now:)` and `tick(now:)` return a `GovernorOutput` whose `effects` array is the only side channel; `snapshot` returns the same output with no effects. Time is the caller's monotonic seconds (B feeds `CACurrentMediaTime()` on the render path). The governor owns no timers: tick at 30 Hz while `needsTicks` (`state != .passthrough || hold != .auto`); `nextDeadline(now:)` serves the optional `deadlineIdle` flag.

Behaviour notes B must know:

- `stateChanged(from: .passthrough, to: .engaging)` is the signal to start the 30 Hz clock and render frame 0 synchronously; `stateChanged(to: .passthrough)` is the signal to stop it (unless a hold mode keeps `needsTicks` true).
- `savePage(reason:)` and `clearCanvas` are requests. The governor tracks "ink since the last save" and "ink since the last clear" heuristically from the events it sees (stylus contact, motion of a tracked stroke, activity, pen contact), so Clear on an untouched board emits nothing and a pinned board cleared twice saves once. SessionSaver still re-checks `StrokeStore.isDirty` before writing (an autosave the governor never saw may already have saved the page). `StrokeStore.isDirty` is false for a page with no strokes, so nothing empty is ever written.
- Eraser rule (D36): an eraser-tool stylus contact never engages from PASSTHROUGH unless `engageOnEraser`; its id is tracked so the lift clears it. In ENGAGING and LIVE it counts as activity; in RETURNING it re-engages (D36 says "cancels a return"), both as `.contact(... tool: .eraser)` and as `.eraserContact(down: true)`.
- `penContact(down: true)` engages with one sentinel id and freezes the idle timer until `penContact(down: false)`. It is honoured in every ink source (only F emits it, so no source check is needed inside the governor).
- `pin` from PASSTHROUGH engages even under `hold == .camera` (the table has no guard on that row); `engage` and `layoutHotkey` are blocked by `hold == .camera` as the table says. `autoEngage == false` tracks contacts but never engages from a contact or a pen contact.
- `msToReturn`: `idleTimeout - (now - lastActivity)` in milliseconds while LIVE and idle (hold auto, not pinned, no contact), 0 while RETURNING, `0xFFFFFFFF` otherwise. `breath` is `0.5 * (1 - cos(2 * pi * t / 2))` while the pre-warning is on, else 0.
- `generation` increments on every state change only (bookkeeping never bumps it), so B can use it as the stale-callback guard.
- Effects order: pin changes before state changes; for Clear: `savePage`, `clearCanvas`, then `stateChanged` when unpinned.

### 1.3 StrokeStore contract for the rasterizer

- `start` returns nil (nothing to draw); the first `append` returns `.drawSegments(strokeID:, fromIndex: 0)`. For `fromIndex > 0` the rasterizer strokes the segments from point `fromIndex - 1` to the end.
- Dot rule: a committed stroke with exactly one point returns `.drawSegments(strokeID:, fromIndex: 0)` from `commit`; the rasterizer fills a disc of diameter `Stroke.dotDiameter` at that point (CoreGraphics draws nothing for a zero-length line, and a round-capped zero-length path is UNVERIFIED on macOS, so the disc is explicit).
- `Stroke.bounds` is the point bounding box; `Stroke.dirtyBounds` inflates it by half the maximum width plus one pixel and is what `cancel`, `undo` and `erase` return in `.redraw`. `DirtyRect.clipped(toWidth:height:)` gives integer canvas pixels.
- Undo and redo are stroke based: `undoDepth` = committed strokes present, `redoDepth` = undone and redoable; a new commit discards the redo stack; `redo` returns `.drawSegments(fromIndex: 0)` (draw the whole stroke). Erase removes strokes for good (not undoable in v1; the clients redraw from STATE depths and their own erase hints, LOOSE_ENDS candidate).
- `erase`, `undo` and `redo` take an optional `now:` so the dirty stamp moves; pass it.
- `scale` is `(1200 / canvas_width, 1600 / canvas_height)` from the HANDSHAKE; points are scaled into our x32 units on append.
- `document(...)` writes `page.index` 1-based (like the file name `page-01`) and `baseWidth` rounded to three decimals (the wire carries a Float; 3.2 would otherwise print as 3.2000000476837158). Encode with `JSONEncoder` and `outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`: without the second option Foundation writes `"daylight-whiteboard-strokes\/1"` (valid JSON, ugly to read; CI run 37108706001 caught it).

### 1.4 Tests (acceptance A1 to A8)

| SPEC 16 | Test file(s) |
|---|---|
| A1 | every file; `kit-linux` and the mac `kit-test` step run the same sources |
| A2 | `Protocol/GoldenVectorTests.swift` (26 cases decode and re-encode), `Protocol/CodecLimitsTests.swift` (ACK 2 and 3, 24-byte STATE, limits, 26-byte start rejected, odd offsets) |
| A3 | `Governor/GovernorScenarioTests.swift` (31 methods, one per SPEC 5.4 sentence, several sentences get two), `Governor/GovernorTableTests.swift` (25 methods for the remaining rows), `Governor/GovernorHarness.swift` (manual clock at exactly `tickIndex / 30`) |
| A4 | `Spring/CriticalSpringTests.swift` (values at 0.100, 0.150, 0.200, 0.250, 0.333 within 1e-4; frames 0.321 ... 0.997; settle at tick 8 = 0.267 s, within one tick of 0.251; retarget continuity; Euler at 1/30 s diverges by step 3; 14.4 ms Euler stays bounded) |
| A5 | `Layout/LayoutTests.swift` (235, 810, 1045, 1279, 1280, 640, 555, 1365, 1440, 480, 240, UV 1/3..2/3, landscape 720..1200, clip-space values, s = 0 equals passthrough, mirror crop fit 810x1015.2) |
| A6 | `Canvas/StrokeStoreTests.swift`, `Canvas/GeometryTests.swift` |
| A7 | `HTTP/WebSocketFrameTests.swift` (0, 1, 125, 126, 127, 65535, 65536, 100000; split reads; fragmentation; control frames; oversize from the header; reserved bits; unmasked), `HTTP/HTTPRequestTests.swift` (split reads, lower-cased headers, traversal, accept key, `SHA1("abc")`) |
| A8 | `Settings/SettingsTests.swift`, `Settings/FailureTextTests.swift`, `Session/SessionFilesTests.swift`, `Util/UtilTests.swift` |

The snap-back scenario ("cancel at 60 ms with progress 0.11") is tested with `springK = 90` because the default spring is already at 0.61 after 60 ms; a second test pins the default spring (snap-back at 15 ms, none at one tick).

---

## 2. How to test on the real device (atomic steps, DaylightKit view)

The kit has no device-facing surface; these are the owner-visible behaviours that the governor and layout numbers produce, in the order they are easiest to check with Daylight Camera showing in the preview window or in FaceTime.

1. Touch the pen to the DC-1 and write one letter. Expect the picture to slide into Studio Split in about a quarter second with no pop at the start (frame 0 is the full webcam) and the whiteboard letterboxed in cream on the left two thirds.
2. Rest a palm, swipe a finger, hover the pen 5 mm above the glass, press the pen side button in the air. Expect nothing to engage.
3. Lift the pen and wait. At 85 s the divider starts breathing amber (one full breath every 2 s); at 90 s the picture slides back to the camera.
4. During the amber breathing, touch the pen once. Expect the breathing to stop and a fresh 90 s.
5. During the slide back, touch the pen. Expect the picture to turn around smoothly (no jump) and come back to the board.
6. Tap the chip (or press Ctrl+Opt+Cmd+K). Expect KEEP WHITEBOARD and no return for as long as you like; tap again and the return happens 90 s later.
7. Hold the pen on the glass without moving for two minutes. Expect no return (a pen on the glass freezes the timer).
8. Press Clear with the board unpinned. Expect a saved `page-01.png` and `page-01.json` under `~/Documents/Daylight Camera/<date>/<HH-mm-ss>/` and the picture back on the camera. Pin, draw, press Clear twice. Expect one new file pair, not two.
9. Open the `.json`: it starts with `"app"`, `"canvas"` and lists `"points"` as `[x, y, pressure, tMs]` arrays; `"page": {"index": 1}` matches `page-01`.
10. Press Ctrl+Opt+Cmd+W from the camera. Expect Whiteboard Only (paper centred, cream margins 555 px each side, no presenter). Press it again: back to the camera. Press Ctrl+Opt+Cmd+D while the board is up: Studio Split without a second slide.

---

## 3. Device facts and CI facts

- CI: actions run 37108531802 (kit-linux) compiled every new file on the first try with Swift 6.4 on x86_64 Linux; the only failures were four tolerance assertions comparing widths derived from a `Float` baseWidth at 1e-9 (fixed to 1e-6 in commit b59e898). The following run proves the kit on both platforms; its id is in the structured result of this component.
- `CodingKeyRepresentable` on `HotkeyAction` makes `Settings.hotkeys` encode as a JSON object keyed by action name (`{"whiteboardOnly": {"keyCode": 13, "modifiers": 6400}}`); it needs macOS 12.3 or later, fine for the 14.0 target, and works on Linux.
- `ProcessInfo.processInfo.systemUptime` exists in swift-corelibs-foundation; `UtilTests.testClocks` asserts monotonicity and that the value is an uptime, not an epoch.

---

## 4. UNVERIFIED items shipped behind a fallback

A is pure Swift, so there are no Apple API facts here. Judgement calls the owner or the integrator may want to flip (each is one line of code):

1. Eraser contact during RETURNING re-engages (D36 "cancels a return"); the literal table would leave it as bookkeeping. Fallback: none needed; flipping it means deleting two lines in `handleReturning`.
2. `pin(1)` from PASSTHROUGH engages even under `hold == .camera` (the table row has no guard). If the owner prefers the hold to win, add `guard hold != .camera` in `handlePassthrough`.
3. Clear and save effects are gated by the governor's own ink heuristic; the saver's `StrokeStore.isDirty` check is the second gate. Confirm on the Mac that a Clear on a board with ink always writes exactly one file pair.
4. The dot rule asks the rasterizer to fill a disc for one-point strokes; whether CoreGraphics also draws a round cap for a zero-length segment is unverified, so the disc is explicit.
5. The JSON `page.index` is 1-based to match `page-01`; the STATE `page_index` and `PAGE_CHANGE` stay 0-based. If the owner prefers 0-based in the file, change one `+ 1` in `StrokeStore.document`.

---

## 5. Requests for the integrator

1. None blocking. `Package.swift` needs no change (no new resources; fixtures are literals).
2. Optional golden additions (plan 4, step 8: `handshake_ack_denied`, `handshake_ack_unsupported`, a decode-only `state_extended_24`) were NOT added to `gen_golden.py`, to avoid turning `golden-check`, D's and E's case counts red on the same day. The same bytes are pinned by `CodecLimitsTests` instead (`da0102001000000040e2cfeeb540060080070000380400001e00000002000000` and `...03000000`). Add them to the oracle at M6 if the cross-client parity list (ARCHITECTURE 11.6) wants them; D and E then bump their counts from 26 to 29.
3. LOOSE_ENDS candidates: erase is not undoable in v1 (UNDO and REDO are stroke based per PROTOCOL 6.7); the web and native clients should mirror that rule.
4. The handoff README names this file `A-daylightkit.md`; the orchestrator's task text spelled it `a-daylightkit.md`. This is the only copy.

---

## 6. Text for the owner-facing documents

### SETUP.md (DaylightKit section, folded into the Mac section)

Nothing to set up: the kit is compiled into Daylight. The two numbers you may want to change live in Settings: the return delay (default 90 s, 15 to 600) and the amber warning (default 5 s before the return, 0 to 30). Advanced: `springK` 1200 is the quarter-second slide; 600 is a slower one that takes the whole third of a second.

### COMPARE.md (what the kit measures identically for all three ink sources)

The engage detector is the same value type for web, native and mirror: stylus contact with pressure above zero, never hover, never a finger. The slide, the 90 s return, the 85 s warning and the pin rules do not change between sources, so any difference you see in COMPARE is transport latency, not governor behaviour.

### TESTING-CHECKLIST.md rows (kit behaviours, about 6 minutes)

- 🟢 Pen touch engages, finger and palm do not (30 s)
- ⏱️ Amber breathing at 85 s, return at 90 s (2 min)
- ✍️ Pen during the return turns the slide around smoothly (20 s)
- 📋 Pin holds the board; unpin gives a fresh 90 s (2 min)
- 🟣 Clear saves once even when pressed twice on a pinned board (30 s)
- 🟡 `page-01.json` starts with `"app"` and has `[x, y, pressure, tMs]` points (30 s)

---

## 7. Red CI runs caused by someone else's files

None observed at the time of writing.

## 8. Public surface (generated from the sources, one line per public declaration)

`Protocol/ByteReader.swift`

```swift
public struct ByteReader
public init(_ bytes: UnsafeRawBufferPointer)
public var remaining: Int
public var position: Int
public mutating func u8() throws -> UInt8
public mutating func i8() throws -> Int8
public mutating func u16() throws -> UInt16
public mutating func u32() throws -> UInt32
public mutating func i32() throws -> Int32
public mutating func u64() throws -> UInt64
public mutating func f32() throws -> Float
public mutating func uuid() throws -> UUID
public mutating func bytes(_ n: Int) throws -> [UInt8]
```

`Protocol/ByteWriter.swift`

```swift
public struct ByteWriter
public private(set) var storage: [UInt8]
public init(reserving: Int = 64)
public var count: Int
public mutating func u8(_ v: UInt8)
public mutating func i8(_ v: Int8)
public mutating func u16(_ v: UInt16)
public mutating func u32(_ v: UInt32)
public mutating func i32(_ v: Int32)
public mutating func u64(_ v: UInt64)
public mutating func f32(_ v: Float)
public mutating func uuid(_ v: UUID)
public mutating func bytes(_ v: [UInt8])
public mutating func patchU32(_ v: UInt32, at index: Int)
```

`Protocol/Codec.swift`

```swift
public enum CodecError: Error, Equatable
public enum Codec
public static func encode(_ m: Message, timestampUs: UInt64) -> [UInt8]
public static func encode(_ m: Message, timestampUs: UInt64, into out: inout [UInt8])
public static func decodeHeader(_ bytes: UnsafeRawBufferPointer) throws -> Header
public static func decode(_ bytes: [UInt8]) throws -> (Header, Message)
public static func decode(_ bytes: UnsafeRawBufferPointer) throws -> (Header, Message)
public static func decodeLenient(_ bytes: UnsafeRawBufferPointer) throws -> (Header, Message?)
```

`Protocol/Identity.swift`

```swift
public struct Identity: Equatable
public static let maxClientIDBytes = 64
public static let maxLabelBytes = 64
public var role: SolStream.Role
public var clientID: String
public var label: String
public init(role: SolStream.Role, clientID: String, label: String)
public init?(name: String)
public var name: String
public func mayControl(_ opcode: SolStream.Opcode) -> Bool
```

`Protocol/Messages.swift`

```swift
public struct Header: Equatable
public var opcode: UInt16
public var payloadLength: UInt32
public var timestampUs: UInt64
public init(opcode: UInt16, payloadLength: UInt32, timestampUs: UInt64)
public var knownOpcode: SolStream.Opcode?
public struct StrokeStart: Equatable
public var id: UUID
public var tool: SolStream.Tool
public var colorARGB: UInt32
public var baseWidth: Float
public var pointer: SolStream.PointerType
public var phase: SolStream.Phase
public var pressure: Float
public init(id: UUID, tool: SolStream.Tool, colorARGB: UInt32, baseWidth: Float, pointer: SolStream.PointerType, phase: SolStream.Phase, pressure: Float)
public var engages: Bool
public struct StateReport: Equatable
public var governor: UInt8
public var flags: UInt8
public var mode: UInt8
public var inkSource: UInt8
public var progress: Float
public var msToReturn: UInt32
public var pageIndex: UInt16
public var strokeCount: UInt16
public var undoDepth: UInt16
public var redoDepth: UInt16
public static let noReturnScheduled: UInt32 = 0xFFFF_FFFF
public init(governor: UInt8, flags: UInt8, mode: UInt8, inkSource: UInt8, progress: Float, msToReturn: UInt32, pageIndex: UInt16, strokeCount: UInt16, undoDepth: UInt16, redoDepth: UInt16)
public struct Flags: OptionSet
public let rawValue: UInt8
public init(rawValue: UInt8)
public static let pinned = Flags(rawValue: 1)
public static let preWarning = Flags(rawValue: 2)
public static let clientAllowed = Flags(rawValue: 4)
public static let clientIsActiveSource = Flags(rawValue: 8)
public static let cameraAttached = Flags(rawValue: 16)
public static let sinkConnected = Flags(rawValue: 32)
public static let saving = Flags(rawValue: 64)
public static let captureIdle = Flags(rawValue: 128)
public var flagSet: Flags
public enum Message: Equatable
public var opcode: SolStream.Opcode
```

`Protocol/SolStream.swift`

```swift
public enum SolStream
public static let magic: UInt8 = 0xDA
public static let version: UInt8 = 0x01
public static let headerLength = 16
public static let pointLength = 11
public static let maxPayload = 1 << 20
public static let maxPointsPerChunk = 4096
public static let maxErasedPerMessage = 1024
public static let maxNameLength = 200
public static let defaultPort: UInt16 = 7788
public static let serviceType = "_daylight-camera._tcp"
public static let subprotocol = "solstream.v1"
public static let canvasWidth = 1200
public static let canvasHeight = 1600
public static let targetWidth: UInt32 = 1920
public static let targetHeight: UInt32 = 1080
public static let targetFPS: UInt32 = 30
public enum Opcode: UInt16
public enum PointerType: UInt8
public enum Phase: UInt8
public enum Tool: UInt8
public enum AckStatus: UInt32
public enum Role: String
public struct Point: Equatable
public var x32: Int32
public var y32: Int32
public var pressure: UInt8
public var deltaMs: UInt16
public init(x32: Int32, y32: Int32, pressure: UInt8, deltaMs: UInt16)
public init(x: Double, y: Double, pressure: Double, deltaMs: Int)
public var x: Double
public var y: Double
public var pressureUnit: Double
```

`Governor/Clock.swift`

```swift
public protocol Clock
public struct SystemClock: Clock
public init()
public func now() -> Double
public final class ManualClock: Clock
public init(start: Double = 0)
public func now() -> Double
public func advance(_ dt: Double)
public func set(_ t: Double)
```

`Governor/EngageGovernor.swift`

```swift
public struct EngageGovernor
public let config: GovernorConfig
public private(set) var state: GovernorState = .passthrough
public private(set) var generation: UInt64 = 0
public init(config: GovernorConfig = GovernorConfig(), now: Double)
public var snapshot: GovernorOutput
public var needsTicks: Bool
public var pinnedState: Bool
public var holdState: HoldMode
public var layout: LayoutStyle
public var activeContactCount: Int
public func nextDeadline(now: Double) -> Double?
public mutating func tick(now: Double) -> GovernorOutput
public mutating func handle(_ event: GovernorEvent, now: Double) -> GovernorOutput
```

`Governor/GovernorEvent.swift`

```swift
public enum GovernorState: UInt8
public enum HoldMode: UInt8, Codable
public var forcedLayout: LayoutStyle?
public enum LayoutStyle: UInt8, Codable
public enum InkSource: UInt8, Codable
public var displayName: String
public var jsonName: String
public enum GovernorEvent: Equatable
public struct GovernorConfig: Equatable
public var idleTimeout: Double = 90
public var preWarningLead: Double = 5
public var snapBackWindow: Double = 0.080
public var snapBackMaxProgress: Double = 0.15
public var springK: Double = 1200
public var engageOnEraser: Bool = false
public var autoEngage: Bool = true
public init()
public init(settings: Settings)
```

`Governor/GovernorOutput.swift`

```swift
public enum SaveReason: String, Codable
public enum GovernorEffect: Equatable
public struct GovernorOutput: Equatable
public var state: GovernorState
public var progress: Double
public var pinned: Bool
public var hold: HoldMode
public var layout: LayoutStyle
public var preWarning: Bool
public var breath: Double
public var msToReturn: UInt32
public var activeContacts: Int
public var effects: [GovernorEffect]
public init(state: GovernorState = .passthrough, progress: Double = 0, pinned: Bool = false, hold: HoldMode = .auto, layout: LayoutStyle = .studioSplit, preWarning: Bool = false, breath: Double = 0, msToReturn: UInt32 = StateReport.noReturnScheduled, activeContacts: Int = 0, effects: [GovernorEffect] = [])
public static func breathWeight(secondsSincePreWarning t: Double) -> Double
public func stateReport(clientFlags: StateReport.Flags, inkSource: InkSource, pageIndex: Int, strokeCount: Int, undoDepth: Int, redoDepth: Int) -> StateReport
```

`Spring/CriticalSpring.swift`

```swift
public struct CriticalSpring: Equatable
public let omega: Double
public private(set) var position: Double
public private(set) var velocity: Double
public private(set) var target: Double
public init(k: Double = 1200, m: Double = 1, position: Double = 0)
public mutating func retarget(_ newTarget: Double, at now: Double)
public mutating func snap(to value: Double, at now: Double)
public mutating func evaluate(at now: Double) -> Double
public var isSettled: Bool
public func eulerReferenceStep(x: inout Double, v: inout Double, target: Double, dt: Double, k: Double, m: Double)
```

`Layout/Rects.swift`

```swift
public struct PixelRect: Equatable
public var x: Double
public var y: Double
public var w: Double
public var h: Double
public init(x: Double, y: Double, w: Double, h: Double)
public struct UVRect: Equatable
public var u0: Double
public var v0: Double
public var u1: Double
public var v1: Double
public init(u0: Double, v0: Double, u1: Double, v1: Double)
public static let full = UVRect(u0: 0, v0: 0, u1: 1, v1: 1)
public struct QuadSpec: Equatable
public var dest: PixelRect
public var uv: UVRect
public init(dest: PixelRect, uv: UVRect)
```

`Layout/StudioLayout.swift`

```swift
public enum StudioLayout
public static let outputWidth: Double = 1920
public static let outputHeight: Double = 1080
public static let portraitZoneWidth: Double = 1280
public static let landscapeZoneWidth: Double = 1440
public static let portraitAspect: Double = 3.0 / 4.0
public static let landscapeAspect: Double = 4.0 / 3.0
public static let dividerWidth: Double = 2
public static let borderWidth: Double = 1
public struct Frame: Equatable
public var presenter: QuadSpec?
public var canvas: QuadSpec?
public var canvasClip: PixelRect?
public var borders: [PixelRect]
public var divider: PixelRect?
public var dividerColor: RGBA
public var dividerAlpha: Double
public init(presenter: QuadSpec?, canvas: QuadSpec?, canvasClip: PixelRect?, borders: [PixelRect], divider: PixelRect?, dividerColor: RGBA, dividerAlpha: Double)
public enum CanvasOrientation
public var aspect: Double
public var zoneWidth: Double
public init(width: Int, height: Int)
public static func passthrough() -> Frame
public static func frame(progress s: Double, layout: LayoutStyle, orientation: CanvasOrientation, canvasAspect: Double, breath: Double = 0) -> Frame
public static func fit(aspect: Double, into r: PixelRect) -> PixelRect
public static func clip(_ r: PixelRect) -> (l: Double, t: Double, r: Double, b: Double)
public static func amberBreath(weight: Double) -> RGBA
```

`Layout/Tokens.swift`

```swift
public struct RGBA: Equatable
public var r: Double
public var g: Double
public var b: Double
public var a: Double
public init(r: Double, g: Double, b: Double, a: Double = 1)
public init(hex: UInt32, alpha: Double = 1)
public enum Tokens
public static let inkBlack = RGBA(hex: 0x111111)
public static let paperBg = RGBA(hex: 0xFAF8F5)
public static let surfaceCream = RGBA(hex: 0xEAE5DC)
public static let borderSubtle = RGBA(hex: 0xCDC6B8)
public static let amber = RGBA(hex: 0xD97706)
public static let amberDeep = RGBA(hex: 0xC87D20)
public static let terracotta = RGBA(hex: 0x9C271D)
public static let textMuted = RGBA(hex: 0x736F68)
```

`Canvas/CatmullRom.swift`

```swift
public enum CatmullRom
public static func bezierControls(p0: (Double, Double), p1: (Double, Double), p2: (Double, Double), p3: (Double, Double)) -> (c1: (Double, Double), c2: (Double, Double))
public static func point(p0: (Double, Double), p1: (Double, Double), p2: (Double, Double), p3: (Double, Double), t: Double) -> (Double, Double)
public static func bezierPoint(p1: (Double, Double), c1: (Double, Double), c2: (Double, Double), p2: (Double, Double), t: Double) -> (Double, Double)
```

`Canvas/Geometry.swift`

```swift
public enum Geometry
public static func distanceSquared(point: (Double, Double), segment a: (Double, Double), b: (Double, Double)) -> Double
public static func segmentDistanceSquared(_ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double), _ d: (Double, Double)) -> Double
public static func strokeHit(_ s: Stroke, segment a: (Double, Double), b: (Double, Double), radius: Double) -> Bool
```

`Canvas/PageDocument.swift`

```swift
public struct PageDocument: Codable, Equatable
public static let schemaName = "daylight-whiteboard-strokes/1"
public struct Canvas: Codable, Equatable
public var width: Int
public var height: Int
public var dpi: Int
public var units: String
public init(width: Int = 1200, height: Int = 1600, dpi: Int = 200, units: String = "canvas")
public struct Session: Codable, Equatable
public var started: String
public var saved: String
public var reason: SaveReason
public var inkSource: String
public var clientLabel: String
public init(started: String, saved: String, reason: SaveReason, inkSource: String, clientLabel: String)
public struct Page: Codable, Equatable
public var id: String
public var index: Int
public init(id: String, index: Int)
public struct Point: Codable, Equatable
public var x: Double
public var y: Double
public var pressure: Double
public var tMs: Int
public init(x: Double, y: Double, pressure: Double, tMs: Int)
public init(from decoder: Decoder) throws
public func encode(to encoder: Encoder) throws
public struct StrokeRecord: Codable, Equatable
public var id: String
public var tool: String
public var color: String
public var baseWidth: Double
public var points: [Point]
public init(id: String, tool: String, color: String, baseWidth: Double, points: [Point])
public var schema: String
public var app: String
public var canvas: Canvas
public var session: Session
public var page: Page
public var strokes: [StrokeRecord]
public init(schema: String = PageDocument.schemaName, app: String, canvas: Canvas, session: Session, page: Page, strokes: [StrokeRecord])
public static func isoString(_ date: Date) -> String
public static func toolName(_ tool: SolStream.Tool) -> String
public static func tool(named name: String) -> SolStream.Tool?
public static func colorString(_ argb: UInt32) -> String
public static func colorValue(_ text: String) -> UInt32?
public func strokeValues() -> [Stroke]
```

`Canvas/Stroke.swift`

```swift
public struct StrokeStyle: Equatable
public var tool: SolStream.Tool
public var colorARGB: UInt32
public var baseWidth: Float
public init(tool: SolStream.Tool, colorARGB: UInt32, baseWidth: Float)
public static let pen = StrokeStyle(tool: .pen, colorARGB: 0xFF11_1111, baseWidth: 3.2)
public static let highlighter = StrokeStyle(tool: .highlighter, colorARGB: 0x80D9_7706, baseWidth: 12.0)
public var maxWidth: Double
public struct Stroke
public let id: UUID
public var style: StrokeStyle
public private(set) var points: ContiguousArray<SolStream.Point>
public private(set) var bounds: PixelRect
public var isCommitted: Bool
public init(id: UUID, style: StrokeStyle)
public mutating func append(_ pts: [SolStream.Point])
public var dirtyBounds: PixelRect
public var isDot: Bool
public var dotDiameter: Double
public func width(at index: Int) -> Double
public struct DirtyRect: Equatable
public var rect: PixelRect?
public init(rect: PixelRect? = nil)
public mutating func union(_ r: PixelRect)
public func clipped(toWidth w: Int, height h: Int) -> PixelRect?
public enum CanvasOp: Equatable
```

`Canvas/StrokeStore.swift`

```swift
public struct StrokeStore
public private(set) var strokes: [Stroke] = []
public private(set) var activeStrokeIDs: Set<UUID> = []
public private(set) var pageID = UUID()
public private(set) var pageIndex = 0
public private(set) var pageWidth: Double
public private(set) var pageHeight: Double
public private(set) var lastInkAt: Double?
public private(set) var savedAt: Double?
public let canvasWidth: Int
public let canvasHeight: Int
public init(canvasWidth: Int = SolStream.canvasWidth, canvasHeight: Int = SolStream.canvasHeight)
public var undoDepth: Int
public var redoDepth: Int
public var committedCount: Int
public var hasInk: Bool
public var isDirty: Bool
public var pageAspect: Double
public func stroke(id: UUID) -> Stroke?
public mutating func start(_ s: StrokeStart, scale: (Double, Double) = (1, 1)) -> CanvasOp?
public mutating func append(id: UUID, points: [SolStream.Point], now: Double) -> CanvasOp?
public mutating func commit(id: UUID, pointCount: UInt32) -> CanvasOp?
public mutating func commitAll(ids: Set<UUID>) -> [CanvasOp]
public mutating func cancel(id: UUID) -> CanvasOp?
public mutating func erase(x1: Float, y1: Float, x2: Float, y2: Float, radius: Float, hint: [UUID], now: Double? = nil) -> CanvasOp?
public mutating func undo(now: Double? = nil) -> CanvasOp?
public mutating func redo(now: Double? = nil) -> CanvasOp?
public mutating func clear() -> CanvasOp
public mutating func newPage(id: UUID, index: Int, width: Double, height: Double) -> CanvasOp
public mutating func markSaved(at now: Double)
public static func width(base: Double, pressure: Double) -> Double
public func document(sessionStart: Date, savedAt: Date, reason: SaveReason, inkSource: InkSource, clientLabel: String, app: String = "Daylight") -> PageDocument
```

`HTTP/HTTPRequest.swift`

```swift
public struct HTTPRequest: Equatable
public var method: String
public var path: String
public var query: [String: String]
public var headers: [String: String]
public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:])
public static let webSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
public static let maxHeadLength = 16 * 1024
public static func parse(_ buffer: UnsafeRawBufferPointer) throws -> (request: HTTPRequest, consumed: Int)?
public static func parse(_ bytes: [UInt8]) throws -> (request: HTTPRequest, consumed: Int)?
public var isWebSocketUpgrade: Bool
public var webSocketKey: String?
public var webSocketVersion: Int?
public var webSocketProtocols: [String]
public static func statusText(_ code: Int) -> String
public static func response(status: Int, headers: [(String, String)], body: [UInt8]) -> [UInt8]
public static func webSocketAccept(forKey key: String) -> String
public static func upgradeResponse(accept: String, subprotocol: String?) -> [UInt8]
public enum HTTPError: Error, Equatable
```

`HTTP/MIME.swift`

```swift
public enum MIME
public static func type(forExtension ext: String) -> String?
```

`HTTP/SHA1.swift`

```swift
public enum SHA1
public static func hash(_ bytes: UnsafeRawBufferPointer) -> [UInt8]
public static func hash(_ bytes: [UInt8]) -> [UInt8]
```

`HTTP/WebRootPath.swift`

```swift
public enum WebRootPath
public static func resolve(_ requestPath: String) -> String?
```

`HTTP/WebSocketFrame.swift`

```swift
public enum WebSocketError: Error, Equatable
public struct WebSocketFrame: Equatable
public var fin: Bool
public var opcode: UInt8
public var payload: [UInt8]
public static let opcodeContinuation: UInt8 = 0x0
public static let opcodeText: UInt8 = 0x1
public static let opcodeBinary: UInt8 = 0x2
public static let opcodeClose: UInt8 = 0x8
public static let opcodePing: UInt8 = 0x9
public static let opcodePong: UInt8 = 0xA
public static let defaultMaxPayload = 2 * 1024 * 1024
public static let maxControlPayload = 125
public init(fin: Bool, opcode: UInt8, payload: [UInt8])
public var isControl: Bool
public static func parse(_ buffer: inout [UInt8], maxPayload: Int) throws -> (frame: WebSocketFrame, consumed: Int)?
public static func encode(opcode: UInt8, payload: UnsafeRawBufferPointer, into out: inout [UInt8])
public static func encode(opcode: UInt8, payload: [UInt8]) -> [UInt8]
public static func encodeMasked(fin: Bool = true, opcode: UInt8, payload: [UInt8], key: (UInt8, UInt8, UInt8, UInt8)) -> [UInt8]
public static func encodeClose(code: UInt16, reason: String) -> [UInt8]
public static func closeCode(_ payload: [UInt8]) -> UInt16?
public struct WebSocketMessageAssembler
public let maxMessage: Int
public init(maxMessage: Int = WebSocketFrame.defaultMaxPayload)
public var isAssembling: Bool
public mutating func accept(_ frame: WebSocketFrame) throws -> WebSocketFrame?
```

`Settings/FailureText.swift`

```swift
public enum FailureText
public enum Case: String, CaseIterable
public var row: String
public static let approvalPathModern = "System Settings > General > Login Items & Extensions > Camera Extensions"
public static let approvalPathLegacy = "System Settings > Privacy & Security > Security"
public static func sentence(_ c: Case, _ args: [String] = []) -> String
public static func followUp(_ c: Case) -> String?
public static func logLine(_ c: Case, _ args: [String] = []) -> String
```

`Settings/Settings.swift`

```swift
public enum HotkeyAction: String, Codable, CaseIterable, CodingKeyRepresentable
public struct HotkeyBinding: Codable, Equatable
public var keyCode: UInt32
public var modifiers: UInt32
public init(keyCode: UInt32, modifiers: UInt32)
public static let cmdKey: UInt32 = 1 << 8
public static let optionKey: UInt32 = 1 << 11
public static let controlKey: UInt32 = 1 << 12
public static let defaultModifiers: UInt32 = cmdKey | optionKey | controlKey
public static let keyW: UInt32 = 0x0D
public static let keyD: UInt32 = 0x02
public static let keyK: UInt32 = 0x28
public static let keyC: UInt32 = 0x08
public static let keyEscape: UInt32 = 0x35
public enum MirrorPinClearMode: String, Codable
public var includesPills: Bool
public var includesPenButton: Bool
public enum PillsPosition: String, Codable
public enum AdbServerMode: String, Codable
public struct Settings: Codable, Equatable
public static let userDefaultsKey = "com.twelve.daylight.settings.v1"
public static let documentsFolderName = "Daylight Camera"
public static let clientsFileName = "clients.json"
public static let applicationSupportFolderName = "Daylight"
public var onboardingDone: Bool = false
public var onboardingVersion: Int = 1
public var cameraUniqueID: String? = nil
public var inkSource: InkSource = .web
public var preferredLayout: LayoutStyle = .studioSplit
public var holdMode: HoldMode = .auto
public var autoEngage: Bool = true
public var idleTimeoutSeconds: Int = 90
public var preWarningSeconds: Int = 5
public var springK: Double = 1200
public var engageOnEraser: Bool = false
public var hotkeys: [HotkeyAction: HotkeyBinding] = Settings.defaultHotkeys
public var port: UInt16 = SolStream.defaultPort
public var bonjourName: String? = nil
public var trustLoopback: Bool = true
public var mirrorPinClearMode: MirrorPinClearMode = .both
public var sideButtonDoublePressMs: Int = 400
public var sideButtonLongPressMs: Int = 700
public var sideButtonSwap: Bool = false
public var mirrorCropInsetsPortrait: CropInsets = CropInsets(top: 96, left: 0, right: 0, bottom: 0)
public var mirrorCropInsetsLandscape: CropInsets = CropInsets(top: 72, left: 0, right: 0, bottom: 0)
public var pillStripHeight: Int = 96
public var mirrorPillsPosition: PillsPosition = .top
public var mirrorMaxSize: Int = 1600
public var mirrorBitRate: Int = 8_000_000
public var mirrorMaxFps: Int = 30
public var mirrorDeviceSerial: String? = nil
public var adbServerMode: AdbServerMode = .auto
public var adbPrivatePort: UInt16 = 27180
public var mirrorOverWiFi: Bool = false
public var viewerIdleStopSeconds: Int = 60
public var saveDirectory: URL? = nil
public var saveStrokesJSON: Bool = true
public var autosaveSeconds: Int = 60
public var previewOnLaunch: Bool = false
public var previewFloats: Bool = true
public var frameReuse: Bool = false
public var deadlineIdle: Bool = false
public var perfLog: Bool = false
public init()
public static let defaults = Settings()
public static let defaultHotkeys: [HotkeyAction: HotkeyBinding] = [
public static let lowBandwidthMirror: (maxSize: Int, bitRate: Int, maxFps: Int) = (1200, 4_000_000, 24)
public static let idleTimeoutRange = 15...600
public static let preWarningRange = 0...30
public static let springKRange: ClosedRange<Double> = 300...2400
public static let viewerIdleStopRange = 10...600
public static let autosaveRange = 15...600
public static let portRange: ClosedRange<Int> = 1024...65535
public func validated() -> Settings
public init(from decoder: Decoder) throws
public func encode(to encoder: Encoder) throws
```

`Session/SessionFiles.swift`

```swift
public enum SessionFiles
public static let folderName = "Daylight Camera"
public static let sessionGapSeconds: Double = 600
public static func sessionDirectory(root: URL, sessionStart: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> URL
public static func pageBaseName(index: Int) -> String
public static func mirrorName(sessionStart: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String
public static func uniqueURL(_ url: URL, exists: (URL) -> Bool) -> URL
public static func startsNewSession(lastInkAt: Double?, now: Double) -> Bool
```

`Util/FixedPoint.swift`

```swift
public enum FixedPoint
public static func toX32(_ v: Double) -> Int32
public static func fromX32(_ v: Int32) -> Double
public static func quantizePressure(_ p: Double) -> UInt8
```

`Util/Hex.swift`

```swift
public enum Hex
public static func encode(_ bytes: [UInt8]) -> String
public static func decode(_ text: String) -> [UInt8]?
```

`Util/Locked.swift`

```swift
public final class Locked<Value>
public init(_ value: Value)
public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R
```

`Util/RateLimiter.swift`

```swift
public struct RateLimiter
public var minInterval: Double
public init(minInterval: Double)
public mutating func allow(now: Double) -> Bool
```

`Util/RingBuffer.swift`

```swift
public struct RingBuffer<T>
public private(set) var count = 0
public init(capacity: Int)
public var capacity: Int
public mutating func push(_ item: T)
public mutating func drain() -> [T]
```
