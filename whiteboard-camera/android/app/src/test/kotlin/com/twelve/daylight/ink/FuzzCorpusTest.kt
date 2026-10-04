package com.twelve.daylight.ink

import com.twelve.daylight.ink.protocol.Decoder
import com.twelve.daylight.ink.protocol.Encoder
import com.twelve.daylight.ink.protocol.MirrorFraming
import com.twelve.daylight.ink.protocol.MirrorStatusFields
import com.twelve.daylight.ink.protocol.ServerMessage
import com.twelve.daylight.ink.protocol.SolStream
import com.twelve.daylight.ink.protocol.WirePoint
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/**
 * Cross-language fuzz parity (protocol/fuzz/README.md): every case of fuzz-corpus.json through the Kotlin codec.
 * Daylight Ink encodes the client-to-server SolStream v1 messages (Encoder) and the mirror family (MirrorFraming), and
 * decodes HANDSHAKE_ACK, STATE, PONG and MIRROR_CONTROL (Decoder); every other opcode is one it ignores (PROTOCOL 5 and
 * 10), so for those the expected decision is "ignore" unless the header itself is bad.
 */
class FuzzCorpusTest {
    private val corpus: JSONObject = JSONObject(
        requireNotNull(javaClass.classLoader?.getResourceAsStream("fuzz-corpus.json")) { "fuzz corpus missing" }
            .readBytes().toString(Charsets.UTF_8)
    )

    private val decodes = setOf(SolStream.Op.HANDSHAKE_ACK, SolStream.Op.STATE, SolStream.Op.PONG, SolStream.Op.MIRROR_CONTROL)
    private val encodes = setOf(
        SolStream.Op.HANDSHAKE, SolStream.Op.STROKE_START, SolStream.Op.STROKE_CHUNK, SolStream.Op.STROKE_COMMIT,
        SolStream.Op.STROKE_CANCEL, SolStream.Op.UNDO, SolStream.Op.REDO, SolStream.Op.ERASE_STROKES, SolStream.Op.LASER_POINT,
        SolStream.Op.CLEAR_CANVAS, SolStream.Op.PAGE_CHANGE, SolStream.Op.AUTO_ENGAGE_RETURN, SolStream.Op.TOGGLE_PIN, SolStream.Op.PING,
        SolStream.Op.MIRROR_HELLO, SolStream.Op.MIRROR_PACKET, SolStream.Op.MIRROR_STATUS,
    )

    /**
     * Expected failures: cases where android/app/src/main disagrees with the corpus, each with its finding id. The
     * fixes are requested from the owner of the Android sources. The test asserts each of these STILL diverges, so it
     * turns red when the codec is fixed; then delete the entry.
     */
    private val knownDivergent: Map<String, String> = emptyMap()   // FZ-1, FZ-3, FZ-4 and FZ-5 are fixed: none left

