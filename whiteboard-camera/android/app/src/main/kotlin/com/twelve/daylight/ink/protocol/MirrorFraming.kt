package com.twelve.daylight.ink.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** MIRROR_CONTROL (0x0071) exactly as received: zeros mean "default" (PROTOCOL 14.4). */
data class MirrorControl(
    val command: Int,
    val maxSize: Int,
    val bitrateBps: Long,
    val maxFps: Int,
    val keyIntervalMs: Int,
) {
    companion object {
        const val STOP = 0
        const val START = 1
        const val REQUEST_KEY_FRAME = 2
        const val RELEASE = 3
    }

    /** The START parameters with the PROTOCOL 14.4 defaults and clamps applied. */
    fun params(): MirrorParams = MirrorParams.from(maxSize, bitrateBps, maxFps, keyIntervalMs)
}

/** Encoder parameters after the PROTOCOL 14.4 defaults and clamps. */
data class MirrorParams(
    /** Long side in pixels, 320..1600, a multiple of 16. */
    val maxSize: Int = DEFAULT_MAX_SIZE,
    /** 1,000,000..8,000,000. */
    val bitrateBps: Int = DEFAULT_BITRATE,
    /** 1..30. */
    val maxFps: Int = DEFAULT_FPS,
    /** 500..10000. */
    val keyIntervalMs: Int = DEFAULT_KEY_INTERVAL_MS,
) {
    /** `KEY_I_FRAME_INTERVAL` in whole seconds, rounded up (2000 ms gives 2, 2500 ms gives 3). */
    val keyIntervalSeconds: Int get() = (keyIntervalMs + 999) / 1000

    companion object {
        const val DEFAULT_MAX_SIZE = 1600
        const val MIN_MAX_SIZE = 320
        const val DEFAULT_BITRATE = 7_000_000
        const val MIN_BITRATE = 1_000_000
        const val MAX_BITRATE = 8_000_000
        const val DEFAULT_FPS = 30
        const val DEFAULT_KEY_INTERVAL_MS = 2000
        const val MIN_KEY_INTERVAL_MS = 500
        const val MAX_KEY_INTERVAL_MS = 10_000

        fun from(maxSize: Int, bitrateBps: Long, maxFps: Int, keyIntervalMs: Int): MirrorParams {
            val size = if (maxSize == 0) DEFAULT_MAX_SIZE else maxSize.coerceIn(MIN_MAX_SIZE, DEFAULT_MAX_SIZE)
            val rate = if (bitrateBps == 0L) DEFAULT_BITRATE.toLong() else bitrateBps.coerceIn(MIN_BITRATE.toLong(), MAX_BITRATE.toLong())
            val fps = if (maxFps == 0) DEFAULT_FPS else maxFps.coerceIn(1, DEFAULT_FPS)
            val key = if (keyIntervalMs == 0) DEFAULT_KEY_INTERVAL_MS else keyIntervalMs.coerceIn(MIN_KEY_INTERVAL_MS, MAX_KEY_INTERVAL_MS)
            return MirrorParams(size / 16 * 16, rate.toInt(), fps, key)
        }
    }
}

/** MIRROR_STATUS (0x0082) fields, PROTOCOL 14.3. */
data class MirrorStatusFields(
    val state: Int,
    val flags: Int,
    val fpsX10: Int,
    val width: Int,
    val height: Int,
    val bitrateBps: Long,
    val sentBps: Long,
)

/**
 * The mirror stream family (PROTOCOL 14). The SolStream header and STATUS and CONTROL payloads are little-endian; the
 * scrcpy parts (HELLO's codec id and the 12-byte packet header) are BIG-endian, exactly as scrcpy 4.1 writes them.
 * Every call allocates its own frame, so the encoder's drain thread and the main thread can both use one instance.
 */
