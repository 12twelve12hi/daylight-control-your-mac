package com.twelve.daylight.ink

import com.twelve.daylight.ink.protocol.Decoder
import com.twelve.daylight.ink.protocol.MirrorControl
import com.twelve.daylight.ink.protocol.MirrorFraming
import com.twelve.daylight.ink.protocol.MirrorParams
import com.twelve.daylight.ink.protocol.MirrorStatusFields
import com.twelve.daylight.ink.protocol.ServerMessage
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer

/**
 * PROTOCOL 14 golden vectors (`mirror_cases` of protocol/golden/solstream-v1.json, read exactly like SolStreamTest
 * reads `cases`): every c2s case encodes byte-equal, every s2c case decodes; plus the 14.4 defaults and clamps and the
 * 63-byte UTF-8 boundary rule of 14.1.
 */
class MirrorFramingTest {
    private val manifest: JSONObject = JSONObject(
        requireNotNull(javaClass.classLoader?.getResourceAsStream("solstream-v1.json")) { "golden manifest missing" }
            .readBytes().toString(Charsets.UTF_8)
    )
    private val ts = manifest.getLong("timestamp_us")
    private val framing = MirrorFraming { ts }

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 0xFF) }
    private fun unhex(s: String): ByteArray = ByteArray(s.length / 2) { i -> s.substring(i * 2, i * 2 + 2).toInt(16).toByte() }

    private fun mirrorCases(): List<JSONObject> {
        val arr = manifest.getJSONArray("mirror_cases")
        return (0 until arr.length()).map { arr.getJSONObject(it) }
    }

    private fun encodeCase(c: JSONObject): ByteArray? {
        val f = c.getJSONObject("fields")
        return when (c.getInt("opcode")) {
            0x0080 -> framing.hello(f.getString("device_name"), f.getLong("codec_id").toInt())
            0x0081 -> when (f.getString("kind")) {
                "session" -> framing.session(f.getInt("width"), f.getInt("height"))
                "config" -> framing.packet(true, f.getBoolean("key_frame"), f.getLong("pts_us"), unhex(f.getString("annex_b")))
                "frame" -> framing.packet(false, f.getBoolean("key_frame"), f.getLong("pts_us"), unhex(f.getString("annex_b")))
                else -> null
            }
            0x0082 -> framing.status(
                MirrorStatusFields(
                    f.getInt("state"), f.getInt("flags"), f.getInt("fps_x10"), f.getInt("width"), f.getInt("height"),
                    f.getLong("bitrate_bps"), f.getLong("sent_bps"),
                )
            )
            else -> null
        }
    }

    @Test
    fun theV1CasesAreUnchangedAndTheMirrorCasesArePresent() {
        assertEquals(1, manifest.getInt("version"))
        assertEquals(26, manifest.getJSONArray("cases").length())
        val names = mirrorCases().map { it.getString("name") }.toSet()
        for (n in listOf("mirror_hello", "mirror_packet_session", "mirror_packet_config", "mirror_packet_key_frame", "mirror_packet_delta",
            "mirror_status_streaming", "mirror_status_consent_denied", "mirror_control_start", "mirror_control_stop", "mirror_control_key_frame")) {
            assertTrue("missing $n", names.contains(n))
        }
    }

    @Test
    fun everyClientMirrorCaseEncodesByteForByte() {
        val c2s = mirrorCases().filter { it.getString("direction") == "c2s" && !it.getBoolean("decode_only") }
        assertTrue(c2s.size >= 7)
        for (c in c2s) {
            val bytes = encodeCase(c)
            assertNotNull("no encoder mapping for ${c.getString("name")}", bytes)
            assertEquals(c.getString("name"), c.getString("hex"), hex(bytes!!))
        }
    }

    @Test
    fun everyServerMirrorCaseDecodes() {
        val s2c = mirrorCases().filter { it.getString("direction") == "s2c" }
        assertTrue(s2c.size >= 3)
        for (c in s2c) {
            val f = c.getJSONObject("fields")
            val frame = unhex(c.getString("hex"))
            val direct = MirrorFraming.decodeControl(frame)
            val msg = Decoder.decode(frame)
            assertTrue(c.getString("name"), msg is ServerMessage.Mirror)
            assertEquals(direct, (msg as ServerMessage.Mirror).control)
            val m = msg.control
            assertEquals(f.getInt("command"), m.command)
            assertEquals(f.getInt("max_size"), m.maxSize)
            assertEquals(f.getLong("bitrate_bps"), m.bitrateBps)
            assertEquals(f.getInt("max_fps"), m.maxFps)
            assertEquals(f.getInt("key_interval_ms"), m.keyIntervalMs)
        }
    }

    @Test
    fun goldenStartGivesTheDefaultsAndStopGivesDefaultsToo() {
        val start = MirrorFraming.decodeControl(unhex(mirrorCases().single { it.getString("name") == "mirror_control_start" }.getString("hex")))!!
        assertEquals(MirrorControl.START, start.command)
        assertEquals(MirrorParams(1600, 7_000_000, 30, 2000), start.params())
        assertEquals(2, start.params().keyIntervalSeconds)
        val stop = MirrorFraming.decodeControl(unhex(mirrorCases().single { it.getString("name") == "mirror_control_stop" }.getString("hex")))!!
        assertEquals(MirrorControl.STOP, stop.command)
        assertEquals(MirrorParams(), stop.params())                       // zeros mean the defaults
    }

    @Test
    fun zerosAreTheDefaults() {
        val p = MirrorParams.from(0, 0L, 0, 0)
        assertEquals(1600, p.maxSize)
        assertEquals(7_000_000, p.bitrateBps)
        assertEquals(30, p.maxFps)
        assertEquals(2000, p.keyIntervalMs)
    }

    @Test
    fun maxSizeIsClampedTo320To1600AndRoundedDownToSixteen() {
        assertEquals(320, MirrorParams.from(1, 0, 0, 0).maxSize)
        assertEquals(320, MirrorParams.from(319, 0, 0, 0).maxSize)
        assertEquals(320, MirrorParams.from(335, 0, 0, 0).maxSize)
        assertEquals(336, MirrorParams.from(336, 0, 0, 0).maxSize)
        assertEquals(1024, MirrorParams.from(1039, 0, 0, 0).maxSize)
        assertEquals(1584, MirrorParams.from(1599, 0, 0, 0).maxSize)
        assertEquals(1600, MirrorParams.from(1600, 0, 0, 0).maxSize)
        assertEquals(1600, MirrorParams.from(65535, 0, 0, 0).maxSize)
    }

    @Test
    fun bitrateIsClampedTo1To8Mbps() {
        assertEquals(1_000_000, MirrorParams.from(0, 1L, 0, 0).bitrateBps)
        assertEquals(1_000_000, MirrorParams.from(0, 999_999L, 0, 0).bitrateBps)
        assertEquals(2_500_000, MirrorParams.from(0, 2_500_000L, 0, 0).bitrateBps)
        assertEquals(8_000_000, MirrorParams.from(0, 8_000_001L, 0, 0).bitrateBps)
        assertEquals(8_000_000, MirrorParams.from(0, 0xFFFFFFFFL, 0, 0).bitrateBps)
    }

    @Test
    fun fpsIsClampedTo1To30() {
        assertEquals(1, MirrorParams.from(0, 0, 1, 0).maxFps)
        assertEquals(15, MirrorParams.from(0, 0, 15, 0).maxFps)
        assertEquals(30, MirrorParams.from(0, 0, 31, 0).maxFps)
        assertEquals(30, MirrorParams.from(0, 0, 65535, 0).maxFps)
    }

    @Test
    fun keyIntervalIsClampedTo500To10000AndRoundedUpToSeconds() {
        assertEquals(500, MirrorParams.from(0, 0, 0, 1).keyIntervalMs)
        assertEquals(1, MirrorParams.from(0, 0, 0, 1).keyIntervalSeconds)
        assertEquals(10_000, MirrorParams.from(0, 0, 0, 65535).keyIntervalMs)
        assertEquals(10, MirrorParams.from(0, 0, 0, 65535).keyIntervalSeconds)
        assertEquals(3, MirrorParams.from(0, 0, 0, 2001).keyIntervalSeconds)
        assertEquals(3, MirrorParams.from(0, 0, 0, 2500).keyIntervalSeconds)
        assertEquals(2, MirrorParams.from(0, 0, 0, 2000).keyIntervalSeconds)
    }

    @Test
    fun maxUnsignedFieldsDecodeWithoutSignErrors() {
        val frame = unhex("da0171000c00000040e2cfeeb5400600" + "03" + "00" + "ffff" + "ffffffff" + "ffff" + "ffff")
        val c = MirrorFraming.decodeControl(frame)!!
        assertEquals(MirrorControl.RELEASE, c.command)
        assertEquals(65535, c.maxSize)
        assertEquals(0xFFFFFFFFL, c.bitrateBps)
        assertEquals(65535, c.maxFps)
        assertEquals(65535, c.keyIntervalMs)
    }

    @Test
    fun aControlOfTheWrongSizeIsDroppedAndOtherOpcodesStayUnknown() {
        val good = unhex(mirrorCases().single { it.getString("name") == "mirror_control_stop" }.getString("hex"))
        // 13-byte payload with a payload_len that tells the truth: a wrong fixed size for a known opcode -> dropped.
        val long = good.copyOf(good.size + 1).also { it[4] = 13 }
        assertNull(MirrorFraming.decodeControl(long))
        assertNull(Decoder.decode(long))
        assertNull(MirrorFraming.decodeControl(good.copyOf(good.size - 1)))
        // A reserved server opcode (0x0072) is still Unknown: PROTOCOL 10.
        val reserved = good.copyOf().also { it[2] = 0x72 }
        assertEquals(ServerMessage.Unknown(0x0072), Decoder.decode(reserved))
    }

    @Test
    fun deviceNameIsCutAt63BytesOnACodePointBoundary() {
        assertEquals("DC-1", String(MirrorFraming.deviceNameBytes("DC-1"), Charsets.UTF_8))
        val ascii63 = "a".repeat(63)
        assertEquals(63, MirrorFraming.deviceNameBytes(ascii63).size)
        assertEquals(63, MirrorFraming.deviceNameBytes("a".repeat(80)).size)
        // 62 ASCII bytes then U+2019 (3 bytes, 62..64): the whole apostrophe goes, 62 bytes remain.
        val cut = MirrorFraming.deviceNameBytes("a".repeat(62) + "’s")
        assertEquals(62, cut.size)
        assertEquals("a".repeat(62), String(cut, Charsets.UTF_8))
        // 60 ASCII then U+2019 ends exactly at byte 63: kept whole.
        val fits = MirrorFraming.deviceNameBytes("a".repeat(60) + "’" + "xyz")
        assertEquals(63, fits.size)
        assertEquals("a".repeat(60) + "’", String(fits, Charsets.UTF_8))
        // A 4-byte code point (U+1F58A) straddling byte 63 is dropped whole.
        val emoji = MirrorFraming.deviceNameBytes("a".repeat(61) + "🖊")
        assertEquals(61, emoji.size)
        // The HELLO field is always 64 bytes with at least one NUL.
        val hello = framing.hello("a".repeat(62) + "’s")
        assertEquals(16 + 68, hello.size)
        assertEquals(0, hello[16 + 62].toInt())
        assertEquals(0, hello[16 + 63].toInt())
        assertEquals("68323634", hex(hello.copyOfRange(16 + 64, 16 + 68)))
    }

    @Test
    fun packetHeaderIsBigEndianWithFlagBitsAndSizeEqualToN() {
        val data = byteArrayOf(0, 0, 0, 1, 0x65, 1, 2)
        val f = framing.packet(config = false, keyFrame = true, ptsUs = 0x0123456789L, annexB = data)
        assertEquals(16 + 12 + data.size, f.size)
        val b = ByteBuffer.wrap(f, 16, 12)                   // ByteBuffer defaults to BIG-endian
        val ptsFlags = b.long
        assertEquals(1L shl 61, ptsFlags and (1L shl 61))
        assertEquals(0L, ptsFlags and (1L shl 62))
        assertEquals(0L, ptsFlags and (1L shl 63))
        assertEquals(0x0123456789L, ptsFlags and MirrorFraming.PTS_MASK)
        assertEquals(data.size, b.int)
        assertArrayEquals(data, f.copyOfRange(28, f.size))
        // The source buffer's position is left alone (the drain thread releases it afterwards).
        val src = ByteBuffer.wrap(data)
        framing.packet(true, false, 0, src)
        assertEquals(0, src.position())
    }

    @Test
    fun ptsFlagsNeverSetBit63AndMaskThePts() {
        assertEquals(0L, MirrorFraming.ptsFlags(false, false, -5))
        assertEquals(MirrorFraming.PTS_MASK, MirrorFraming.ptsFlags(false, false, Long.MAX_VALUE))
        assertEquals((1L shl 62) or (1L shl 61) or 7L, MirrorFraming.ptsFlags(true, true, 7))
    }

    @Test
    fun packetSizeLimitIsTheOneMebibytePayloadCapMinusTwelve() {
        assertEquals(1_048_564, MirrorFraming.MAX_ANNEX_B_BYTES)
        val max = framing.packet(false, false, 0, ByteArray(MirrorFraming.MAX_ANNEX_B_BYTES))
        assertEquals(1_048_576, max.size - 16)
        assertEquals(true, runCatching { framing.packet(false, false, 0, ByteArray(MirrorFraming.MAX_ANNEX_B_BYTES + 1)) }.isFailure)
        assertEquals(true, runCatching { framing.packet(false, false, 0, ByteArray(0)) }.isFailure)
    }

    @Test
    fun statusFieldsSaturateInsteadOfWrapping() {
        val f = framing.status(MirrorStatusFields(3, 0x0F, 70000, 70000, -1, 1L shl 40, -5))
        val p = Frame(f)
        assertEquals(0x0082, p.opcode)
        assertEquals(16, p.payloadLen)
        assertEquals(3, p.u8())
        assertEquals(0x0F, p.u8())
        assertEquals(0xFFFF, p.u16())
        assertEquals(0xFFFF, p.u16())
        assertEquals(0, p.u16())
        assertEquals(0xFFFFFFFFL, p.u32())
        assertEquals(0L, p.u32())
    }

    @Test
    fun controlCommandOutsideZeroToThreeDoesNotDecode() {
        // PROTOCOL 14.4 and 10 (FZ-5).
        for (cmd in listOf("04", "ff")) {
            val frame = unhex("da0171000c00000040e2cfeeb5400600" + cmd + "00" + "0000" + "00000000" + "0000" + "0000")
            assertNull(cmd, MirrorFraming.decodeControl(frame))
            assertNull(cmd, Decoder.decode(frame))
        }
        val release = unhex("da0171000c00000040e2cfeeb5400600" + "03" + "00" + "0000" + "00000000" + "0000" + "0000")
        assertEquals(MirrorControl.RELEASE, MirrorFraming.decodeControl(release)!!.command)
    }

    @Test
    fun theLargestMediaPacketFitsTheOneMiBHeaderCap() {
        // PROTOCOL 14.2: n <= 1,048,564, so 12 + n is exactly the 1 MiB payload cap the header check enforces (FZ-1).
        val largest = framing.packet(false, true, 0L, ByteArray(MirrorFraming.MAX_ANNEX_B_BYTES))
        assertEquals(1_048_576, Decoder.header(largest)!!.payloadLen)
        try {
            framing.packet(false, true, 0L, ByteArray(MirrorFraming.MAX_ANNEX_B_BYTES + 1))
            throw AssertionError("an access unit over the cap must be refused (the tablet drops it and asks for a key frame)")
        } catch (expected: IllegalArgumentException) {
        }
    }
}