    private fun hex(bytes: ByteArray): String {
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            sb.append(Character.forDigit(v shr 4, 16)).append(Character.forDigit(v and 0xF, 16))
        }
        return sb.toString()
    }

    private fun bytes(hexString: String, pad: Int): ByteArray {
        val out = ByteArray(hexString.length / 2 + pad)
        for (i in 0 until hexString.length / 2) out[i] = hexString.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        return out
    }

    private fun cases(): List<JSONObject> {
        val arr = corpus.getJSONArray("cases")
        return (0 until arr.length()).map { arr.getJSONObject(it) }
    }

    private fun u64(f: JSONObject, k: String): Long = java.lang.Long.parseUnsignedLong(f.getString(k))
    private fun float(f: JSONObject, k: String): Float = f.getDouble(k).toFloat()
    private fun uuid(f: JSONObject, k: String): UUID = UUID.fromString(f.getString(k))

    private fun points(f: JSONObject): List<WirePoint> {
        val arr = f.getJSONArray("points")
        val one = (0 until arr.length()).map {
            val p = arr.getJSONArray(it)
            WirePoint(p.getDouble(0).toFloat(), p.getDouble(1).toFloat(), p.getDouble(2).toFloat(), p.getInt(3))
        }
        val repeat = f.optInt("points_repeat", 1)
        return (0 until repeat).flatMap { one }
    }

    private fun ids(f: JSONObject): List<UUID> {
        val arr = f.getJSONArray("ids")
        val one = (0 until arr.length()).map { UUID.fromString(arr.getString(it)) }
        val repeat = f.optInt("ids_repeat", 1)
        return (0 until repeat).flatMap { one }
    }

    /** Encodes a client-to-server case from its fields with the case's header timestamp. */
    private fun encode(c: JSONObject): ByteArray {
        val ts = java.lang.Long.parseUnsignedLong(c.getString("timestamp_us"))
        val f = c.getJSONObject("fields")
        val enc = Encoder { ts }
        val mirror = MirrorFraming { ts }
        return when (c.getInt("opcode")) {
            SolStream.Op.HANDSHAKE -> enc.handshake(float(f, "canvas_width"), float(f, "canvas_height"), float(f, "dpi"), f.getString("name"))
            SolStream.Op.STROKE_START -> enc.strokeStart(uuid(f, "stroke_id"), f.getInt("tool"), f.getLong("color").toInt(), float(f, "base_width"), float(f, "pressure"))
            SolStream.Op.STROKE_CHUNK -> enc.strokeChunk(uuid(f, "stroke_id"), points(f))
            SolStream.Op.STROKE_COMMIT -> enc.strokeCommit(uuid(f, "stroke_id"), f.getLong("point_count").toInt())
            SolStream.Op.STROKE_CANCEL -> enc.strokeCancel(uuid(f, "stroke_id"))
            SolStream.Op.UNDO -> enc.undo(uuid(f, "page_id"), u64(f, "client_time_us"))
            SolStream.Op.REDO -> enc.redo(uuid(f, "page_id"), u64(f, "client_time_us"))
            SolStream.Op.CLEAR_CANVAS -> enc.clear(uuid(f, "page_id"), u64(f, "client_time_us"))
            SolStream.Op.ERASE_STROKES -> enc.erase(float(f, "x1"), float(f, "y1"), float(f, "x2"), float(f, "y2"), float(f, "radius"), ids(f))
            SolStream.Op.LASER_POINT -> enc.laserPoint(float(f, "x"), float(f, "y"), float(f, "intensity"), float(f, "decay_s"))
            SolStream.Op.PAGE_CHANGE -> enc.pageChange(uuid(f, "page_id"), float(f, "width"), float(f, "height"), f.getLong("page_index").toInt())
            SolStream.Op.AUTO_ENGAGE_RETURN -> enc.returnNow(u64(f, "client_time_us"))
            SolStream.Op.TOGGLE_PIN -> enc.togglePin(f.getInt("value"), u64(f, "client_time_us"))
            SolStream.Op.PING -> enc.ping(u64(f, "sequence"), u64(f, "client_time_us"))
            SolStream.Op.MIRROR_HELLO -> mirror.hello(f.getString("device_name"), f.getLong("codec_id").toInt())
            SolStream.Op.MIRROR_PACKET -> if (f.getString("kind") == "session") {
                mirror.session(f.getLong("width").toInt(), f.getLong("height").toInt())
            } else {
                val flags = u64(f, "pts_flags")
                val annexB = if (f.has("annex_b_zero_bytes")) ByteArray(f.getInt("annex_b_zero_bytes")) else bytes(f.getString("annex_b"), 0)
                mirror.packet(flags and MirrorFraming.FLAG_CONFIG != 0L, flags and MirrorFraming.FLAG_KEY_FRAME != 0L, flags and MirrorFraming.PTS_MASK, annexB)
            }
            SolStream.Op.MIRROR_STATUS -> mirror.status(
                MirrorStatusFields(f.getInt("state"), f.getInt("flags"), f.getInt("fps_x10"), f.getInt("width"), f.getInt("height"), f.getLong("bitrate_bps"), f.getLong("sent_bps"))
            )
            else -> error("no encoder for opcode ${c.getInt("opcode")}")
        }
    }

    private fun expected(c: JSONObject, implemented: Boolean): String {
        val expect = c.getString("expect")
        if (implemented) return expect
        return if (expect == "reject" && c.optString("layer") == "header") "reject" else "ignore"
    }

    private fun u32(v: Int): Long = v.toLong() and 0xFFFFFFFFL

    /** Every way the Kotlin codec disagrees with one case (empty when it agrees). */
    private fun check(c: JSONObject): List<String> {
        val problems = ArrayList<String>()
        val opcode = c.getInt("opcode")
        val expect = c.getString("expect")
        if (expect == "encode_reject") {
            if (opcode !in encodes) return problems
            val threw = try { encode(c); false } catch (e: IllegalArgumentException) { true }
            if (!threw) problems.add("encoder accepted fields it must refuse")
            return problems
        }
        val pad = c.optInt("pad", 0)
        val msg = Decoder.decode(bytes(c.getString("hex"), pad))
        val got = when (msg) {
            null -> "reject"
            is ServerMessage.Unknown -> "ignore"
            else -> "accept"
        }
        val want = expected(c, opcode in decodes)
        if (got != want) problems.add("decode: expected $want, got $got")
        if (want == "accept" && msg != null && c.has("fields")) {
            val f = c.getJSONObject("fields")
            val same = when (msg) {
                is ServerMessage.Ack -> listOf(u32(msg.ack.width), u32(msg.ack.height), u32(msg.ack.fps), u32(msg.ack.status)) ==
                    listOf(f.getLong("target_width"), f.getLong("target_height"), f.getLong("target_fps"), f.getLong("status"))
                is ServerMessage.State -> msg.state.let { s ->
                    listOf(s.governor, s.flags, s.mode, s.inkSource, s.pageIndex, s.strokeCount, s.undoDepth, s.redoDepth) ==
                        listOf(f.getInt("governor"), f.getInt("flags"), f.getInt("mode"), f.getInt("ink_source"), f.getInt("page_index"),
                            f.getInt("stroke_count"), f.getInt("undo_depth"), f.getInt("redo_depth")) &&
                        s.msToReturn == f.getLong("ms_to_return") && s.progress.toRawBits() == float(f, "progress").toRawBits()
                }
                is ServerMessage.Pong -> msg.sequence == u64(f, "sequence") && msg.clientTimeUs == u64(f, "client_time_us")
                is ServerMessage.Mirror -> msg.control.let { m ->
                    listOf(m.command.toLong(), m.maxSize.toLong(), m.bitrateBps, m.maxFps.toLong(), m.keyIntervalMs.toLong()) ==
                        listOf(f.getLong("command"), f.getLong("max_size"), f.getLong("bitrate_bps"), f.getLong("max_fps"), f.getLong("key_interval_ms"))
                }
                is ServerMessage.Unknown -> true
            }
            if (!same) problems.add("decoded fields differ: $msg")
        }
        if (expect == "accept" && c.getString("direction") == "c2s" && c.optBoolean("encodable", false) && opcode in encodes) {
            val canonical = hex(bytes(c.getString("canonical"), c.optInt("canonical_pad", pad)))
            val encoded = try { hex(encode(c)) } catch (e: IllegalArgumentException) { "threw ${e.message}" }
            if (encoded != canonical) problems.add("encode: ${encoded.take(120)} != canonical ${canonical.take(120)}")
        }
        return problems
    }

    @Test
    fun corpusIsVersion1AndCoversEveryOpcode() {
        assertEquals(1, corpus.getInt("version"))
        assertEquals("gen_fuzz.py", corpus.getString("generator"))
        val all = cases()
        assertTrue("only ${all.size} cases", all.size >= 500)
        val ops = corpus.getJSONArray("opcodes")
        for (i in 0 until ops.length()) {
            val op = ops.getInt(i)
            assertTrue("no valid case for $op", all.any { it.getInt("opcode") == op && it.getString("expect") == "accept" })
        }
        val names = all.map { it.getString("name") }.toSet()
        for (name in knownDivergent.keys) assertTrue("knownDivergent names a case the corpus lacks: $name", name in names)
    }

    @Test
    fun kotlinCodecAgreesWithTheFuzzCorpus() {
        val failures = ArrayList<String>()
        for (c in cases()) {
            val name = c.getString("name")
            val problems = check(c)
            val known = knownDivergent[name]
            if (known != null) {
                if (problems.isEmpty()) failures.add("$name: listed as divergent ($known) but now agrees; remove it from knownDivergent")
            } else if (problems.isNotEmpty()) {
                val finding = if (c.has("finding")) " [${c.getString("finding")}]" else ""
                failures.add("$name$finding: ${problems.joinToString("; ")}")
            }
        }
        assertEquals(failures.joinToString("\n"), emptyList<String>(), failures)
    }
}