class MirrorFraming(private val nowUs: () -> Long) {
    companion object {
        const val OP_MIRROR_CONTROL = SolStream.Op.MIRROR_CONTROL
        const val OP_MIRROR_HELLO = SolStream.Op.MIRROR_HELLO
        const val OP_MIRROR_PACKET = SolStream.Op.MIRROR_PACKET
        const val OP_MIRROR_STATUS = SolStream.Op.MIRROR_STATUS

        const val CODEC_H264: Int = 0x68323634          // "h264"
        const val NAME_FIELD_BYTES = 64
        const val NAME_MAX_BYTES = 63
        const val PACKET_HEADER_BYTES = 12
        const val HELLO_PAYLOAD_BYTES = 68
        const val STATUS_PAYLOAD_BYTES = 16
        const val CONTROL_PAYLOAD_BYTES = 12
        /** 1 MiB SolStream payload cap minus the 12-byte scrcpy header (PROTOCOL 14.2). */
        const val MAX_ANNEX_B_BYTES = 1_048_576 - PACKET_HEADER_BYTES

        const val FLAG_CONFIG: Long = 1L shl 62
        const val FLAG_KEY_FRAME: Long = 1L shl 61
        const val PTS_MASK: Long = (1L shl 61) - 1

        /** UTF-8 bytes of [name], at most 63, cut on a code point boundary (the scrcpy device meta rule). */
        fun deviceNameBytes(name: String): ByteArray {
            val all = name.toByteArray(Charsets.UTF_8)
            if (all.size <= NAME_MAX_BYTES) return all
            var cut = NAME_MAX_BYTES
            // A continuation byte (10xxxxxx) at the cut means the character started earlier: drop all of it.
            while (cut > 0 && (all[cut].toInt() and 0xC0) == 0x80) cut--
            return all.copyOf(cut)
        }

        /** The 64-bit scrcpy `pts_flags` of a media packet. */
        fun ptsFlags(config: Boolean, keyFrame: Boolean, ptsUs: Long): Long {
            var v = ptsUs.coerceAtLeast(0L) and PTS_MASK
            if (config) v = v or FLAG_CONFIG
            if (keyFrame) v = v or FLAG_KEY_FRAME
            return v
        }

        /** MIRROR_CONTROL from a whole frame; null when it is not one or its payload is not exactly 12 bytes. */
        fun decodeControl(frame: ByteArray): MirrorControl? {
            val h = Decoder.header(frame) ?: return null
            if (h.opcode != OP_MIRROR_CONTROL) return null
            return decodeControlPayload(frame, h.payloadLen)
        }

        internal fun decodeControlPayload(frame: ByteArray, payloadLen: Int): MirrorControl? {
            if (payloadLen != CONTROL_PAYLOAD_BYTES) return null
            val b = ByteBuffer.wrap(frame, SolStream.HEADER_LEN, payloadLen).order(ByteOrder.LITTLE_ENDIAN)
            val command = b.get().toInt() and 0xFF
            b.get()                                       // reserved
            val maxSize = b.short.toInt() and 0xFFFF
            val bitrate = b.int.toLong() and 0xFFFFFFFFL
            val fps = b.short.toInt() and 0xFFFF
            val key = b.short.toInt() and 0xFFFF
            return MirrorControl(command, maxSize, bitrate, fps, key)
        }
    }

    private fun frame(opcode: Int, payloadLen: Int): ByteBuffer {
        val b = ByteBuffer.allocate(SolStream.HEADER_LEN + payloadLen).order(ByteOrder.LITTLE_ENDIAN)
        b.put(SolStream.MAGIC.toByte())
        b.put(SolStream.VERSION.toByte())
        b.putShort(opcode.toShort())
        b.putInt(payloadLen)
        b.putLong(nowUs())
        return b
    }

    /** MIRROR_HELLO: the device name NUL-padded to 64 bytes, then the BIG-endian codec id. */
    fun hello(deviceName: String, codecId: Int = CODEC_H264): ByteArray {
        val b = frame(OP_MIRROR_HELLO, HELLO_PAYLOAD_BYTES)
        val name = deviceNameBytes(deviceName)
        b.put(name)
        b.put(ByteArray(NAME_FIELD_BYTES - name.size))
        b.order(ByteOrder.BIG_ENDIAN).putInt(codecId)
        return b.array()
    }

    /** MIRROR_PACKET session form: byte 0 = 0x80, three zero bytes, width and height u32 BIG-endian, no payload. */
    fun session(width: Int, height: Int): ByteArray {
        val b = frame(OP_MIRROR_PACKET, PACKET_HEADER_BYTES)
        b.order(ByteOrder.BIG_ENDIAN)
        b.putInt(0x80000000.toInt())
        b.putInt(width)
        b.putInt(height)
        return b.array()
    }

    /** MIRROR_PACKET media form from the [annexB] bytes between its position and limit (the position is not moved). */
    fun packet(config: Boolean, keyFrame: Boolean, ptsUs: Long, annexB: ByteBuffer): ByteArray {
        val src = annexB.duplicate()
        val n = src.remaining()
        require(n in 1..MAX_ANNEX_B_BYTES) { "media packet needs 1..$MAX_ANNEX_B_BYTES bytes, got $n" }
        val b = frame(OP_MIRROR_PACKET, PACKET_HEADER_BYTES + n)
        b.order(ByteOrder.BIG_ENDIAN)
        b.putLong(ptsFlags(config, keyFrame, ptsUs))
        b.putInt(n)
        b.put(src)
        return b.array()
    }

    fun packet(config: Boolean, keyFrame: Boolean, ptsUs: Long, annexB: ByteArray): ByteArray =
        packet(config, keyFrame, ptsUs, ByteBuffer.wrap(annexB))

    /** MIRROR_STATUS, `<BBHHHII>`: unsigned fields saturate instead of wrapping. */
    fun status(s: MirrorStatusFields): ByteArray {
        val b = frame(OP_MIRROR_STATUS, STATUS_PAYLOAD_BYTES)
        b.put(s.state.coerceIn(0, 255).toByte())
        b.put(s.flags.coerceIn(0, 255).toByte())
        b.putShort(s.fpsX10.coerceIn(0, 0xFFFF).toShort())
        b.putShort(s.width.coerceIn(0, 0xFFFF).toShort())
        b.putShort(s.height.coerceIn(0, 0xFFFF).toShort())
        b.putInt(s.bitrateBps.coerceIn(0L, 0xFFFFFFFFL).toInt())
        b.putInt(s.sentBps.coerceIn(0L, 0xFFFFFFFFL).toInt())
        return b.array()
    }
}
