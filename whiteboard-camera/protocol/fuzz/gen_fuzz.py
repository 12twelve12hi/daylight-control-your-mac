#!/usr/bin/env python3
"""SolStream-v1 cross-language fuzz corpus (protocol/fuzz/README.md).

Seeded and deterministic, Python 3 standard library only. The struct layouts come from protocol/gen_golden.py (imported,
so the oracle and the corpus can never disagree on a layout). The expected decision of every case is derived here from
docs/PROTOCOL.md (section 3 header rules, section 6 and 14 per-message rules, section 9 validation policy, section 10
versioning), never from a codec.
Usage: python3 protocol/fuzz/gen_fuzz.py [output-path]   (default: protocol/fuzz/corpus.json)
"""
import json, os, random, struct, sys, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True   # importing gen_golden must leave no __pycache__ in the tree
sys.path.insert(0, os.path.dirname(HERE))
import gen_golden as G  # noqa: E402  (struct layouts: G.H header, G.P point, G.STATE, G.MSTATUS, G.MCONTROL)

SEED = 0x50150F
PER_OPCODE = 12
MAX_PAYLOAD = 1 << 20
MIRROR_MAX_ANNEX_B = MAX_PAYLOAD - 12
I32_MIN, I32_MAX = -(1 << 31), (1 << 31) - 1

rng = random.Random(SEED)
cases = []
names = set()


def bits(n):
    return rng.getrandbits(n)


def below(n):
    return rng.getrandbits(32) % n


def f32(v):
    """The double that is exactly the binary32 nearest to v (so every codec reads the same value from JSON)."""
    return struct.unpack("<f", struct.pack("<f", v))[0]


def rand_f32():
    """A finite binary32: half realistic canvas values, half random bit patterns (no NaN or infinity, no -0)."""
    if bits(1):
        return f32((bits(24) / (1 << 24)) * 4000.0 - 1000.0)
    while True:
        v = struct.unpack("<f", struct.pack("<I", bits(32)))[0]
        if v == v and v not in (float("inf"), float("-inf")) and not (v == 0 and struct.pack("<f", v)[3] & 0x80):
            return v


def rand_uuid():
    return uuid.UUID(bytes=bytes(bits(8) for _ in range(16)))


def frame(op, payload, ts=None, magic=0xDA, version=1, length=None):
    ts = bits(64) if ts is None else ts
    return G.H.pack(magic, version, op, len(payload) if length is None else length, ts) + payload, ts


def add(name, kind, op, direction, data, expect, *, ts=0, layer=None, canonical=None, fields=None, pad=0,
        canonical_pad=None, encodable=True, note="", finding=None):
    assert name not in names, name
    names.add(name)
    c = dict(name=name, kind=kind, opcode=op, direction=direction, hex=data.hex(), expect=expect, timestamp_us=str(ts))
    if pad:
        c["pad"] = pad
    if expect == "reject":
        assert layer in ("header", "payload"), name
        c["layer"] = layer
    if expect == "accept":
        c["canonical"] = (data if canonical is None else canonical).hex()
        if canonical_pad is not None and canonical_pad != pad:
            c["canonical_pad"] = canonical_pad
        c["fields"] = fields
        if direction == "c2s":
            c["encodable"] = encodable
    if finding:
        c["finding"] = finding
    if note:
        c["note"] = note
    cases.append(c)


def add_encode_reject(name, op, fields, note):
    assert name not in names, name
    names.add(name)
    cases.append(dict(name=name, kind="encode_reject", opcode=op, direction="c2s", expect="encode_reject", timestamp_us="0", fields=fields, note=note))


def ok(name, kind, op, direction, payload, fields, ts=None, **kw):
    data, ts = frame(op, payload, ts)
    add(name, kind, op, direction, data, "accept", ts=ts, fields=fields, **kw)
    return data, ts


def bad(name, kind, op, direction, data, layer, ts=0, **kw):
    add(name, kind, op, direction, data, "reject", ts=ts, layer=layer, **kw)


# ---- per-opcode payload builders: (payload bytes, canonical fields) --------------------------------------------------

def p_handshake(cw=None, ch=None, dpi=None, name=None):
    cw = rand_f32() if cw is None else cw
    ch = rand_f32() if ch is None else ch
    dpi = rand_f32() if dpi is None else dpi
    if name is None:
        label = "".join(rng.choice("abcdefghijklmnopqrstuvwxyz ’éß中😀;") for _ in range(below(20) + 1))
        name = f"{rng.choice(['web', 'ink', 'overlay', 'test'])};{rand_uuid()};{label}"
    nb = name.encode("utf-8")
    return struct.pack("<fffH", cw, ch, dpi, len(nb)) + nb, dict(canvas_width=cw, canvas_height=ch, dpi=dpi, name=name)


def p_ack(w=None, h=None, fps=None, status=None):
    v = [bits(32) if x is None else x for x in (w, h, fps)]
    status = below(4) if status is None else status
    return struct.pack("<IIII", *v, status), dict(target_width=v[0], target_height=v[1], target_fps=v[2], status=status)


def p_stroke_start(tool=None, pointer=0, phase=1, pressure=None):
    sid = rand_uuid()
    tool = below(4) if tool is None else tool
    color, width = bits(32), rand_f32()
    pressure = rand_f32() if pressure is None else pressure
    payload = struct.pack("<16sBIfBBf", sid.bytes, tool, color, width, pointer, phase, pressure)
    return payload, dict(stroke_id=str(sid), tool=tool, color=color, base_width=width, pointer_type=pointer, phase=phase, pressure=pressure)


def point_fields(x32, y32, p8, d):
    return [x32 / 32, y32 / 32, p8 / 255, d]


def p_chunk(points=None):
    sid = rand_uuid()
    if points is None:
        points = [(bits(24) - (1 << 23), bits(24) - (1 << 23), bits(8), bits(16)) for _ in range(below(40) + 1)]
    payload = struct.pack("<16sH", sid.bytes, len(points)) + b"".join(G.P.pack(*p) for p in points)
    return payload, dict(stroke_id=str(sid), points=[point_fields(*p) for p in points])


