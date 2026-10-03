#!/usr/bin/env python3
"""SolStream-v1 golden vector oracle.

Regenerates protocol/golden/solstream-v1.json with Python struct (the same formats as the
prototype's solstream_wire.py, plus <16sQ for UNDO/REDO and <BBBBfIHHHH for STATE).
Usage: python3 protocol/gen_golden.py [output-path]   (default: protocol/golden/solstream-v1.json)
See docs/PROTOCOL.md section 12. No dependencies beyond the standard library.
"""
import os, sys
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "golden", "solstream-v1.json")
import struct, uuid, hashlib, base64, json
H = struct.Struct("<BBHIQ"); P = struct.Struct("<iiBH")
TS = 1760000000123456
SID = uuid.UUID("00010203-0405-0607-0809-0a0b0c0d0e0f")
PID = uuid.UUID("10111213-1415-1617-1819-1a1b1c1d1e1f")
CID = "6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b"
def frame(op, payload): return H.pack(0xDA, 1, op, len(payload), TS) + payload
def q8(p): return max(0, min(255, int(round(max(0.0, min(1.0, p)) * 255))))
def pt(x, y, p, d): return P.pack(int(round(x*32)), int(round(y*32)), q8(p), max(0, min(65535, d)))
pts = [(10.5, -3.25, 0.73, 0), (100.0, 200.25, 0.2, 8), (1199.96875, 1599.0, 1.0, 70000)]
cases = []
VERBOSE = "-v" in sys.argv
def add(name, op, direction, fields, payload, decode_only=False, note=""):
    b = frame(op, payload)
    cases.append(dict(name=name, opcode=op, direction=direction, fields=fields, hex=b.hex(), decode_only=decode_only, note=note))
    if VERBOSE: print(f"{name:28s} op=0x{op:04X} len={len(b):4d} payload={len(payload):3d}\n  {b.hex()}")
name = f"web;{CID};Mike’s DC-1"
nb = name.encode("utf-8")
add("handshake", 0x0001, "c2s", dict(canvas_width=1200.0, canvas_height=1600.0, dpi=200.0, name=name),
    struct.pack("<fffH", 1200.0, 1600.0, 200.0, len(nb)) + nb, note=f"name is {len(nb)} UTF-8 bytes (U+2019 apostrophe is 3 bytes)")
add("handshake_ack_ok", 0x0002, "s2c", dict(target_width=1920, target_height=1080, target_fps=30, status=0), struct.pack("<IIII", 1920, 1080, 30, 0))
add("handshake_ack_pending", 0x0002, "s2c", dict(target_width=1920, target_height=1080, target_fps=30, status=1), struct.pack("<IIII", 1920, 1080, 30, 1))
add("stroke_start", 0x0010, "c2s", dict(stroke_id=str(SID), tool=0, color=0xFF111111, base_width=3.2, pointer_type=0, phase=1, pressure=0.73),
    struct.pack("<16sBIfBBf", SID.bytes, 0, 0xFF111111, 3.2, 0, 1, 0.73))
add("stroke_start_highlighter", 0x0010, "c2s", dict(stroke_id=str(SID), tool=1, color=0x80D97706, base_width=12.0, pointer_type=0, phase=1, pressure=0.5),
    struct.pack("<16sBIfBBf", SID.bytes, 1, 0x80D97706, 12.0, 0, 1, 0.5))
add("stroke_start_legacy25", 0x0010, "c2s", dict(stroke_id=str(SID), tool=0, color=0xFF111111, base_width=3.2, pointer_type=0, phase=1, pressure=0.5),
    struct.pack("<16sBIf", SID.bytes, 0, 0xFF111111, 3.2), decode_only=True, note="oracle 25-byte form; decoders accept it as stylus/contact/0.5; nothing sends it")
add("stroke_chunk_3pts", 0x0011, "c2s", dict(stroke_id=str(SID), points=[dict(x=x, y=y, pressure=p, delta_ms=d) for (x,y,p,d) in pts]),
    struct.pack("<16sH", SID.bytes, 3) + b"".join(pt(*p) for p in pts), note="delta_ms is ms since the FIRST point of the stroke; 70000 saturates to 65535")
