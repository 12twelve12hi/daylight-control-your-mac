package com.twelve.daylight.ink

import com.twelve.daylight.ink.protocol.Decoder
import com.twelve.daylight.ink.protocol.Encoder
import com.twelve.daylight.ink.protocol.ServerMessage
import com.twelve.daylight.ink.protocol.SolStream
import com.twelve.daylight.ink.protocol.WirePoint
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/** Golden vectors from protocol/golden/solstream-v1.json (docs/PROTOCOL.md section 12): encode every c2s case, decode every s2c case. */
class SolStreamTest {
    private val manifest: JSONObject = JSONObject(
        requireNotNull(javaClass.classLoader?.getResourceAsStream("solstream-v1.json")) { "golden manifest missing" }
            .readBytes().toString(Charsets.UTF_8)
    )
    private val ts = manifest.getLong("timestamp_us")
    private val strokeId = UUID.fromString(manifest.getString("stroke_id"))
    private val pageId = UUID.fromString(manifest.getString("page_id"))
    private val enc = Encoder { ts }

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    private fun unhex(s: String): ByteArray = ByteArray(s.length / 2) { i -> s.substring(i * 2, i * 2 + 2).toInt(16).toByte() }

    private fun cases(): List<JSONObject> {
        val arr = manifest.getJSONArray("cases")
        return (0 until arr.length()).map { arr.getJSONObject(it) }
    }

    private fun encodeCase(c: JSONObject): ByteArray? {
        val f = c.getJSONObject("fields")
        return when (c.getString("name")) {
            "handshake" -> enc.handshake(f.getDouble("canvas_width").toFloat(), f.getDouble("canvas_height").toFloat(), f.getDouble("dpi").toFloat(), f.getString("name"))
            "stroke_start", "stroke_start_highlighter" -> enc.strokeStart(strokeId, f.getInt("tool"), f.getLong("color").toInt(), f.getDouble("base_width").toFloat(), f.getDouble("pressure").toFloat())
            "stroke_chunk_3pts" -> {
                val pts = f.getJSONArray("points")
                enc.strokeChunk(strokeId, (0 until pts.length()).map {
                    val p = pts.getJSONObject(it)
                    WirePoint(p.getDouble("x").toFloat(), p.getDouble("y").toFloat(), p.getDouble("pressure").toFloat(), p.getInt("delta_ms"))
                })
            }
            "stroke_commit" -> enc.strokeCommit(strokeId, f.getInt("point_count"))
            "stroke_cancel" -> enc.strokeCancel(strokeId)
            "undo" -> enc.undo(pageId, ts)
            "redo" -> enc.redo(pageId, ts)
            "undo_current_page" -> enc.undo(null, ts)
            "erase_strokes" -> {
                val ids = f.getJSONArray("ids")
                enc.erase(f.getDouble("x1").toFloat(), f.getDouble("y1").toFloat(), f.getDouble("x2").toFloat(), f.getDouble("y2").toFloat(), f.getDouble("radius").toFloat(), (0 until ids.length()).map { UUID.fromString(ids.getString(it)) })
            }
            "laser_point" -> enc.laserPoint(f.getDouble("x").toFloat(), f.getDouble("y").toFloat(), f.getDouble("intensity").toFloat(), f.getDouble("decay_s").toFloat())
            "clear_canvas" -> enc.clear(pageId, ts)
            "page_change" -> enc.pageChange(pageId, f.getDouble("width").toFloat(), f.getDouble("height").toFloat(), f.getInt("page_index"))
            "auto_engage_return" -> enc.returnNow(ts)
            "toggle_pin_toggle", "toggle_pin_on", "toggle_pin_off" -> enc.togglePin(f.getInt("value"), ts)
            "ping" -> enc.ping(f.getLong("sequence"), ts)
            else -> null
        }
    }

    @Test
    fun manifestIsVersionOneWithAllCases() {
        assertEquals(1, manifest.getInt("version"))
        assertEquals(26, cases().size)
    }

    @Test
    fun everyClientCaseEncodesByteForByte() {
        val c2s = cases().filter { it.getString("direction") == "c2s" && !it.getBoolean("decode_only") }
        assertTrue(c2s.size >= 18)
        for (c in c2s) {
            val bytes = encodeCase(c)
            assertNotNull("no encoder mapping for ${c.getString("name")}", bytes)
            assertEquals(c.getString("name"), c.getString("hex"), hex(bytes!!))
        }
    }

    @Test
    fun everyServerCaseDecodes() {
        for (c in cases().filter { it.getString("direction") == "s2c" }) {
            val f = c.getJSONObject("fields")
            val msg = Decoder.decode(unhex(c.getString("hex")))
            assertNotNull(c.getString("name"), msg)
            when (msg) {
                is ServerMessage.Ack -> {
                    assertEquals(f.getInt("target_width"), msg.ack.width)
                    assertEquals(f.getInt("target_height"), msg.ack.height)
                    assertEquals(f.getInt("target_fps"), msg.ack.fps)
                    assertEquals(f.getInt("status"), msg.ack.status)
                }
                is ServerMessage.State -> {
                    assertEquals(f.getInt("governor"), msg.state.governor)
                    assertEquals(f.getInt("flags"), msg.state.flags)
                    assertEquals(f.getInt("ink_source"), msg.state.inkSource)
                    assertEquals(f.getLong("ms_to_return"), msg.state.msToReturn)
                    assertEquals(f.getInt("undo_depth"), msg.state.undoDepth)
                    assertEquals(f.getInt("redo_depth"), msg.state.redoDepth)
                    assertEquals(f.getDouble("progress").toFloat(), msg.state.progress, 1e-6f)
                    assertEquals(f.getInt("flags") and 1 != 0, msg.state.pinned)
                }
                is ServerMessage.Pong -> {
                    assertEquals(f.getLong("sequence"), msg.sequence)
                    assertEquals(ts, msg.clientTimeUs)
                }
                else -> throw AssertionError("unexpected message for ${c.getString("name")}: $msg")
            }
        }
    }