def p_commit():
    sid, n = rand_uuid(), bits(32)
    return struct.pack("<16sI", sid.bytes, n), dict(stroke_id=str(sid), point_count=n)


def p_cancel():
    sid = rand_uuid()
    return sid.bytes, dict(stroke_id=str(sid))


def p_page_time(zero=False):
    pid = uuid.UUID(int=0) if zero else rand_uuid()
    t = bits(64)
    return struct.pack("<16sQ", pid.bytes, t), dict(page_id=str(pid), client_time_us=str(t))


def p_erase(k=None):
    k = below(6) if k is None else k
    fs = [rand_f32() for _ in range(5)]
    ids = [rand_uuid() for _ in range(k)]
    payload = struct.pack("<fffffH", *fs, k) + b"".join(i.bytes for i in ids)
    return payload, dict(x1=fs[0], y1=fs[1], x2=fs[2], y2=fs[3], radius=fs[4], ids=[str(i) for i in ids])


def p_laser():
    fs = [rand_f32() for _ in range(4)]
    return struct.pack("<ffff", *fs), dict(x=fs[0], y=fs[1], intensity=fs[2], decay_s=fs[3])


def p_page_change():
    pid, w, h, i = rand_uuid(), rand_f32(), rand_f32(), bits(32)
    return struct.pack("<16sffI", pid.bytes, w, h, i), dict(page_id=str(pid), width=w, height=h, page_index=i)


def p_return():
    t = bits(64)
    return struct.pack("<Q", t), dict(client_time_us=str(t))


def p_pin(v=None):
    v = rng.choice([-1, 0, 1]) if v is None else v
    t = bits(64)
    return struct.pack("<bQ", v, t), dict(value=v, client_time_us=str(t))


STATE_KEYS = ("governor", "flags", "mode", "ink_source", "progress", "ms_to_return", "page_index", "stroke_count", "undo_depth", "redo_depth")


def p_state(**over):
    v = dict(governor=below(4), flags=bits(8), mode=below(4), ink_source=below(3), progress=rand_f32(),
             ms_to_return=rng.choice([bits(32), 0xFFFFFFFF, below(10000)]), page_index=bits(16), stroke_count=bits(16),
             undo_depth=bits(16), redo_depth=bits(16))
    v.update(over)
    return G.STATE.pack(*(v[k] for k in STATE_KEYS)), v


def p_ping():
    s, t = bits(64), bits(64)
    return struct.pack("<QQ", s, t), dict(sequence=str(s), client_time_us=str(t))


def p_control(command=None, reserved=0, **over):
    v = dict(command=below(4) if command is None else command, max_size=bits(16), bitrate_bps=bits(32), max_fps=bits(16), key_interval_ms=bits(16))
    v.update(over)
    return G.MCONTROL.pack(v["command"], reserved, v["max_size"], v["bitrate_bps"], v["max_fps"], v["key_interval_ms"]), v


def hello_name_bytes(name):
    """PROTOCOL 14.1: UTF-8, at most 63 bytes, cut on a scalar boundary."""
    out = b""
    for ch in name:
        e = ch.encode("utf-8")
        if len(out) + len(e) > 63:
            break
        out += e
    return out


def p_hello(name=None, codec=None):
    if name is None:
        name = "".join(rng.choice("ABCDEFGHIJ0123456789-_ é中😀") for _ in range(below(30) + 1))
    codec = G.H264 if codec is None and bits(1) else (bits(32) if codec is None else codec)
    nb = hello_name_bytes(name)
    return nb.ljust(64, b"\0") + struct.pack(">I", codec), dict(device_name=name, codec_id=codec)


def p_session(w=None, h=None):
    w = bits(32) if w is None else w
    h = bits(32) if h is None else h
    return struct.pack(">BxxxII", 0x80, w, h), dict(kind="session", width=w, height=h)


def p_media(pts_flags=None, annex=None):
    pts_flags = bits(63) if pts_flags is None else pts_flags   # bit 63 is always 0 (PROTOCOL 14.2)
    annex = bytes(bits(8) for _ in range(below(48) + 1)) if annex is None else annex
    return G.mpacket(pts_flags, annex), dict(kind="media", pts_flags=str(pts_flags), annex_b=annex.hex())


def p_status(**over):
    v = dict(state=below(9), flags=bits(8), fps_x10=bits(16), width=bits(16), height=bits(16), bitrate_bps=bits(32), sent_bps=bits(32))
    v.update(over)
    return G.MSTATUS.pack(v["state"], v["flags"], v["fps_x10"], v["width"], v["height"], v["bitrate_bps"], v["sent_bps"]), v


# Every opcode the corpus covers: (opcode, direction, short name, random payload builder).
OPCODES = [
    (0x0001, "c2s", "handshake", p_handshake),
    (0x0002, "s2c", "handshake_ack", p_ack),
    (0x0010, "c2s", "stroke_start", p_stroke_start),
    (0x0011, "c2s", "stroke_chunk", p_chunk),
    (0x0012, "c2s", "stroke_commit", p_commit),
    (0x0013, "c2s", "stroke_cancel", p_cancel),
    (0x0014, "c2s", "undo", p_page_time),
    (0x0015, "c2s", "redo", p_page_time),
    (0x0020, "c2s", "erase_strokes", p_erase),
    (0x0030, "c2s", "laser_point", p_laser),
    (0x0040, "c2s", "clear_canvas", p_page_time),
    (0x0050, "c2s", "page_change", p_page_change),
    (0x0060, "c2s", "auto_engage_return", p_return),
    (0x0061, "c2s", "toggle_pin", p_pin),
    (0x0070, "s2c", "state", p_state),
    (0x0071, "s2c", "mirror_control", p_control),
    (0x0080, "c2s", "mirror_hello", p_hello),
    (0x0081, "c2s", "mirror_packet", lambda: p_session() if below(4) == 0 else p_media()),
    (0x0082, "c2s", "mirror_status", p_status),
    (0x00FE, "c2s", "ping", p_ping),
    (0x00FF, "s2c", "pong", p_ping),
]
# Payload sizes a decoder accepts for the fixed-size opcodes (PROTOCOL 5); None = variable (own rules below).
FIXED = {0x0002: [16], 0x0010: [25, 31], 0x0012: [20], 0x0013: [16], 0x0014: [24], 0x0015: [24], 0x0030: [16],
         0x0040: [0, 24], 0x0050: [28], 0x0060: [8], 0x0061: [9], 0x0070: "min20", 0x0071: [12], 0x0080: [68],
         0x0082: [16], 0x00FE: [16], 0x00FF: [16]}

