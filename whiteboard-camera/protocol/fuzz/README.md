# SolStream fuzz parity corpus

`gen_fuzz.py` (seeded, Python 3 standard library only) writes `corpus.json`: random valid messages for every opcode
plus structured invalid and boundary frames, each with the decision docs/PROTOCOL.md requires. It imports the struct
layouts from `../gen_golden.py`, so the corpus and the golden oracle share one definition of every layout.

- `make fuzz-corpus`: regenerate and copy into the three test trees (`mac/DaylightKit/Tests/DaylightKitTests/Resources/fuzz-corpus.json`, `web/tests/fuzz/corpus.json`, `android/app/src/test/resources/fuzz-corpus.json`).
- `make fuzz-check`: regenerate to a temp file and diff all four copies (golden CI job, after `make golden-check`).

## Case shape

`name`, `kind`, `opcode`, `direction`, `hex` (whole frame), optional `pad` (zero bytes appended to `hex`, so the 1 MiB
cases stay small), `expect`, `timestamp_us` (a decimal string, like every u64 field). `accept` cases add `canonical`
(the re-encoding; `canonical_pad` when its padding differs from `pad`) and `fields` (encoder inputs and decoded values;
f32 values are exact binary32 numbers, points are `[x, y, pressure, delta_ms]`, `points_repeat` and `ids_repeat`
repeat a list). `reject` cases add `layer`: `header` (magic, version, payload_len, the 1 MiB cap) or `payload`.

Decisions: `accept`, `reject` (dropped or closed per PROTOCOL 9), `ignore` (well-formed unknown or reserved opcode),
`encode_reject` (fields a client encoder must refuse). A codec that does not implement an opcode must `reject` a
header-layer reject and `ignore` everything else (PROTOCOL 5 and 10).

Kinds: `valid` (12 random per opcode), `bad_magic`, `wrong_version`, `length_mismatch`, `truncated`, `wrong_size`,
`longer_state`, `unknown_opcode`, `oversize`, `boundary` (int32 min and max, 0, canvas edges, pressure 0 and 255,
counts 1, 4096, 4097, 0 to 1024 and 1025 ids, name_len 0, 1, 200, 201), `zero_points`, `name_length`, `utf8`,
`enum_range`, `state_boundary`, `mirror_boundary`, `legacy` (25-byte STROKE_START, 0-byte CLEAR_CANVAS), `encode_clamp`
(encoder inputs that clamp or truncate), `encode_reject`.

Rule applied where the spec lists a closed set of values (ACK status, tool, pointer, phase, pin value, STATE governor,
mode and ink_source, MIRROR_STATUS state, MIRROR_CONTROL command): any other value does not decode. Flag bits outside
the defined ones are kept (PROTOCOL 10). Reserved and padding bytes are ignored and re-encoded as 0.

## Direction matrix

| Opcodes | Swift (DaylightKit) | TypeScript (web) | Kotlin (Daylight Ink) |
|---|---|---|---|
| v1 client to server (0x0001, 0x0010 to 0x0015, 0x0020 to 0x0061, 0x00FE) | decode + re-encode | encode | encode |
| v1 server to client (0x0002, 0x0070, 0x00FF) | decode + re-encode | decode | decode |
| mirror client to server (0x0080 to 0x0082) | decode + re-encode | ignore | encode |
| mirror server to client (0x0071) | decode + re-encode | ignore | decode |
| unknown and reserved | ignore | ignore | ignore |

Every harness checks every case: decisions for all frames, decoded fields for what it decodes, byte-exact encodes
from `fields` for what it encodes (skipping `encodable: false`, STROKE_START with pointer or phase other than stylus
and contact, which no client sends). Harnesses: `mac/DaylightKit/Tests/DaylightKitTests/Protocol/FuzzCorpusTests.swift`,
`web/tests/unit/fuzz.test.ts`, `android/app/src/test/kotlin/com/twelve/daylight/ink/FuzzCorpusTest.kt`.

PROTOCOL 15 (tablet facts) is HTTP JSON, not SolStream: only the Mac parses it (the page and the app only build it),
so there is no pair of codecs to compare and it is not in the corpus.

## Known expected failures

Each harness lists the cases its codec still gets wrong, with the finding id, and asserts they still diverge (so the
test turns red when the codec is fixed and the entry must go). Swift and TypeScript: none. Kotlin (`knownDivergent` in
`FuzzCorpusTest.kt`; fixes requested from the owner of the Android sources):

- FZ-1: no 1 MiB payload_len cap in `Decoder.header` (3 `oversize` cases).
- FZ-3: HANDSHAKE_ACK status outside 0..3 decodes (3 `ack_status_*` cases).
- FZ-4: STATE governor, mode or ink_source out of range decodes (5 `state_*` cases).
- FZ-5: MIRROR_CONTROL command outside 0..3 decodes (2 `mirror_control_cmd_*` cases).