add("stroke_commit", 0x0012, "c2s", dict(stroke_id=str(SID), point_count=3), struct.pack("<16sI", SID.bytes, 3))
add("stroke_cancel", 0x0013, "c2s", dict(stroke_id=str(SID)), SID.bytes)
add("undo", 0x0014, "c2s", dict(page_id=str(PID), client_time_us=TS), struct.pack("<16sQ", PID.bytes, TS))
add("redo", 0x0015, "c2s", dict(page_id=str(PID), client_time_us=TS), struct.pack("<16sQ", PID.bytes, TS))
add("undo_current_page", 0x0014, "c2s", dict(page_id="00000000-0000-0000-0000-000000000000", client_time_us=TS), struct.pack("<16sQ", b"\0"*16, TS), note="all-zero page_id means the current page")
add("erase_strokes", 0x0020, "c2s", dict(x1=100.0, y1=100.0, x2=140.0, y2=160.0, radius=12.0, ids=[str(SID)]),
    struct.pack("<fffffH", 100.0, 100.0, 140.0, 160.0, 12.0, 1) + SID.bytes)
add("laser_point", 0x0030, "c2s", dict(x=600.0, y=800.0, intensity=1.0, decay_s=0.5), struct.pack("<ffff", 600.0, 800.0, 1.0, 0.5))
add("clear_canvas", 0x0040, "c2s", dict(page_id=str(PID), client_time_us=TS), struct.pack("<16sQ", PID.bytes, TS))
add("clear_canvas_empty", 0x0040, "c2s", dict(page_id=None, client_time_us=None), b"", decode_only=True, note="0-byte form accepted on decode; clients send the 24-byte form")
add("page_change", 0x0050, "c2s", dict(page_id=str(PID), width=1200.0, height=1600.0, page_index=2), struct.pack("<16sffI", PID.bytes, 1200.0, 1600.0, 2))
add("auto_engage_return", 0x0060, "c2s", dict(client_time_us=TS), struct.pack("<Q", TS))
add("toggle_pin_toggle", 0x0061, "c2s", dict(value=-1, client_time_us=TS), struct.pack("<bQ", -1, TS))
add("toggle_pin_on", 0x0061, "c2s", dict(value=1, client_time_us=TS), struct.pack("<bQ", 1, TS))
add("toggle_pin_off", 0x0061, "c2s", dict(value=0, client_time_us=TS), struct.pack("<bQ", 0, TS))
STATE = struct.Struct("<BBBBfIHHHH")
add("state_live_pinned", 0x0070, "s2c", dict(governor=2, flags=0x0D, mode=0, ink_source=1, progress=1.0, ms_to_return=0xFFFFFFFF, page_index=0, stroke_count=3, undo_depth=3, redo_depth=0),
    STATE.pack(2, 0x0D, 0, 1, 1.0, 0xFFFFFFFF, 0, 3, 3, 0), note="flags 0x0D = pinned | allowed | active_source")
add("state_returning_prewarn", 0x0070, "s2c", dict(governor=3, flags=0x36, mode=0, ink_source=0, progress=0.5, ms_to_return=4200, page_index=1, stroke_count=12, undo_depth=12, redo_depth=2),
    STATE.pack(3, 0x36, 0, 0, 0.5, 4200, 1, 12, 12, 2), note="flags 0x36 = pre_warning | allowed | camera_attached | sink_connected")
add("state_passthrough_idle", 0x0070, "s2c", dict(governor=0, flags=0xB4, mode=0, ink_source=2, progress=0.0, ms_to_return=0xFFFFFFFF, page_index=0, stroke_count=0, undo_depth=0, redo_depth=0),
    STATE.pack(0, 0xB4, 0, 2, 0.0, 0xFFFFFFFF, 0, 0, 0, 0), note="flags 0xB4 = allowed | camera_attached | sink_connected | capture_idle (bit3 clear: this client is not the active source)")