# ---- 1. random valid messages ---------------------------------------------------------------------------------------
for op, d, short, build in OPCODES:
    for i in range(PER_OPCODE):
        payload, fields = build()
        ok(f"{short}_random_{i:02d}", "valid", op, d, payload, fields)

# ---- 2. header-level invalid frames (section 3, section 9 rows 1 and 2) ---------------------------------------------
templates = {}
for op, d, short, build in OPCODES:
    payload, _ = build()
    templates[op] = (d, short, payload)
for op, (d, short, payload) in templates.items():
    data, ts = frame(op, payload)
    bad(f"{short}_bad_magic", "bad_magic", op, d, bytes([0xDB]) + data[1:], "header", ts)
    bad(f"{short}_version_0", "wrong_version", op, d, data[:1] + b"\x00" + data[2:], "header", ts)
    bad(f"{short}_version_2", "wrong_version", op, d, data[:1] + b"\x02" + data[2:], "header", ts)
    bad(f"{short}_len_plus_1", "length_mismatch", op, d, frame(op, payload, ts, length=len(payload) + 1)[0], "header", ts)
    if payload:
        bad(f"{short}_len_minus_1", "length_mismatch", op, d, frame(op, payload, ts, length=len(payload) - 1)[0], "header", ts)
        bad(f"{short}_truncated_last_byte", "truncated", op, d, data[:-1], "header", ts,
            note="payload_len still names the full payload")
    bad(f"{short}_len_ffffffff", "length_mismatch", op, d, frame(op, payload, ts, length=0xFFFFFFFF)[0], "header", ts)
    bad(f"{short}_header_only_15", "truncated", op, d, data[:15], "header", ts, note="shorter than the 16-byte header")
for n in (0, 1, 2, 4, 8):
    bad(f"short_frame_{n}_bytes", "truncated", 0x00FE, "c2s", bytes([0xDA, 0x01, 0xFE, 0x00, 0x10, 0x00, 0x00, 0x00])[:n], "header",
        note="no complete header")
bad("bad_magic_zero_frame", "bad_magic", 0x0000, "c2s", bytes(16), "header", note="16 zero bytes")
bad("bad_magic_text", "bad_magic", 0x0000, "c2s", b"GET /ink HTTP/1.1", "header", note="text, not SolStream")
bad("version_ff", "wrong_version", 0x00FE, "c2s", frame(0x00FE, p_ping()[0], 1, version=0xFF)[0], "header", 1)

# ---- 3. reserved and unknown opcodes (section 5 "Not defined" and reserved ranges; section 9 row 3, section 10) ----
UNKNOWN = [0x0000, 0x0003, 0x0004, 0x000F, 0x0016, 0x001F, 0x0021, 0x0031, 0x0041, 0x0051, 0x0062, 0x006F, 0x0072,
           0x007F, 0x0083, 0x008F, 0x0090, 0x00FD, 0x0100, 0x0101, 0x8001, 0xFFFF]
for op in UNKNOWN:
    for n in (0, 9):
        payload = bytes(bits(8) for _ in range(n))
        data, ts = frame(op, payload)
        add(f"unknown_op_{op:04x}_len{n}", "unknown_opcode", op, "c2s", data, "ignore", ts=ts)
    data, ts = frame(op, b"\x01\x02\x03")
    bad(f"unknown_op_{op:04x}_len_mismatch", "unknown_opcode", op, "c2s", frame(op, b"\x01\x02\x03", ts, length=4)[0], "header", ts,
        note="the header rules apply before the opcode is looked at")

# ---- 4. oversize (section 1 message cap, section 3 payload_len <= 1 MiB, section 9 row 5) ---------------------------
# The zero bytes are not stored: `pad` zero bytes follow the hex in every harness.
data, ts = frame(0x00FD, b"", length=MAX_PAYLOAD + 1)
add("oversize_unknown_op_1mib_plus_1", "oversize", 0x00FD, "c2s", data, "reject", ts=ts, layer="header", pad=MAX_PAYLOAD + 1, finding="FZ-1")
data, ts = frame(0x00FD, b"", length=MAX_PAYLOAD)
add("max_payload_unknown_op_1mib", "oversize", 0x00FD, "c2s", data, "ignore", ts=ts, pad=MAX_PAYLOAD)
st, sf = p_state()
data, ts = frame(0x0070, st, length=MAX_PAYLOAD + 1)
add("oversize_state_1mib_plus_1", "oversize", 0x0070, "s2c", data, "reject", ts=ts, layer="header", pad=MAX_PAYLOAD + 1 - 20, finding="FZ-1",
    note="a STATE longer than 20 bytes is a compatible addition, but not past the 1 MiB cap")
data, ts = frame(0x0070, st, length=MAX_PAYLOAD)
add("max_state_1mib", "oversize", 0x0070, "s2c", data, "accept", ts=ts, pad=MAX_PAYLOAD - 20, canonical=frame(0x0070, st, ts)[0],
    canonical_pad=0, fields=sf, note="read the first 20 bytes (PROTOCOL 10)")