    @Test
    fun uuidBytesAreRfc4122Order() {
        assertEquals("000102030405060708090a0b0c0d0e0f", hex(SolStream.uuidBytes(strokeId)))
        assertEquals(strokeId, SolStream.uuidFromBytes(SolStream.uuidBytes(strokeId)))
    }

    @Test
    fun badFramesAreRejected() {
        assertNull(Decoder.decode(ByteArray(3)))
        val bad = unhex(cases()[0].getString("hex"))
        bad[0] = 0
        assertNull(Decoder.decode(bad))
        val shortByOne = unhex(cases().first { it.getString("name") == "pong" }.getString("hex")).copyOf(31)
        assertNull(Decoder.decode(shortByOne))
    }

    /** A server frame with a correct header around [payload]. */
    private fun frame(opcode: Int, payload: ByteArray): ByteArray {
        val b = java.nio.ByteBuffer.allocate(SolStream.HEADER_LEN + payload.size).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        b.put(SolStream.MAGIC.toByte()).put(SolStream.VERSION.toByte()).putShort(opcode.toShort()).putInt(payload.size).putLong(ts)
        return b.put(payload).array()
    }

    private fun ackPayload(status: Int): ByteArray =
        java.nio.ByteBuffer.allocate(16).order(java.nio.ByteOrder.LITTLE_ENDIAN).putInt(1920).putInt(1080).putInt(30).putInt(status).array()

    private fun statePayload(governor: Int, mode: Int, inkSource: Int, size: Int = 20): ByteArray {
        val p = ByteArray(size)
        p[0] = governor.toByte(); p[2] = mode.toByte(); p[3] = inkSource.toByte()
        return p
    }

    @Test
    fun payloadLenAboveOneMiBIsRejectedInTheHeader() {
        // PROTOCOL 3: payload_len <= 1 MiB (FZ-1). Exactly 1 MiB is fine, one byte more is not, whatever the opcode.
        assertEquals(1_048_576, Decoder.MAX_PAYLOAD_LEN)
        val unknownAtCap = frame(0x00FD, ByteArray(1_048_576))
        assertNotNull(Decoder.header(unknownAtCap))
        assertTrue(Decoder.decode(unknownAtCap) is ServerMessage.Unknown)
        assertNull(Decoder.header(frame(0x00FD, ByteArray(1_048_577))))
        assertNull(Decoder.decode(frame(0x00FD, ByteArray(1_048_577))))
        // A STATE longer than 20 bytes is a compatible addition, but not past the cap.
        assertTrue(Decoder.decode(frame(SolStream.Op.STATE, statePayload(2, 0, 1, 1_048_576))) is ServerMessage.State)
        assertNull(Decoder.decode(frame(SolStream.Op.STATE, statePayload(2, 0, 1, 1_048_577))))
        // A payload_len with the top bit set (a negative Int) never decodes either.
        val negative = frame(0x00FD, ByteArray(0))
        negative[7] = 0x80.toByte()
        assertNull(Decoder.header(negative))
    }

    @Test
    fun ackStatusOutsideZeroToThreeDoesNotDecode() {
        // PROTOCOL 6.2 and 10 (FZ-3): Link maps such a frame to INCOMPATIBLE itself (LinkTest).
        for (status in 0..3) {
            val msg = Decoder.decode(frame(SolStream.Op.HANDSHAKE_ACK, ackPayload(status)))
            assertEquals(status, (msg as ServerMessage.Ack).ack.status)
        }
        for (status in listOf(4, 255, -1, Int.MIN_VALUE)) {   // -1 is u32 0xFFFFFFFF
            assertNull("status $status", Decoder.decode(frame(SolStream.Op.HANDSHAKE_ACK, ackPayload(status))))
        }
    }

    @Test
    fun stateEnumsOutOfRangeDoNotDecode() {
        // PROTOCOL 6.14 and 10 (FZ-4): governor 0..3, mode 0..3, ink_source 0..2.
        val top = Decoder.decode(frame(SolStream.Op.STATE, statePayload(3, 3, 2))) as ServerMessage.State
        assertEquals(listOf(3, 3, 2), listOf(top.state.governor, top.state.mode, top.state.inkSource))
        for ((g, m, i) in listOf(Triple(4, 0, 0), Triple(0xFF, 0, 0), Triple(0, 4, 0), Triple(0, 0xFF, 0), Triple(0, 0, 3), Triple(0, 0, 0xFF))) {
            assertNull("governor $g mode $m ink_source $i", Decoder.decode(frame(SolStream.Op.STATE, statePayload(g, m, i))))
            assertNull("longer STATE too", Decoder.decode(frame(SolStream.Op.STATE, statePayload(g, m, i, 24))))
        }
    }
}
