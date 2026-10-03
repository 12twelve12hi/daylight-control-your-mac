# SolStream-v1 over WebSocket: the Daylight Camera wire protocol

Status: binding for v1. Every client (web whiteboard, Daylight Ink APK incl. its overlay pills, the Mac's own self-test client) and the Swift server implement exactly this document. The Python prototype at `DaylightWhiteboardCamera/src/protocol/solstream_wire.py` is the oracle for the byte layouts that already existed there; the additions (UNDO, REDO, STATE, the identity convention, the allow handshake, the limits) are defined here and nowhere else. `protocol/gen_golden.py` regenerates the golden vectors in section 12 with Python `struct`; CI fails when any committed copy drifts.

Writing rules: no em-dashes. Sizes are bytes. All integers are little-endian unless a section says otherwise. Hex strings are lower-case, no separators.

---

## 1. Transport

| Item | Value |
|---|---|
| URL | `ws://<mac-address>:<port>/ink`; default port 7788. The bound port is also published in the Bonjour TXT record (`port`) and in `GET /api/info`. |
| Bonjour | service type `_daylight-camera._tcp` (exactly 15 characters after the underscore; never lengthen it), instance name `Daylight Camera on <hostname>`, TXT `v=1`, `ws=/ink`, `port=<n>`. |
| WebSocket version | RFC 6455, `Sec-WebSocket-Version: 13`. |
| Subprotocol | Clients SHOULD send `Sec-WebSocket-Protocol: solstream.v1`. The server echoes `solstream.v1` when the client offered it and sends no `Sec-WebSocket-Protocol` header otherwise. A client that offers it and does not get it back MUST treat the server as incompatible and stop retrying. |
| Framing | One SolStream message per WebSocket BINARY message. Text frames are ignored (logged once per connection). Fragmented messages are reassembled per RFC 6455; no shipping client fragments. Client frames are masked, server frames are not. |
| Message cap | payload_len <= 1,048,576 (1 MiB). WebSocket receive buffer per connection 2 MiB. Exceeding either closes with 1009. |
| Keep-alive | Client sends PING (0x00FE) every 10 s (the APK also uses OkHttp's `pingInterval(10, SECONDS)`); the server answers PONG with the same payload. The server closes a connection after 30 s without any frame. Clients reconnect with backoff (web: 1000 ms x 1.7 capped at 15 s; APK: 0.5 s doubling to 8 s with 20 percent jitter). |
| Close codes used by the server | 1002 bad magic or version (not a SolStream peer); 1008 a denied client sent ink; 1009 oversize frame or payload; 1001 server shutting down. |

HTTP on the same listener (same port):

| Route | Purpose |
|---|---|
| `GET /` and static paths | the web whiteboard (Vite `dist`), `Connection: close`, `/assets/*` with `Cache-Control: public, max-age=31536000, immutable`, everything else `no-cache`; `.webmanifest` served as `application/manifest+json`. |
| `GET /ink` with `Upgrade: websocket` | the protocol below. |
| `GET /healthz` | `200 text/plain` body `ok`. Used by Playwright's `webServer` readiness and by the owner's curl test. |
| `GET /api/info` | `200 application/json`: `{"app":"daylight","version":"<marketing>","build":<run number>,"port":7788,"inkSource":"web|native|mirror","pillStripHeight":96,"secureHint":"chrome://flags/#unsafely-treat-insecure-origin-as-secure","origin":"http://<ip>:7788"}`. |
| `GET /daylight-ink.apk` | the embedded `Resources/DaylightInk.apk`, `Content-Type: application/vnd.android.package-archive`, `Content-Disposition: attachment; filename="DaylightInk.apk"`; `404` when the build has no APK. |

---

## 2. Conventions

- Integers: little-endian two's complement (`<` in Python `struct`, `DataView(..., true)` in JS, `ByteOrder.LITTLE_ENDIAN` in Kotlin, byte assembly in Swift).
- Floats: IEEE 754 binary32 little-endian (`f`).
- UUID (`16s`): 16 raw bytes in RFC 4122 byte order, i.e. the bytes of the canonical hex string in reading order. Python `uuid.bytes`; Swift `uuid.uuid` tuple in order; JS `Uint8Array(16)` parsed from the hex string; Kotlin: write `mostSignificantBits` then `leastSignificantBits` into a BIG-endian `ByteBuffer` and copy the 16 bytes (writing them little-endian is the classic bug the golden vectors catch).
- Strings: UTF-8, no terminator, length-prefixed where a length field exists.
- Alignment: none. Points are 11 bytes and land on odd offsets; decoders assemble bytes and never cast.
- Rounding: `x32 = round(x * 32)`, `pressure_u8 = round(clamp(p, 0, 1) * 255)`, both round-half-away-from-zero (`Math.round` in JS and Kotlin for non-negative values, `.rounded()` in Swift, Python `round` differs only on exact ties, which the golden inputs avoid).

---

## 3. Header (16 bytes, `<BBHIQ`)

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 1 | magic | `0xDA` |
| 1 | 1 | version | `0x01` |
| 2 | 2 | msg_type | opcode (section 5) |
| 4 | 4 | payload_len | bytes after the header; MUST equal `frame.length - 16`; <= 1 MiB |
| 8 | 8 | timestamp_us | sender clock in microseconds since the Unix epoch: web `BigInt(Math.round((performance.timeOrigin + performance.now()) * 1000))`, Android `System.currentTimeMillis() * 1000`, Mac `UInt64(Date().timeIntervalSince1970 * 1_000_000)`. Informational (logs, PONG round trips); never used for ordering. |

Decoder rules: magic or version mismatch -> close 1002. `payload_len != frame.length - 16` -> drop the message, log once per connection, keep the socket. The Swift `Header.opcode` is a `UInt16` with a computed `Opcode?` so an unknown opcode is representable (ignored, logged once per opcode value).

---

## 4. Point (11 bytes, `<iiBH`)

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 4 | x32 | `int32`, canvas units times 32 |
| 4 | 4 | y32 | `int32`, canvas units times 32 |
| 8 | 1 | pressure | `uint8 = round(clamp(p, 0, 1) * 255)` |
| 9 | 2 | delta_ms | `uint16`, milliseconds since the FIRST point of this stroke (the first point carries 0), saturating at 65535. Defined by the oracle (`models.py:138`, "Monotonic relative time from stroke start"). It is NOT the gap to the previous point. |

Coordinate space: canvas units are the 1200 x 1600 portrait page (3:4), origin top-left, y down, independent of device pixels and DPR. Web: `x = (clientX - rect.left) * 1200 / rect.width` where `rect` is the 3:4 canvas element; Android: `x = viewX * 1200 / viewWidth` inside the letterboxed 3:4 view. Negative and out-of-range values are legal on the wire (the Mac clips when it rasterises). Mirror mode sends no points.

---

## 5. Opcodes

| Opcode | Name | Direction | Payload | Size |
|---|---|---|---|---|
| 0x0001 | HANDSHAKE | C to S | `<fffH` + name | 14 + n |
| 0x0002 | HANDSHAKE_ACK | S to C | `<IIII` | 16 |
| 0x0010 | STROKE_START | C to S | `<16sBIfBBf` | 31 (decoders also accept 25) |
| 0x0011 | STROKE_CHUNK | C to S | `<16sH` + N points | 18 + 11N, 1 <= N <= 4096 |
| 0x0012 | STROKE_COMMIT | C to S | `<16sI` | 20 |
| 0x0013 | STROKE_CANCEL | C to S | `<16s` | 16 |
| 0x0014 | UNDO (new) | C to S | `<16sQ` | 24 |
| 0x0015 | REDO (new) | C to S | `<16sQ` | 24 |
| 0x0020 | ERASE_STROKES | C to S | `<fffffH` + K uuids | 22 + 16K, 0 <= K <= 1024 |
| 0x0030 | LASER_POINT | C to S | `<ffff` | 16 |
| 0x0040 | CLEAR_CANVAS | C to S | `<16sQ` (or empty) | 24 (decoders also accept 0) |
| 0x0050 | PAGE_CHANGE | C to S | `<16sffI` | 28 |
| 0x0060 | AUTO_ENGAGE_RETURN | C to S | `<Q` | 8 |
| 0x0061 | TOGGLE_PIN_WHITEBOARD | C to S | `<bQ` | 9 |
| 0x0070 | STATE (new) | S to C | `<BBBBfIHHHH` | 20 |
| 0x0071 | MIRROR_CONTROL (mirror v2) | S to C | `<BBHIHH` | 12 |
| 0x0080 | MIRROR_HELLO (mirror v2) | C to S | 64-byte name + `>I` codec id | 68 |
| 0x0081 | MIRROR_PACKET (mirror v2) | C to S | `>QI` + n bytes (or the 12-byte session form) | 12 + n |
| 0x0082 | MIRROR_STATUS (mirror v2) | C to S | `<BBHHHII` | 16 |
| 0x00FE | PING | C to S | `<QQ` | 16 |
| 0x00FF | PONG | S to C | `<QQ` | 16 |

Not defined: 0x0003 (a separate CLIENT_HELLO was considered and rejected; identity travels in the HANDSHAKE name, section 7). Reserved for v2: 0x0072 to 0x007F (server to client), 0x0016 to 0x001F (stroke family), 0x0083 to 0x008F (mirror stream family). The mirror stream family (0x0071 and 0x0080 to 0x0082) is specified in section 14; a peer that does not implement it ignores those opcodes like any unknown opcode (section 10).

---

## 6. Message layouts

### 6.1 HANDSHAKE (0x0001), client to server, 14 + n bytes

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 4 | canvas_width | f32, canvas units the client will send (1200.0) |
| 4 | 4 | canvas_height | f32 (1600.0) |
| 8 | 4 | dpi | f32, informational (200.0 on the DC-1) |
| 12 | 2 | name_len | u16, 1 <= name_len <= 200 |
| 14 | n | name | UTF-8, `"<role>;<clientId>;<label>"` (section 7) |

Rules: first message on the socket, within 5 s of the WebSocket open (else close 1002). Clients MUST declare a 3:4 canvas; the Mac scales points by `1200 / canvas_width` and `1600 / canvas_height` and logs when they differ. The oracle's 28-byte fixed-name form (16 NUL-padded name bytes then `<fff>`) is NOT accepted: it is ambiguous with a variable-length name of 14 bytes, and nothing ships that sends it.

### 6.2 HANDSHAKE_ACK (0x0002), server to client, 16 bytes

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 4 | target_width | u32, 1920 |
| 4 | 4 | target_height | u32, 1080 |
| 8 | 4 | target_fps | u32, 30 (the oracle said 60; the camera is 30 fps) |
| 12 | 4 | status | u32: 0 OK (allowed), 1 PENDING_APPROVAL, 2 DENIED (server closes 1008 after sending), 3 UNSUPPORTED (bad canvas or name; server closes 1002 after sending) |

A connection may receive HANDSHAKE_ACK twice: status 1 first, then status 0 when the owner clicks Allow (section 8).

### 6.3 STROKE_START (0x0010), client to server, 31 bytes

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 16 | stroke_id | UUID, fresh per stroke |
| 16 | 1 | tool | 0 pen, 1 highlighter, 2 eraser, 3 lasso (lasso unused in v1) |
| 17 | 4 | color | u32 ARGB (pen default `0xFF111111` InkBlack; highlighter default `0x80D97706` Amber at 50 percent) |
| 21 | 4 | base_width | f32, canvas units (pen 3.2, highlighter 12.0, eraser radius 12.0) |
| 25 | 1 | pointer_type | 0 stylus, 1 finger, 2 palm, 3 mouse, 4 unknown |
| 26 | 1 | phase | 0 hover, 1 contact, 2 cancel, 3 unknown |
| 27 | 4 | pressure | f32 in [0, 1] at contact |

Clients always send the 31-byte form and never send pointer_type != 0 or phase != 1 (fingers, palms and hover are filtered on the tablet). The server re-checks: the governor engages only when `pointer_type == 0 && phase == 1 && pressure > 0`; a STROKE_START that fails the check is dropped together with its chunks. Decoders accept the oracle's 25-byte `<16sBIf` form as stylus, contact, pressure 0.5 (decode-only golden `stroke_start_legacy25`). The oracle's 26-byte `<16sHIf` form is rejected (dropped, logged). The first point of the stroke is NOT in this message; it arrives in the first STROKE_CHUNK with delta_ms 0.

### 6.4 STROKE_CHUNK (0x0011), client to server, 18 + 11N bytes

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 16 | stroke_id | UUID of an open stroke |
| 16 | 2 | count | u16 N, 1 <= N <= 4096 |
| 18 | 11N | points | N Points (section 4) in time order |

Batching: web sends one chunk per `requestAnimationFrame` per active stroke; Android one chunk per Choreographer frame (`sendPerEvent` setting switches to one chunk per MotionEvent). `count == 0` or `count > 4096` -> message dropped and logged, socket kept. A chunk for an unknown stroke_id is dropped (the stroke was cancelled or belongs to a client that was not allowed).

### 6.5 STROKE_COMMIT (0x0012), client to server, 20 bytes

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 16 | stroke_id | UUID |
| 16 | 4 | point_count | u32, total points the client sent; informational, a mismatch is logged, never rejected |

### 6.6 STROKE_CANCEL (0x0013), client to server, 16 bytes

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 16 | stroke_id | UUID; the stroke is removed from the canvas (dirty rectangle redrawn); may trigger the governor's snap-back (SPEC section 5.2, ENGAGING + cancel) |

Web sends it on `pointercancel` or `pointerleave` while down when the stroke has fewer than 2 points or is younger than 80 ms; otherwise it sends STROKE_COMMIT. Android sends it on `ACTION_CANCEL` and on `FLAG_CANCELED`.

### 6.7 UNDO (0x0014) and REDO (0x0015), client to server, 24 bytes

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 16 | page_id | UUID of the page; all-zero = the current page |
| 16 | 8 | client_time_us | u64 |

The Mac is the source of truth: the client does NOT mutate its local undo stack on tap; it waits for STATE `undo_depth` / `redo_depth` and redraws from its own stroke list using the Mac's depths (the local list and the Mac's list hold the same strokes in the same order because every stroke went through this socket). Undo while a stroke is open applies to the last committed stroke.

### 6.8 ERASE_STROKES (0x0020), client to server, 22 + 16K bytes

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 4 | x1 | f32 canvas units, eraser segment start |
| 4 | 4 | y1 | f32 |
| 8 | 4 | x2 | f32, segment end |
| 12 | 4 | y2 | f32 |
| 16 | 4 | radius | f32 canvas units |
| 20 | 2 | count | u16 K, 0 <= K <= 1024 |
| 22 | 16K | ids | UUIDs the client believes it erased (hint) |

The Mac's own hit test (point-to-polyline distance <= radius + width / 2) is authoritative; the id list may be empty. One message per eraser sample. `K > 1024` -> dropped and logged.

### 6.9 LASER_POINT (0x0030), client to server, 16 bytes

`<ffff` x, y (canvas units), intensity [0, 1], decay_s. Accepted, counts as activity (resets the idle timer), not rendered in v1.

### 6.10 CLEAR_CANVAS (0x0040), client to server, 24 bytes

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 16 | page_id | UUID; all-zero = current page |
| 16 | 8 | client_time_us | u64 |

Clients send the 24-byte form; decoders also accept the oracle's 0-byte form (decode-only golden `clear_canvas_empty`). Semantics (SPEC section 7): save the page if it has ink, clear both layers and the undo stack, then return to camera unless pinned.

### 6.11 PAGE_CHANGE (0x0050), client to server, 28 bytes

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 16 | page_id | UUID of the NEW page (client-generated) |
| 16 | 4 | width | f32 canvas units (1200.0) |
| 20 | 4 | height | f32 (1600.0) |
| 24 | 4 | page_index | u32, 0-based index in this session |

"New page": the previous page is saved (if it has ink), the canvas and undo stack are cleared, the whiteboard stays up. Counts as activity.

### 6.12 AUTO_ENGAGE_RETURN (0x0060), client to server, 8 bytes

`<Q` client_time_us. "Back to camera now": unpins and starts RETURNING (from LIVE or ENGAGING). Sent by the chip long press.

### 6.13 TOGGLE_PIN_WHITEBOARD (0x0061), client to server, 9 bytes

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 1 | value | i8: -1 toggle, 0 off, 1 on |
| 1 | 8 | client_time_us | u64 |

Semantics in SPEC section 7; notably a pin while RETURNING re-engages ("keep it").

### 6.14 STATE (0x0070), server to client, 20 bytes, `<BBBBfIHHHH`

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 1 | governor | 0 PASSTHROUGH, 1 ENGAGING, 2 LIVE, 3 RETURNING |
| 1 | 1 | flags | bit0 pinned; bit1 pre_warning; bit2 this_client_allowed; bit3 this_client_is_active_source; bit4 camera_attached (a webcam device is present; says nothing about whether it is capturing); bit5 sink_connected (the camera extension's sink stream is open); bit6 saving (a page write is in progress); bit7 capture_idle (webcam capture is stopped because nobody is viewing Daylight Camera and the preview is closed) |
| 2 | 1 | mode | 0 auto, 1 hold Studio Split, 2 hold Whiteboard Only, 3 hold camera |
| 3 | 1 | ink_source | the Mac's current "Ink source" setting: 0 web, 1 native, 2 mirror |
| 4 | 4 | progress | f32 spring position 0 (camera) to 1 (board) |
| 8 | 4 | ms_to_return | u32 milliseconds until the automatic return: remaining idle time while LIVE, unpinned and no pen on the glass; 0 while RETURNING; `0xFFFFFFFF` when no return is scheduled (PASSTHROUGH, ENGAGING, pinned, hold mode, pen down) |
| 12 | 2 | page_index | u16 current page |
| 14 | 2 | stroke_count | u16 committed strokes on the page (saturates) |
| 16 | 2 | undo_depth | u16 strokes available to undo |
| 18 | 2 | redo_depth | u16 strokes available to redo |

Cadence: immediately after HANDSHAKE_ACK; immediately on any change of governor, flags, mode, ink_source, page_index, undo_depth or redo_depth; at 10 Hz while governor is ENGAGING or RETURNING or `pre_warning` is set (so the chip countdown and the amber breath stay in phase with the divider); at 1 Hz while LIVE; never while PASSTHROUGH with nothing changed (clients count down locally from `ms_to_return` between messages and use PING/PONG for liveness). The amber breath on the tablet uses the same formula as the Mac, `0.5 * (1 - cos(2 * pi * t / 2))`, where `t` is seconds since `pre_warning` was first seen set.

Chip mapping (web and native, SPEC section 10): `allowed` clear -> "Look at your Mac"; `active_source` clear -> "Ink source is <web|native|mirror> on the Mac"; governor 0 -> "Camera"; 1 or 2 with `pinned` -> "KEEP WHITEBOARD"; 1 or 2 -> "LIVE"; `pre_warning` -> "Returning in N" with N = `ceil(ms_to_return / 1000)`; 3 -> "Returning" (tap = keep). Before any STATE: ACK status 1 -> "Look at your Mac"; ACK status 2 -> "Not allowed by the Mac"; ACK status 3, or a server that did not echo the offered `solstream.v1` -> "Update Daylight on your Mac" (the client stops re-dialling until the chip is tapped). Chromium fails the upgrade itself when the offered subprotocol is not echoed, so a web client never observes that case directly; after five failed dials plus a `GET /api/info` answer with `"app":"daylight"` it shows the web-only "Mac found, socket refused. Tap to retry" (SPEC 10) and re-dials once a minute, since a refused socket and an old protocol look the same from the page (LOOSE_ENDS E18).

### 6.15 PING (0x00FE) and PONG (0x00FF), 16 bytes

`<QQ` sequence, client_time_us. The server echoes the PING payload unchanged as PONG. Clients compute RTT from `client_time_us`.

---

## 7. Identity: the HANDSHAKE name

`name = "<role>;<clientId>;<label>"`

| Part | Values | Notes |
|---|---|---|
| role | `web`, `ink` (the native app's canvas), `overlay` (the native app's pills service), `test` (the Mac's self-test and Playwright fake clients) | decides which messages are honoured (section 9) |
| clientId | a UUID string the client generates once and stores forever (web: `localStorage["daylight.clientId"]`; Android: SharedPreferences `clientId`, shared by `ink` and `overlay`) | the key of the Mac's allow-list |
| label | human text, <= 64 UTF-8 bytes, e.g. `Chrome on Daylight`, `Mike’s DC-1` | shown in the Allow panel and Settings |

Rules: the `overlay` role reuses the SAME clientId as the `ink` role of the same tablet, so the pills are auto-allowed once the canvas was allowed and never count as a second tablet. A name without two semicolons is rejected with ACK status 3.

---

## 8. Connection sequence and the Allow handshake

```
Client                                   Mac
  |-- WebSocket upgrade GET /ink -------->|   (Sec-WebSocket-Protocol: solstream.v1 optional)
  |<-- 101 Switching Protocols -----------|
  |-- HANDSHAKE (<= 5 s) ---------------->|   lookup clientId in ClientRegistry
  |                                       |   allowed, or loopback remote (127.0.0.1 / ::1, i.e. adb reverse) with trustLoopback on,
  |                                       |   or role overlay with an allowed ink clientId:
  |<-- HANDSHAKE_ACK status 0 ------------|
  |<-- STATE (flags bit2 set) ------------|
  |-- ink / control ... ----------------->|
                                          |   unknown clientId over the network:
  |<-- HANDSHAKE_ACK status 1 ------------|   AllowClientPanel shown on the Mac (non-activating panel, 60 s auto-dismiss,
  |<-- STATE (bit2 clear) ----------------|   mirrored as a menu item "Allow <label>" while pending; the socket stays
  |   (ink decoded and DROPPED) ----------|   pending indefinitely: NO auto-deny on a timer)
  |<-- HANDSHAKE_ACK status 0 ------------|   owner clicked Allow: ClientRegistry remembers the id forever
  |<-- STATE (bit2 set) ------------------|
                                          |   owner clicked Not now:
  |<-- HANDSHAKE_ACK status 2 ------------|   then close 1008 (the client shows "Not allowed by the Mac" and retries only on user action)
```

A loopback connection sets `seenOverUSB = true` on the record and records it as allowed, so the same tablet connecting later over Wi-Fi with the same clientId needs no prompt. Exactly one ink client is "active" at a time per source: the most recently handshaken allowed `web` client when `inkSource == web`, the most recent allowed `ink` client when `inkSource == native`; others receive STATE with bit3 clear and their ink is dropped. `overlay` and `test` roles may send TOGGLE_PIN, CLEAR_CANVAS and AUTO_ENGAGE_RETURN in every ink source; `test` may send everything. A client demoted from active while a stroke is open may still send STROKE_CHUNK, STROKE_COMMIT and STROKE_CANCEL for its own open stroke ids, so the stroke ends and the governor contact is released; new ink from it is dropped.

Loopback is judged by the TCP peer address and the Origin header together: a loopback socket whose upgrade request carries an `Origin` whose host and port differ from its `Host` header (a web page from another site in a browser on the Mac) is treated as a network client and goes through the Allow panel. A request without `Origin` (Daylight Ink, the self-test) is judged by the peer address alone. Role `test` is accepted only from a loopback socket; from any other it gets HANDSHAKE_ACK 3 and close 1002.

The owner's Allow is recorded by clientId: clicking Allow after the pending socket closed still writes the registry, and a redial of the same clientId that is pending gets status 0.

---

## 9. Server validation policy (one table)

| Condition | Action |
|---|---|
| bad magic or version | close 1002 |
| payload_len mismatch, truncated payload, wrong fixed size for a known opcode | drop message, log once per connection |
| unknown opcode | ignore, log once per opcode |
| STROKE_CHUNK count 0 or > 4096; ERASE_STROKES count > 1024; HANDSHAKE name_len 0 or > 200 after the connection has an identity | drop message, log |
| a first HANDSHAKE that does not decode (name_len 0 or > 200, short payload, payload_len mismatch) | HANDSHAKE_ACK 3, close 1002 |
| payload > 1 MiB or WebSocket frame > 2 MiB | close 1009 |
| no HANDSHAKE within 5 s, or a non-HANDSHAKE first | close 1002 |
| ink from a pending client | decode and drop (bounded cost), STATE keeps flowing |
| ink from a denied client | close 1008 |
| ink from a non-active source (bit3 clear) | drop silently; STATE tells the client why |
| 30 s without any frame | close 1001 |

---

## 10. Versioning

- `version` byte 0x01 is the only accepted value in v1. A future incompatible layout bumps it to 0x02; the server then answers HANDSHAKE_ACK status 3 to a 0x01 client only if it cannot speak 0x01 any more.
- Compatible additions (new opcodes, new flag bits, longer STATE with appended fields) keep 0x01. Clients MUST ignore unknown opcodes and unknown flag bits, and MUST accept a STATE longer than 20 bytes by reading the first 20.
- The golden manifest carries `"version": 1`; each client's test asserts it.

---

## 11. Encoding rules per client

- Swift (`DaylightKit/Protocol`): `ByteReader` / `ByteWriter` assemble bytes (no `load(fromByteOffset:)` on unaligned offsets); `Float(bitPattern:)` for f32; `Codec.encode(_:timestampUs:into:)` appends into a reusable `[UInt8]`; `Codec.decode(_:)` returns `(Header, Message)` and `Codec.decodeLenient` returns `(Header, Message?)` with `nil` for an unknown opcode.
- TypeScript (`web/src/protocol.ts`): `DataView` with `littleEndian = true` on EVERY multi-byte call, `setBigUint64` / `getBigUint64` with `BigInt`; one 64 KiB scratch `ArrayBuffer` per connection, `slice(0, len)` on send; UUID bytes from `crypto.randomUUID()` when it exists, else `crypto.getRandomValues(new Uint8Array(16))` with the version (byte 6 = `0x40 | (b & 0x0f)`) and variant (byte 8 = `0x80 | (b & 0x3f)`) bits set; `ws.binaryType = "arraybuffer"` before the first message.
- Kotlin (`android/.../protocol/SolStream.kt`): one `ByteBuffer.allocateDirect(65536).order(ByteOrder.LITTLE_ENDIAN)` per connection; UUIDs through a 16-byte BIG-endian temporary (`putLong(msb); putLong(lsb)`), then copied; frames sent as `ByteArray.toByteString(0, len)`; `TCP_NODELAY` through a `SocketFactory` (OkHttp leaves Nagle on).
- All: clamp pressure to [0, 1] before quantising; never emit STROKE_START for a pointerdown or ACTION_DOWN with pressure 0 (that is a side-button press in the air on the DC-1).

---

## 12. Golden test vectors

Generated by `protocol/gen_golden.py` (Python 3 `struct`, formats copied from `solstream_wire.py`, plus `<16sQ` for UNDO/REDO and `<BBBBfIHHHH` for STATE) into `protocol/golden/solstream-v1.json`, which `make golden` copies to `mac/DaylightKit/Tests/DaylightKitTests/Resources/solstream-v1.json`, `web/tests/golden/solstream-v1.json` and `android/app/src/test/resources/solstream-v1.json`. `make golden-check` regenerates to a temp file and diffs all four copies. The mirror stream family (section 14) adds a second array `mirror_cases`; the v1 `cases` array is unchanged.

Fixed inputs: `timestamp_us = 1760000000123456` (`40e2cfeeb5400600` on the wire), `stroke_id = 00010203-0405-0607-0809-0a0b0c0d0e0f`, `page_id = 10111213-1415-1617-1819-1a1b1c1d1e1f`, `clientId = 6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b`, handshake name `web;6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b;Mike’s DC-1` (the apostrophe is U+2019, 3 bytes, pinning UTF-8: 68 bytes total), points `(10.5, -3.25, 0.73, 0)`, `(100.0, 200.25, 0.2, 8)`, `(1199.96875, 1599.0, 1.0, 70000 -> 65535)`.

Manifest shape:

```json
{ "version": 1, "generator": "gen_golden.py", "timestamp_us": 1760000000123456,
  "stroke_id": "00010203-0405-0607-0809-0a0b0c0d0e0f", "page_id": "10111213-1415-1617-1819-1a1b1c1d1e1f",
  "cases": [ { "name": "stroke_chunk_3pts", "opcode": 17, "direction": "c2s", "decode_only": false,
               "fields": { "stroke_id": "...", "points": [ { "x": 10.5, "y": -3.25, "pressure": 0.73, "delta_ms": 0 }, ... ] },
               "hex": "da0111...", "note": "..." }, ... ] }
```

Test contract: Swift decodes every case to the expected fields (f32 tolerance 1e-6, pressure compared after quantisation) and re-encodes every non-`decode_only` case byte-equal. TypeScript and Kotlin encode every `c2s` non-`decode_only` case from `fields` and compare hex, and decode every `s2c` case. The Mac `--self-test` and `WebServerLoopbackTests` send `handshake`, `stroke_start`, `stroke_chunk_3pts`, `stroke_commit` through a real socket and expect `handshake_ack_ok` (bytes 16 to 31 equal; the header timestamp differs) and a STATE with governor 1.

### 12.1 Vectors (full frames, header included)

| Case | Opcode | Dir | Hex |
|---|---|---|---|
| handshake | 0x0001 | c2s | `da0101004400000040e2cfeeb5400600000096440000c8440000484336007765623b36663161326233632d346435652d346636302d386139622d3063316432653366346135623b4d696b65e28099732044432d31` |
| handshake_ack_ok | 0x0002 | s2c | `da0102001000000040e2cfeeb540060080070000380400001e00000000000000` |
| handshake_ack_pending | 0x0002 | s2c | `da0102001000000040e2cfeeb540060080070000380400001e00000001000000` |
| stroke_start | 0x0010 | c2s | `da0110001f00000040e2cfeeb5400600000102030405060708090a0b0c0d0e0f00111111ffcdcc4c40000148e13a3f` |
| stroke_start_highlighter | 0x0010 | c2s | `da0110001f00000040e2cfeeb5400600000102030405060708090a0b0c0d0e0f010677d9800000404100010000003f` |
| stroke_start_legacy25 (decode only) | 0x0010 | c2s | `da0110001900000040e2cfeeb5400600000102030405060708090a0b0c0d0e0f00111111ffcdcc4c40` |
| stroke_chunk_3pts | 0x0011 | c2s | `da0111003300000040e2cfeeb5400600000102030405060708090a0b0c0d0e0f03005001000098ffffffba0000800c000008190000330800ff950000e0c70000ffffff` |
| stroke_commit | 0x0012 | c2s | `da0112001400000040e2cfeeb5400600000102030405060708090a0b0c0d0e0f03000000` |
| stroke_cancel | 0x0013 | c2s | `da0113001000000040e2cfeeb5400600000102030405060708090a0b0c0d0e0f` |
| undo | 0x0014 | c2s | `da0114001800000040e2cfeeb5400600101112131415161718191a1b1c1d1e1f40e2cfeeb5400600` |
| redo | 0x0015 | c2s | `da0115001800000040e2cfeeb5400600101112131415161718191a1b1c1d1e1f40e2cfeeb5400600` |
| undo_current_page | 0x0014 | c2s | `da0114001800000040e2cfeeb54006000000000000000000000000000000000040e2cfeeb5400600` |
| erase_strokes | 0x0020 | c2s | `da0120002600000040e2cfeeb54006000000c8420000c84200000c4300002043000040410100000102030405060708090a0b0c0d0e0f` |
| laser_point | 0x0030 | c2s | `da0130001000000040e2cfeeb540060000001644000048440000803f0000003f` |
| clear_canvas | 0x0040 | c2s | `da0140001800000040e2cfeeb5400600101112131415161718191a1b1c1d1e1f40e2cfeeb5400600` |
| clear_canvas_empty (decode only) | 0x0040 | c2s | `da0140000000000040e2cfeeb5400600` |
| page_change | 0x0050 | c2s | `da0150001c00000040e2cfeeb5400600101112131415161718191a1b1c1d1e1f000096440000c84402000000` |
| auto_engage_return | 0x0060 | c2s | `da0160000800000040e2cfeeb540060040e2cfeeb5400600` |
| toggle_pin_toggle | 0x0061 | c2s | `da0161000900000040e2cfeeb5400600ff40e2cfeeb5400600` |
| toggle_pin_on | 0x0061 | c2s | `da0161000900000040e2cfeeb54006000140e2cfeeb5400600` |
| toggle_pin_off | 0x0061 | c2s | `da0161000900000040e2cfeeb54006000040e2cfeeb5400600` |
| state_live_pinned | 0x0070 | s2c | `da0170001400000040e2cfeeb5400600020d00010000803fffffffff0000030003000000` |
| state_returning_prewarn | 0x0070 | s2c | `da0170001400000040e2cfeeb5400600033600000000003f6810000001000c000c000200` |
| state_passthrough_idle | 0x0070 | s2c | `da0170001400000040e2cfeeb540060000b4000200000000ffffffff0000000000000000` |
| ping | 0x00FE | c2s | `da01fe001000000040e2cfeeb5400600070000000000000040e2cfeeb5400600` |
| pong | 0x00FF | s2c | `da01ff001000000040e2cfeeb5400600070000000000000040e2cfeeb5400600` |

Field values behind the vectors: `stroke_start` = pen, color `0xFF111111`, base_width 3.2 (`cdcc4c40`), stylus, contact, pressure 0.73 (`48e13a3f`); `stroke_start_highlighter` = highlighter, `0x80D97706`, width 12.0, pressure 0.5; `erase_strokes` = (100, 100) to (140, 160), radius 12, one id (the stroke id); `laser_point` = (600, 800), intensity 1.0, decay 0.5 s; `page_change` = page id, 1200 x 1600, index 2; `state_live_pinned` = LIVE, flags `0x0D` (pinned, allowed, active source), auto, native, progress 1.0, no return, page 0, 3 strokes, undo 3, redo 0; `state_returning_prewarn` = RETURNING, flags `0x36` (pre_warning, allowed, camera_attached, sink_connected), auto, web, progress 0.5, 4200 ms, page 1, 12 strokes, undo 12, redo 2; `state_passthrough_idle` = PASSTHROUGH, flags `0xB4` (allowed, camera_attached, sink_connected, capture_idle; bit3 clear so this client is not the active source), auto, mirror; `ping`/`pong` sequence 7.

### 12.2 Annotated decomposition of `stroke_chunk_3pts`

```
da 01                      magic, version
11 00                      opcode 0x0011 STROKE_CHUNK
33 00 00 00                payload_len 51 = 18 + 3 * 11
40 e2 cf ee b5 40 06 00    timestamp_us 1760000000123456
00 01 02 ... 0e 0f         stroke_id (16 bytes, RFC 4122 order)
03 00                      count 3
50 01 00 00  98 ff ff ff  ba  00 00    x32 336 (10.5)   y32 -104 (-3.25)   p 186 (0.73)  dt 0
80 0c 00 00  08 19 00 00  33  08 00    x32 3200 (100.0) y32 6408 (200.25) p 51 (0.2)    dt 8
ff 95 00 00  e0 c7 00 00  ff  ff ff    x32 38399        y32 51168         p 255 (1.0)   dt 65535 (saturated from 70000)
```

### 12.3 WebSocket constants (also emitted into the manifest under `"websocket"`)

- `SHA1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d`
- `Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==` -> `Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=` (RFC 6455 section 1.3 sample, recomputed with Python `hashlib` + `base64`)
- GUID appended before hashing: `258EAFA5-E914-47DA-95CA-C5AB0DC85B11`

Both the pure-Swift SHA-1 (used on Linux) and CryptoKit `Insecure.SHA1` (used on macOS) must produce these; the macOS test asserts they agree.

---

## 13. Governor event mapping (server side, for reference)

| Message | Canvas | Governor event |
|---|---|---|
| STROKE_START | begin stroke (only if pointer 0, phase 1, pressure > 0) | `.contact(strokeID, pointer, phase, pressure, tool)` |
| STROKE_CHUNK | append points, draw new segments | `.motion(strokeID)` |
| STROKE_COMMIT | close stroke | `.lift(strokeID)` |
| STROKE_CANCEL | remove stroke, redraw dirty rect | `.cancel(strokeID)` |
| UNDO / REDO | undo / redo | `.activity` |
| ERASE_STROKES | hit test, remove, redraw dirty rect | `.activity` |
| LASER_POINT | nothing | `.activity` |
| CLEAR_CANVAS | save (if ink), clear both layers, clear undo | `.clear` |
| PAGE_CHANGE | save (if ink), new page | `.activity` |
| AUTO_ENGAGE_RETURN | nothing | `.returnNow` |
| TOGGLE_PIN_WHITEBOARD | nothing | `.pin(value)` |
| client disconnect | commit that client's open strokes as they stand | remove its ids from `activeContacts`; no state change |

Mirror mode produces the same governor events from `getevent` (SPEC section 8, engage detector column, and ARCHITECTURE section 6 item 7) and feeds no canvas. The Wi-Fi mirror transport (section 14) produces them from frame differencing when no USB pen watcher is available.

---

## 14. Mirror stream family (Wi-Fi mirror transport, LOOSE_ENDS A9)

A second mirror transport that needs neither USB debugging nor a cable: Daylight Ink captures the tablet screen with MediaProjection, encodes it with MediaCodec H.264 and sends it to the Mac over the SAME WebSocket connection it already holds (role `ink` or `overlay`, same clientId, same allow rule). The payloads carry the scrcpy 4.1 video-socket bytes unchanged (ARCHITECTURE 6 item 4), so the Mac feeds the concatenated payloads of one stream to its existing `ScrcpyDemuxer` (constructed with `expectsDummyByte: false`) and its existing `H264Decoder`.

Byte order: the SolStream header stays little-endian. The scrcpy parts (MIRROR_HELLO's codec id, the whole 12-byte MIRROR_PACKET header) are BIG-endian, exactly as scrcpy writes them. MIRROR_STATUS and MIRROR_CONTROL are ordinary little-endian SolStream payloads.

### 14.1 MIRROR_HELLO (0x0080), client to server, 68 bytes

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 64 | device_name | UTF-8 `Build.MODEL`, NUL-padded to 64 bytes, truncated to at most 63 bytes on a UTF-8 boundary (the scrcpy device meta) |
| 64 | 4 | codec_id | BIG-endian u32, `0x68323634` ("h264"); 0 and 1 keep their scrcpy meaning (disabled, configuration error) |

Starts a stream: the Mac discards any previous demuxer state for this connection and feeds these 68 bytes to a fresh `ScrcpyDemuxer(expectsDummyByte: false)`. Sent once per encoder start (Mac START, a rotation that restarts the encoder, an encoder error recovery).

### 14.2 MIRROR_PACKET (0x0081), client to server, 12 + n bytes

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 12 | scrcpy_header | either a session packet or a media packet header, BIG-endian, exactly as in scrcpy 4.1 |
| 12 | n | annex_b | Annex-B bytes of one access unit or of the codec config (SPS and PPS); absent for a session packet |

Session packet (n = 0): byte 0 = `0x80` (bit 7 set), bytes 1 to 3 = 0, bytes 4 to 7 width (u32 BE), bytes 8 to 11 height (u32 BE). Sent after MIRROR_HELLO and again whenever the encoder's output size changes (rotation, fallback size).

Media packet (n >= 1): bytes 0 to 7 `pts_flags` (u64 BE: bit 62 config, bit 61 key frame, low 61 bits PTS in microseconds from `MediaCodec.BufferInfo.presentationTimeUs`), bytes 8 to 11 `size` (u32 BE) which MUST equal n. Bit 63 is always 0 (so byte 0 bit 7 is clear and the packet is not a session packet).

Size limit: the SolStream payload cap (1 MiB, section 1) bounds n to 1,048,564. The tablet drops a larger access unit, requests a sync frame (`MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME`) and logs it; at the bit rates below a key frame is a few hundred KiB. Order: one MIRROR_HELLO, one session packet, one config packet, then key and delta frames, all on one socket in order.

Backpressure (tablet): before sending a non-key, non-config packet the tablet checks the OkHttp `WebSocket.queueSize()`; above 1 MiB queued it drops the packet, counts it, sets MIRROR_STATUS flags bit3 for the next report and requests a sync frame once the queue drains below 256 KiB (OkHttp closes a socket whose queue exceeds 16 MiB; this rule keeps the ink, pills and PING traffic flowing).

### 14.3 MIRROR_STATUS (0x0082), client to server, 16 bytes, `<BBHHHII`

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 1 | state | 0 IDLE (capable, not streaming), 1 CONSENT_NEEDED (the tablet shows its "Share screen" prompt or notification), 2 STARTING, 3 STREAMING, 4 PAUSED (projection held, encoder stopped by MIRROR_CONTROL STOP), 5 CONSENT_DENIED, 6 ENCODER_UNAVAILABLE (no H.264 encoder, or configure or start failed), 7 PROJECTION_ENDED (stopped on the tablet: the notification's Stop, the system's cast control, or the app), 8 UNSUPPORTED (this build or device cannot capture) |
| 1 | 1 | flags | bit0 projection_held; bit1 thermal_reduced (frame rate or bit rate lowered for heat); bit2 power_save (the system battery saver is on); bit3 backpressure (packets dropped since the previous report) |
| 2 | 2 | fps_x10 | u16, access units sent in the last second times 10 |
| 4 | 2 | width | u16, encoder output width (0 when not streaming) |
| 6 | 2 | height | u16 |
| 8 | 4 | bitrate_bps | u32, configured encoder bit rate |
| 12 | 4 | sent_bps | u32, MIRROR_PACKET bytes sent in the last second times 8 |

Cadence: once right after every HANDSHAKE_ACK status 0 with the CURRENT state (usually 0 IDLE; 4 PAUSED when a projection survived a Wi-Fi drop, so the next START streams with no new consent; 8 UNSUPPORTED when the tablet cannot capture). This first report announces the connection; the Mac only ever sends MIRROR_CONTROL to a connection that announced itself, and never sends START to one whose last state is 8, on every state change, and at 1 Hz while STREAMING or PAUSED. A tablet that never sends it is treated as not capable.

### 14.4 MIRROR_CONTROL (0x0071), server to client, 12 bytes, `<BBHIHH`

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 1 | command | 0 STOP (stop the encoder, keep the projection so the next START needs no new consent), 1 START, 2 REQUEST_KEY_FRAME, 3 RELEASE (stop and release the projection) |
| 1 | 1 | reserved | 0 |
| 2 | 2 | max_size | u16, long side in pixels; 0 = default 1600; clamped to 320...1600, rounded down to a multiple of 16 |
| 4 | 4 | bitrate_bps | u32; 0 = default 7,000,000; clamped to 1,000,000...8,000,000 |
| 8 | 2 | max_fps | u16; 0 = default 30; clamped to 1...30 |
| 10 | 2 | key_interval_ms | u16; 0 = default 2000; clamped to 500...10000 (`KEY_I_FRAME_INTERVAL` in seconds, rounded up) |

The parameter fields matter for START only; STOP, REQUEST_KEY_FRAME and RELEASE send zeros. START on a tablet that holds a projection resumes at once (state 2 then 3); without a projection the tablet asks for consent (state 1). START while STREAMING with different parameters restarts the encoder (a new MIRROR_HELLO follows).

### 14.5 Rules (Mac)

| Condition | Action |
|---|---|
| mirror-family message from a pending, denied or unhandshaken connection | dropped (denied: the usual close 1008 applies to ink only) |
| MIRROR_PACKET before any MIRROR_HELLO on that connection | dropped, logged once |
| media packet whose `size` differs from n, or a session packet with n > 0 | dropped, demuxer reset, REQUEST_KEY_FRAME sent (at most once per second) |
| MIRROR_HELLO from a second connection | the newest stream wins; the older connection gets STOP |
| no MIRROR_PACKET for 2 s while the last MIRROR_STATUS said STREAMING | status "stream stalled" (FailureText), REQUEST_KEY_FRAME, and again every 2 s |
| connection closed while streaming | the source keeps the last frame, status idle; START is sent again to the next capable connection while the transport is Wi-Fi and the ink source is mirror |

The tablet's encoder repeats the previous frame after 250 ms without screen updates (`MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER = 250000`), so a static screen still produces packets and the 2 s stall rule never fires on an idle page.

### 14.6 Golden vectors (manifest key `mirror_cases`)

The mirror family lives in its own manifest array `mirror_cases` (same case shape as `cases`) so the v1 `cases` list and every v1 test stay unchanged; `"version"` stays 1. The Kit `MirrorStream` codec and the Android `MirrorFraming` codec encode every non-`decode_only` case of their direction byte-equal and decode every case; the web client ignores the opcodes (unknown-opcode rule).

| Case | Opcode | Dir | Fields |
|---|---|---|---|
| mirror_hello | 0x0080 | c2s | device_name `DC-1`, codec_id `0x68323634` |
| mirror_packet_session | 0x0081 | c2s | session 1200 x 1600 |
| mirror_packet_config | 0x0081 | c2s | config, pts 0, Annex-B `0000000167428028da0280bf` + `0000000168ce3c80` |
| mirror_packet_key_frame | 0x0081 | c2s | key frame, pts 33333, Annex-B `0000000165888400ffaa` |
| mirror_packet_delta | 0x0081 | c2s | delta frame, pts 66666, Annex-B `00000001419a020c` |
| mirror_status_streaming | 0x0082 | c2s | STREAMING, flags 0x01, fps_x10 300, 1200 x 1600, 7,000,000 bps, sent 6,543,210 bps |
| mirror_status_consent_denied | 0x0082 | c2s | CONSENT_DENIED, flags 0, zeros, 7,000,000 bps |
| mirror_control_start | 0x0071 | s2c | START, 1600, 7,000,000, 30, 2000 |
| mirror_control_stop | 0x0071 | s2c | STOP, zeros |
| mirror_control_key_frame | 0x0071 | s2c | REQUEST_KEY_FRAME, zeros |

The hex strings are in `protocol/golden/solstream-v1.json` under `mirror_cases` (generated; never typed by hand).