pk, pf = p_media(pts_flags=1 << 61, annex=b"")
hdr = struct.pack(">QI", 1 << 61, MIRROR_MAX_ANNEX_B)
data, ts = frame(0x0081, hdr, length=MAX_PAYLOAD)
add("mirror_packet_max_annex_b", "oversize", 0x0081, "c2s", data, "accept", ts=ts, pad=MIRROR_MAX_ANNEX_B,
    fields=dict(kind="media", pts_flags=str(1 << 61), annex_b_zero_bytes=MIRROR_MAX_ANNEX_B), encodable=True,
    note="n = 1,048,564 zero bytes (annex_b_zero_bytes) is the largest media packet")
hdr = struct.pack(">QI", 1 << 61, MIRROR_MAX_ANNEX_B + 1)
data, ts = frame(0x0081, hdr, length=MAX_PAYLOAD + 1)
add("mirror_packet_oversize", "oversize", 0x0081, "c2s", data, "reject", ts=ts, layer="header", pad=MIRROR_MAX_ANNEX_B + 1, finding="FZ-1")

# ---- 5. per-message boundaries ---------------------------------------------------------------------------------------
def fixed_size_variants(op, d, short, payload, fields, sizes):
    """Wrong payload sizes with a consistent payload_len (section 9 row 2: wrong fixed size for a known opcode)."""
    ts = bits(64)
    for n in sorted({0, 1, len(payload) - 1, len(payload) + 1, len(payload) + 7} - {len(payload)}):
        body = (payload + bytes(8))[:n] if n > len(payload) else payload[:n]
        if n > len(payload):
            body = payload + bytes(bits(8) for _ in range(n - len(payload)))
        if sizes == "min20":
            if n >= 20:
                add(f"{short}_payload_{n}", "longer_state", op, d, frame(op, body, ts)[0], "accept", ts=ts,
                    canonical=frame(op, body[:20], ts)[0], fields=fields, note="STATE longer than 20 bytes: read the first 20")
            else:
                bad(f"{short}_payload_{n}", "wrong_size", op, d, frame(op, body, ts)[0], "payload", ts)
        elif n in sizes:
            continue   # an alternative accepted size (25-byte STROKE_START, 0-byte CLEAR_CANVAS) has its own cases
        else:
            bad(f"{short}_payload_{n}", "wrong_size", op, d, frame(op, body, ts)[0], "payload", ts)


for op, d, short, build in OPCODES:
    if op in FIXED:
        payload, fields = build()
        fixed_size_variants(op, d, short, payload, fields, FIXED[op])

# HANDSHAKE (6.1, 7, 9): name_len 1..200, exact remaining bytes, UTF-8.
for n in (1, 63, 64, 199, 200):
    nm = ("web;" + "a" * 200)[:n]
    p, f = p_handshake(f32(1200.0), f32(1600.0), f32(200.0), nm)
    ok(f"handshake_name_len_{n}", "boundary", 0x0001, "c2s", p, f)
nm = "ink;" + "€" * 65 + "ab"   # 4 + 195 + 2 = 201 bytes
nb = nm.encode()[:200]
p = struct.pack("<fffH", 1200.0, 1600.0, 200.0, 200) + nb
ok("handshake_name_200_multibyte", "boundary", 0x0001, "c2s", p, dict(canvas_width=1200.0, canvas_height=1600.0, dpi=200.0, name=nb.decode()))
for n in (0, 201, 0xFFFF):
    nb = b"w" * min(n, 201)
    data, ts = frame(0x0001, struct.pack("<fffH", 1200.0, 1600.0, 200.0, n) + nb)
    bad(f"handshake_name_len_{n}", "name_length", 0x0001, "c2s", data, "payload", ts)
data, ts = frame(0x0001, struct.pack("<fffH", 1200.0, 1600.0, 200.0, 10) + b"web;abc")
bad("handshake_name_len_exceeds_payload", "name_length", 0x0001, "c2s", data, "payload", ts)
data, ts = frame(0x0001, struct.pack("<fffH", 1200.0, 1600.0, 200.0, 3) + b"web;abc")
bad("handshake_trailing_bytes", "name_length", 0x0001, "c2s", data, "payload", ts)
data, ts = frame(0x0001, struct.pack("<fffH", 1200.0, 1600.0, 200.0, 0))
bad("handshake_payload_14_name_0", "name_length", 0x0001, "c2s", data, "payload", ts)
for i, n in enumerate((0, 13)):
    data, ts = frame(0x0001, struct.pack("<fffH", 1200.0, 1600.0, 200.0, 5)[:n])
    bad(f"handshake_short_payload_{n}", "truncated", 0x0001, "c2s", data, "payload", ts)
# Odd UTF-8 (section 2: strings are UTF-8). Valid oddities decode; invalid sequences do not.
for label, nm in [("emoji_4byte", "web;id;😀🎨"), ("bom", "web;id;﻿DC-1"), ("nul_inside", "web;id;a\x00b"),
                  ("u_fffd", "web;id;�"), ("u_10ffff", "web;id;\U0010ffff"), ("combining", "web;id;é")]:
    p, f = p_handshake(f32(1200.0), f32(1600.0), f32(200.0), nm)
    ok(f"handshake_utf8_{label}", "utf8", 0x0001, "c2s", p, f)
BAD_UTF8 = [("lone_continuation", b"\x80"), ("truncated_3byte", b"\xe2\x80"), ("overlong_slash", b"\xc0\xaf"),
            ("surrogate_d800", b"\xed\xa0\x80"), ("byte_ff", b"\xff"), ("above_10ffff", b"\xf4\x90\x80\x80"),
            ("f5_lead", b"\xf5\x80\x80\x80"), ("truncated_at_end", b"\xf0\x9f\x98")]
for label, raw in BAD_UTF8:
    nb = b"web;id;" + raw
    data, ts = frame(0x0001, struct.pack("<fffH", 1200.0, 1600.0, 200.0, len(nb)) + nb)
    bad(f"handshake_utf8_invalid_{label}", "utf8", 0x0001, "c2s", data, "payload", ts, finding="FZ-2",
        note="the name is not UTF-8: a first HANDSHAKE that does not decode gets ACK 3 (PROTOCOL 2, 9)")