add("ping", 0x00FE, "c2s", dict(sequence=7, client_time_us=TS), struct.pack("<QQ", 7, TS))
add("pong", 0x00FF, "s2c", dict(sequence=7, client_time_us=TS), struct.pack("<QQ", 7, TS))
# Mirror stream family (PROTOCOL 14): its own array so the v1 `cases` list stays unchanged.
v1_cases = cases; cases = []
H264 = 0x68323634
def mpacket(pts_flags, annexb): return struct.pack(">QI", pts_flags, len(annexb)) + annexb
CONFIG = bytes.fromhex("0000000167428028da0280bf" + "0000000168ce3c80")
KEY = bytes.fromhex("0000000165888400ffaa")
DELTA = bytes.fromhex("00000001419a020c")
add("mirror_hello", 0x0080, "c2s", dict(device_name="DC-1", codec_id=H264), "DC-1".encode("utf-8").ljust(64, b"\0") + struct.pack(">I", H264),
    note="64-byte NUL-padded name then the BIG-endian codec id, exactly the scrcpy device meta and codec id")
add("mirror_packet_session", 0x0081, "c2s", dict(kind="session", width=1200, height=1600), struct.pack(">BxxxII", 0x80, 1200, 1600),
    note="scrcpy session packet: byte 0 bit 7 set, width and height u32 BIG-endian, no payload")
add("mirror_packet_config", 0x0081, "c2s", dict(kind="config", pts_us=0, key_frame=False, annex_b=CONFIG.hex()), mpacket(1 << 62, CONFIG),
    note="pts_flags bit 62 = config (SPS and PPS); size u32 BIG-endian equals the Annex-B length")
add("mirror_packet_key_frame", 0x0081, "c2s", dict(kind="frame", pts_us=33333, key_frame=True, annex_b=KEY.hex()), mpacket((1 << 61) | 33333, KEY),
    note="pts_flags bit 61 = key frame, low 61 bits PTS in microseconds")
add("mirror_packet_delta", 0x0081, "c2s", dict(kind="frame", pts_us=66666, key_frame=False, annex_b=DELTA.hex()), mpacket(66666, DELTA))
MSTATUS = struct.Struct("<BBHHHII")
add("mirror_status_streaming", 0x0082, "c2s", dict(state=3, flags=0x01, fps_x10=300, width=1200, height=1600, bitrate_bps=7000000, sent_bps=6543210),
    MSTATUS.pack(3, 0x01, 300, 1200, 1600, 7000000, 6543210), note="STREAMING, projection_held")
add("mirror_status_consent_denied", 0x0082, "c2s", dict(state=5, flags=0, fps_x10=0, width=0, height=0, bitrate_bps=7000000, sent_bps=0),
    MSTATUS.pack(5, 0, 0, 0, 0, 7000000, 0))
MCONTROL = struct.Struct("<BBHIHH")
add("mirror_control_start", 0x0071, "s2c", dict(command=1, max_size=1600, bitrate_bps=7000000, max_fps=30, key_interval_ms=2000),
    MCONTROL.pack(1, 0, 1600, 7000000, 30, 2000))
add("mirror_control_stop", 0x0071, "s2c", dict(command=0, max_size=0, bitrate_bps=0, max_fps=0, key_interval_ms=0), MCONTROL.pack(0, 0, 0, 0, 0, 0))
add("mirror_control_key_frame", 0x0071, "s2c", dict(command=2, max_size=0, bitrate_bps=0, max_fps=0, key_interval_ms=0), MCONTROL.pack(2, 0, 0, 0, 0, 0))
mirror_cases = cases; cases = v1_cases
if VERBOSE: print("\nSTATE size", STATE.size)
if VERBOSE: print("sha1(abc)", hashlib.sha1(b"abc").hexdigest())
key = "dGhlIHNhbXBsZSBub25jZQ=="
if VERBOSE: print("accept", base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode())
if VERBOSE: print("f32 3.2 ->", struct.pack("<f", 3.2).hex(), " 0.73 ->", struct.pack("<f", 0.73).hex(), " 12.0 ->", struct.pack("<f",12.0).hex(), " 0.5 ->", struct.pack("<f",0.5).hex())
if VERBOSE: print("q8(0.73)=", q8(0.73), "q8(0.2)=", q8(0.2))
websocket = dict(sha1_abc=hashlib.sha1(b"abc").hexdigest(), key=key, accept=base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode(), guid="258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(dict(version=1, generator="gen_golden.py", timestamp_us=TS, stroke_id=str(SID), page_id=str(PID), websocket=websocket, cases=cases, mirror_cases=mirror_cases), f, indent=1, ensure_ascii=False)
    f.write("\n")
print(f"wrote {len(cases)} cases and {len(mirror_cases)} mirror_cases to {OUT}")