# HANDSHAKE_ACK (6.2): status 0..3.
for s in range(4):
    p, f = p_ack(0, 0xFFFFFFFF, 30, s)
    ok(f"ack_status_{s}_extremes", "boundary", 0x0002, "s2c", p, f)
for s in (4, 0xFF, 0xFFFFFFFF):
    p, _ = p_ack(1920, 1080, 30, s)
    data, ts = frame(0x0002, p)
    bad(f"ack_status_{s}", "enum_range", 0x0002, "s2c", data, "payload", ts, finding="FZ-3",
        note="status is one of 0..3 (PROTOCOL 6.2)")

# STROKE_START (6.3): 31 or the legacy 25; enums tool 0..3, pointer 0..4, phase 0..3.
for t in range(4):
    p, f = p_stroke_start(tool=t, pressure=0.0 if t == 0 else 1.0)
    ok(f"stroke_start_tool_{t}", "boundary", 0x0010, "c2s", p, f)
for pt_ in range(5):
    for ph in range(4):
        if (pt_, ph) == (0, 1):
            continue
        p, f = p_stroke_start(pointer=pt_, phase=ph)
        ok(f"stroke_start_pointer{pt_}_phase{ph}", "boundary", 0x0010, "c2s", p, f, encodable=False,
           note="valid on the wire; clients never send pointer != 0 or phase != 1, so no client encoder can produce it")
for label, kw in [("tool_4", dict(tool=4)), ("tool_ff", dict(tool=255)), ("pointer_5", dict(pointer=5)), ("phase_4", dict(phase=4))]:
    p, _ = p_stroke_start(**kw)
    data, ts = frame(0x0010, p)
    bad(f"stroke_start_{label}", "enum_range", 0x0010, "c2s", data, "payload", ts)
sid = rand_uuid()
legacy = struct.pack("<16sBIf", sid.bytes, 1, 0x80D97706, f32(12.0))
data, ts = frame(0x0010, legacy)
canon = frame(0x0010, struct.pack("<16sBIfBBf", sid.bytes, 1, 0x80D97706, f32(12.0), 0, 1, 0.5), ts)[0]
add("stroke_start_legacy25", "legacy", 0x0010, "c2s", data, "accept", ts=ts, canonical=canon,
    fields=dict(stroke_id=str(sid), tool=1, color=0x80D97706, base_width=12.0, pointer_type=0, phase=1, pressure=0.5),
    note="the oracle's 25-byte form is stylus, contact, pressure 0.5; the canonical form is 31 bytes")
legacy26 = struct.pack("<16sHIf", sid.bytes, 1, 0xFF111111, f32(3.2))
data, ts = frame(0x0010, legacy26)
bad("stroke_start_legacy26", "legacy", 0x0010, "c2s", data, "payload", ts, note="the oracle's 26-byte <16sHIf form is rejected (PROTOCOL 6.3)")

# STROKE_CHUNK (4, 6.4): count 1..4096, boundary coordinates, pressure 0 and 255, delta saturation.
CORNERS = [(I32_MIN, I32_MAX), (I32_MAX, I32_MIN), (0, 0), (-1, 1), (1200 * 32, 1600 * 32), (1200 * 32 - 1, 1600 * 32 - 1),
           (-32, -32), (1200 * 32 + 32, 1600 * 32 + 32), (I32_MIN, I32_MIN), (I32_MAX, I32_MAX)]
for i, (x, y) in enumerate(CORNERS):
    p, f = p_chunk([(x, y, 0, 0), (x, y, 255, 65535), (x, y, 128, 1)])
    ok(f"stroke_chunk_corner_{i}", "boundary", 0x0011, "c2s", p, f, note=f"x32 {x}, y32 {y}; pressure 0, 255, 128; delta 0, 65535, 1")
p, f = p_chunk([(0, 0, 0, 0)])
ok("stroke_chunk_one_point", "boundary", 0x0011, "c2s", p, f)
sid = rand_uuid()
data, ts = frame(0x0011, struct.pack("<16sH", sid.bytes, 4096), length=18 + 11 * 4096)
add("stroke_chunk_4096_points", "boundary", 0x0011, "c2s", data, "accept", ts=ts, pad=11 * 4096,
    fields=dict(stroke_id=str(sid), points=[[0.0, 0.0, 0.0, 0]], points_repeat=4096), note="4096 zero points (pad)")
data, ts = frame(0x0011, struct.pack("<16sH", sid.bytes, 4097), length=18 + 11 * 4097)
add("stroke_chunk_4097_points", "boundary", 0x0011, "c2s", data, "reject", ts=ts, layer="payload", pad=11 * 4097)
data, ts = frame(0x0011, struct.pack("<16sH", sid.bytes, 0))
bad("stroke_chunk_zero_points", "zero_points", 0x0011, "c2s", data, "payload", ts, note="count 0: dropped (PROTOCOL 6.4)")
data, ts = frame(0x0011, struct.pack("<16sH", sid.bytes, 0) + G.P.pack(1, 2, 3, 4))
bad("stroke_chunk_count0_with_point", "zero_points", 0x0011, "c2s", data, "payload", ts)
data, ts = frame(0x0011, struct.pack("<16sH", sid.bytes, 2) + G.P.pack(1, 2, 3, 4))
bad("stroke_chunk_count_exceeds_points", "wrong_size", 0x0011, "c2s", data, "payload", ts)
data, ts = frame(0x0011, struct.pack("<16sH", sid.bytes, 1) + G.P.pack(1, 2, 3, 4) + b"\x00")
bad("stroke_chunk_trailing_byte", "wrong_size", 0x0011, "c2s", data, "payload", ts)
for n in (0, 17):
    data, ts = frame(0x0011, struct.pack("<16sH", sid.bytes, 1)[:n])
    bad(f"stroke_chunk_payload_{n}", "truncated", 0x0011, "c2s", data, "payload", ts)
# Client-side quantisation (2, 4): pressure clamps to [0, 1], delta saturates at 65535 and floors at 0.
sid = rand_uuid()
data, ts = frame(0x0011, struct.pack("<16sH", sid.bytes, 4) + G.P.pack(32, 64, 255, 65535) + G.P.pack(-32, -64, 0, 0)
                 + G.P.pack(16, 48, 255, 65535) + G.P.pack(0, 0, 0, 0))
add("stroke_chunk_encoder_clamps", "encode_clamp", 0x0011, "c2s", data, "accept", ts=ts,
    fields=dict(stroke_id=str(sid), points=[[1.0, 2.0, 1.5, 70000], [-1.0, -2.0, -0.25, -5], [0.5, 1.5, 3.0, 65536], [0.0, 0.0, 0.0, 0]]),
    note="fields are encoder inputs: pressure 1.5 and 3.0 clamp to 255, -0.25 to 0; delta 70000 and 65536 saturate, -5 floors at 0")

# STROKE_COMMIT, CANCEL, UNDO, REDO, CLEAR (6.5 to 6.10).
p, f = p_page_time(zero=True)
ok("undo_zero_page", "boundary", 0x0014, "c2s", p, f)
ok("redo_zero_page", "boundary", 0x0015, "c2s", p, f)
ok("clear_canvas_zero_page", "boundary", 0x0040, "c2s", p, f)
data, ts = frame(0x0040, b"")
add("clear_canvas_empty", "legacy", 0x0040, "c2s", data, "accept", ts=ts, canonical=frame(0x0040, bytes(24), ts)[0],
    fields=dict(page_id=str(uuid.UUID(int=0)), client_time_us="0"), note="0-byte form: current page, time 0; canonical is the 24-byte form")
sid = rand_uuid()
ok("stroke_commit_count_0", "boundary", 0x0012, "c2s", struct.pack("<16sI", sid.bytes, 0), dict(stroke_id=str(sid), point_count=0))
ok("stroke_commit_count_max", "boundary", 0x0012, "c2s", struct.pack("<16sI", sid.bytes, 0xFFFFFFFF), dict(stroke_id=str(sid), point_count=0xFFFFFFFF))
ok("stroke_cancel_ff_uuid", "boundary", 0x0013, "c2s", b"\xff" * 16, dict(stroke_id="ffffffff-ffff-ffff-ffff-ffffffffffff"))
p = struct.pack("<16sQ", b"\xff" * 16, (1 << 64) - 1)
ok("undo_max_time", "boundary", 0x0014, "c2s", p, dict(page_id="ffffffff-ffff-ffff-ffff-ffffffffffff", client_time_us=str((1 << 64) - 1)))

# ERASE_STROKES (6.8): K 0..1024.
p, f = p_erase(0)
ok("erase_strokes_no_ids", "boundary", 0x0020, "c2s", p, f)
fs = [f32(100.0), f32(100.0), f32(140.0), f32(160.0), f32(12.0)]
data, ts = frame(0x0020, struct.pack("<fffffH", *fs, 1024), length=22 + 16 * 1024)
add("erase_strokes_1024_ids", "boundary", 0x0020, "c2s", data, "accept", ts=ts, pad=16 * 1024,
    fields=dict(x1=fs[0], y1=fs[1], x2=fs[2], y2=fs[3], radius=fs[4], ids=[str(uuid.UUID(int=0))], ids_repeat=1024), note="1024 zero ids (pad)")
data, ts = frame(0x0020, struct.pack("<fffffH", *fs, 1025), length=22 + 16 * 1025)
add("erase_strokes_1025_ids", "boundary", 0x0020, "c2s", data, "reject", ts=ts, layer="payload", pad=16 * 1025)
data, ts = frame(0x0020, struct.pack("<fffffH", *fs, 2) + bytes(16))
bad("erase_strokes_count_exceeds_ids", "wrong_size", 0x0020, "c2s", data, "payload", ts)
data, ts = frame(0x0020, struct.pack("<fffffH", *fs, 0) + bytes(1))
bad("erase_strokes_trailing_byte", "wrong_size", 0x0020, "c2s", data, "payload", ts)
data, ts = frame(0x0020, struct.pack("<fffffH", *fs, 0)[:21])
bad("erase_strokes_payload_21", "truncated", 0x0020, "c2s", data, "payload", ts)

# Floats: extremes are legal values (no float field has a range rule in sections 6.1 to 6.11).
FEXT = [f32(3.4028234663852886e38), f32(-3.4028234663852886e38), f32(1.401298464324817e-45), f32(1.1754943508222875e-38), 0.0, f32(-1e-30)]
p = struct.pack("<ffff", *FEXT[:4])
ok("laser_point_float_extremes", "boundary", 0x0030, "c2s", p, dict(x=FEXT[0], y=FEXT[1], intensity=FEXT[2], decay_s=FEXT[3]))
pid = rand_uuid()
p = struct.pack("<16sffI", pid.bytes, FEXT[4], FEXT[5], 0xFFFFFFFF)
ok("page_change_extremes", "boundary", 0x0050, "c2s", p, dict(page_id=str(pid), width=FEXT[4], height=FEXT[5], page_index=0xFFFFFFFF))

# AUTO_ENGAGE_RETURN, TOGGLE_PIN (6.12, 6.13): value -1, 0, 1 only.
ok("auto_engage_return_zero", "boundary", 0x0060, "c2s", bytes(8), dict(client_time_us="0"))
for v in (-1, 0, 1):
    p, f = p_pin(v)
    ok(f"toggle_pin_{v}".replace("-", "minus"), "boundary", 0x0061, "c2s", p, f)
for v in (2, -2, 127, -128):
    data, ts = frame(0x0061, struct.pack("<bQ", v, 1))
    bad(f"toggle_pin_value_{v}".replace("-", "minus"), "enum_range", 0x0061, "c2s", data, "payload", ts)

# STATE (6.14, 10): enums governor 0..3, mode 0..3, ink_source 0..2; unknown flag bits are ignored (kept).
for label, kw in [("all_max_valid", dict(governor=3, flags=0xFF, mode=3, ink_source=2, progress=1.0, ms_to_return=0xFFFFFFFF,
                                         page_index=0xFFFF, stroke_count=0xFFFF, undo_depth=0xFFFF, redo_depth=0xFFFF)),
                  ("all_zero", dict(governor=0, flags=0, mode=0, ink_source=0, progress=0.0, ms_to_return=0, page_index=0,
                                    stroke_count=0, undo_depth=0, redo_depth=0)),
                  ("ms_to_return_fffffffe", dict(ms_to_return=0xFFFFFFFE)),
                  ("progress_out_of_range", dict(progress=f32(-2.5))),
                  ("progress_huge", dict(progress=FEXT[0]))]:
    p, f = p_state(**kw)
    ok(f"state_{label}", "state_boundary", 0x0070, "s2c", p, f)
for label, kw in [("governor_4", dict(governor=4)), ("governor_ff", dict(governor=255)), ("mode_4", dict(mode=4)),
                  ("ink_source_3", dict(ink_source=3)), ("ink_source_ff", dict(ink_source=255))]:
    p, _ = p_state(**kw)
    data, ts = frame(0x0070, p)
    bad(f"state_{label}", "state_boundary", 0x0070, "s2c", data, "payload", ts, finding="FZ-4",
        note="an enum value outside its PROTOCOL 6.14 range is not a v1 STATE (new values are not a compatible addition, PROTOCOL 10)")

# PING, PONG (6.15).
p = struct.pack("<QQ", (1 << 64) - 1, 0)
ok("ping_max_sequence", "boundary", 0x00FE, "c2s", p, dict(sequence=str((1 << 64) - 1), client_time_us="0"))
ok("pong_max_sequence", "boundary", 0x00FF, "s2c", p, dict(sequence=str((1 << 64) - 1), client_time_us="0"))

# MIRROR_CONTROL (14.4): command 0..3, reserved byte ignored (canonical 0).
for cmd in range(4):
    p, f = p_control(cmd, max_size=0xFFFF, bitrate_bps=0xFFFFFFFF, max_fps=0xFFFF, key_interval_ms=0xFFFF)
    ok(f"mirror_control_cmd_{cmd}_max_fields", "mirror_boundary", 0x0071, "s2c", p, f,
       note="decoders keep the raw fields; the 14.4 defaults and clamps are applied by the tablet, not by the codec")
p, f = p_control(1, reserved=0xFF)
data, ts = frame(0x0071, p)
add("mirror_control_reserved_ff", "mirror_boundary", 0x0071, "s2c", data, "accept", ts=ts, canonical=frame(0x0071, p[:1] + b"\0" + p[2:], ts)[0],
    fields=f, note="reserved byte ignored; the canonical encoding writes 0")
for cmd in (4, 0xFF):
    p, _ = p_control(cmd)
    data, ts = frame(0x0071, p)
    bad(f"mirror_control_cmd_{cmd}", "mirror_boundary", 0x0071, "s2c", data, "payload", ts, finding="FZ-5",
        note="command is one of 0..3 (PROTOCOL 14.4)")

# MIRROR_HELLO (14.1): 64-byte NUL-padded UTF-8 name (at most 63 bytes), BIG-endian codec id.
for label, nm, codec in [("empty_name", "", 0), ("name_63", "N" * 63, 1), ("name_multibyte_63", "中" * 21, G.H264),
                         ("codec_max", "DC-1", 0xFFFFFFFF), ("emoji", "😀" * 15, G.H264)]:
    p, f = p_hello(nm, codec)
    ok(f"mirror_hello_{label}", "mirror_boundary", 0x0080, "c2s", p, f)
p, f = p_hello("M" * 70, G.H264)
ok("mirror_hello_encoder_truncates_70", "encode_clamp", 0x0080, "c2s", p, f, note="encoder input 70 bytes: truncated to 63")
p, f = p_hello("x" * 62 + "é", G.H264)
ok("mirror_hello_encoder_cut_on_scalar", "encode_clamp", 0x0080, "c2s", p, f, note="62 + 2 bytes: the 2-byte scalar does not fit and is dropped whole")
raw = b"Y" * 64 + struct.pack(">I", G.H264)
data, ts = frame(0x0080, raw)
add("mirror_hello_64_bytes_no_nul", "mirror_boundary", 0x0080, "c2s", data, "accept", ts=ts,
    canonical=frame(0x0080, b"Y" * 63 + b"\0" + struct.pack(">I", G.H264), ts)[0], fields=dict(device_name="Y" * 64, codec_id=G.H264),
    note="deliberate exception to the closed-size rule: 14.1 says at most 63 name bytes, but the field is informational and "
         "scrcpy itself reads at most 63, so a 64-byte name is accepted and the canonical encoding keeps the first 63")
raw = b"DC-1\0garbage".ljust(64, b"\0") + struct.pack(">I", G.H264)
data, ts = frame(0x0080, raw)
add("mirror_hello_bytes_after_nul", "mirror_boundary", 0x0080, "c2s", data, "accept", ts=ts,
    canonical=frame(0x0080, b"DC-1".ljust(64, b"\0") + struct.pack(">I", G.H264), ts)[0], fields=dict(device_name="DC-1", codec_id=G.H264),
    note="the name ends at the first NUL; padding bytes are ignored and written as 0")
for label, rawname in BAD_UTF8:
    raw = (b"DC-" + rawname).ljust(64, b"\0") + struct.pack(">I", G.H264)
    data, ts = frame(0x0080, raw)
    bad(f"mirror_hello_utf8_invalid_{label}", "utf8", 0x0080, "c2s", data, "payload", ts, finding="FZ-2")

# MIRROR_PACKET (14.2): session (n = 0) or media (n >= 1, size == n).
for label, (w, h) in [("zero", (0, 0)), ("max", (0xFFFFFFFF, 0xFFFFFFFF)), ("portrait", (1200, 1600))]:
    p, f = p_session(w, h)
    ok(f"mirror_packet_session_{label}", "mirror_boundary", 0x0081, "c2s", p, f)
raw = bytes([0xFF, 1, 2, 3]) + struct.pack(">II", 800, 600)
data, ts = frame(0x0081, raw)
add("mirror_packet_session_dirty_bytes", "mirror_boundary", 0x0081, "c2s", data, "accept", ts=ts,
    canonical=frame(0x0081, struct.pack(">BxxxII", 0x80, 800, 600), ts)[0], fields=dict(kind="session", width=800, height=600),
    note="spec-ambiguous: 14.2 says bytes 1 to 3 are 0, scrcpy 4.1 uses byte 3 as its client_resized flag; byte 0 bit 7 makes "
         "it a session packet, the Mac re-encodes it (0x80 then three zeros), so the other bits are dropped harmlessly")
data, ts = frame(0x0081, struct.pack(">BxxxII", 0x80, 800, 600) + b"\x00")
bad("mirror_packet_session_with_payload", "mirror_boundary", 0x0081, "c2s", data, "payload", ts)
for label, flags in [("config_and_key", (1 << 62) | (1 << 61) | 5), ("pts_max", (1 << 61) - 1), ("all_flags_pts_max", (1 << 63) - 1)]:
    p, f = p_media(flags, b"\x00\x00\x00\x01\x65")
    ok(f"mirror_packet_{label}", "mirror_boundary", 0x0081, "c2s", p, f)
p, f = p_media(0, b"\x01")
ok("mirror_packet_one_byte", "mirror_boundary", 0x0081, "c2s", p, f)
data, ts = frame(0x0081, struct.pack(">QI", 5, 0))
bad("mirror_packet_media_empty", "mirror_boundary", 0x0081, "c2s", data, "payload", ts, note="a media packet has n >= 1")
data, ts = frame(0x0081, struct.pack(">QI", 5, 3) + b"\x01\x02")
bad("mirror_packet_size_field_too_big", "mirror_boundary", 0x0081, "c2s", data, "payload", ts)
data, ts = frame(0x0081, struct.pack(">QI", 5, 1) + b"\x01\x02")
bad("mirror_packet_size_field_too_small", "mirror_boundary", 0x0081, "c2s", data, "payload", ts)
for n in (0, 11):
    data, ts = frame(0x0081, struct.pack(">QI", 5, 0)[:n])
    bad(f"mirror_packet_payload_{n}", "truncated", 0x0081, "c2s", data, "payload", ts)

# MIRROR_STATUS (14.3): state 0..8; unknown flag bits kept.
for s in range(9):
    p, f = p_status(state=s, flags=0xFF if s == 8 else s)
    ok(f"mirror_status_state_{s}", "mirror_boundary", 0x0082, "c2s", p, f)
p, f = p_status(state=3, flags=0xFF, fps_x10=0xFFFF, width=0xFFFF, height=0xFFFF, bitrate_bps=0xFFFFFFFF, sent_bps=0xFFFFFFFF)
ok("mirror_status_max_fields", "mirror_boundary", 0x0082, "c2s", p, f)
for s in (9, 0xFF):
    p, _ = p_status(state=s)
    data, ts = frame(0x0082, p)
    bad(f"mirror_status_state_{s}", "mirror_boundary", 0x0082, "c2s", data, "payload", ts, note="state is one of 0..8 (PROTOCOL 14.3)")

# ---- 6. encoder refusals: fields a client encoder must not turn into a frame (6.1, 6.4, 6.8, 14.2) -------------------
add_encode_reject("encode_handshake_name_empty", 0x0001, dict(canvas_width=1200.0, canvas_height=1600.0, dpi=200.0, name=""), "name_len 0")
add_encode_reject("encode_handshake_name_201", 0x0001, dict(canvas_width=1200.0, canvas_height=1600.0, dpi=200.0, name="web;" + "x" * 197), "name_len 201")
add_encode_reject("encode_handshake_name_201_multibyte", 0x0001, dict(canvas_width=1200.0, canvas_height=1600.0, dpi=200.0, name="ink;" + "€" * 65 + "ab"),
                  "201 UTF-8 bytes from 71 characters")
add_encode_reject("encode_stroke_chunk_no_points", 0x0011, dict(stroke_id=str(uuid.UUID(int=1)), points=[]), "count 0")
add_encode_reject("encode_stroke_chunk_4097_points", 0x0011, dict(stroke_id=str(uuid.UUID(int=1)), points=[[0.0, 0.0, 0.0, 0]], points_repeat=4097), "count 4097")
add_encode_reject("encode_erase_1025_ids", 0x0020, dict(x1=0.0, y1=0.0, x2=0.0, y2=0.0, radius=1.0, ids=[str(uuid.UUID(int=0))], ids_repeat=1025), "K 1025")
add_encode_reject("encode_mirror_packet_empty_media", 0x0081, dict(kind="media", pts_flags="0", annex_b=""), "a media packet has n >= 1")

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "corpus.json")
    doc = dict(version=1, generator="gen_fuzz.py", seed=SEED, per_opcode=PER_OPCODE, max_payload=MAX_PAYLOAD,
               opcodes=[op for op, _, _, _ in OPCODES], cases=cases)
    with open(out, "w", encoding="utf-8") as f:
        f.write("{\n")
        for k in ("version", "generator", "seed", "per_opcode", "max_payload", "opcodes"):
            f.write(f" {json.dumps(k)}: {json.dumps(doc[k])},\n")
        f.write(' "cases": [\n')
        f.write(",\n".join("  " + json.dumps(c, ensure_ascii=False, separators=(",", ":")) for c in cases))
        f.write("\n ]\n}\n")
    kinds = {}
    for c in cases:
        kinds[c["expect"]] = kinds.get(c["expect"], 0) + 1
    print(f"wrote {len(cases)} cases {kinds} to {out}")
