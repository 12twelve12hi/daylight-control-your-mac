package com.twelve.daylight.ink.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

data class Header(val opcode: Int, val payloadLen: Int, val timestampUs: Long)

data class HandshakeAck(val width: Int, val height: Int, val fps: Int, val status: Int) {
    companion object {
        const val OK = 0
        const val PENDING_APPROVAL = 1
        const val DENIED = 2
        const val UNSUPPORTED = 3
    }
}

/** STATE (0x0070), 20 bytes. ms_to_return is [SolStream.NO_RETURN_SCHEDULED] when nothing is scheduled. */
data class StateReport(
    val governor: Int,
    val flags: Int,
    val mode: Int,
    val inkSource: Int,
    val progress: Float,
    val msToReturn: Long,
    val pageIndex: Int,
    val strokeCount: Int,
    val undoDepth: Int,
    val redoDepth: Int,
) {
    val pinned: Boolean get() = flags and 1 != 0
    val preWarning: Boolean get() = flags and 2 != 0
    val allowed: Boolean get() = flags and 4 != 0
    val activeSource: Boolean get() = flags and 8 != 0
    val cameraAttached: Boolean get() = flags and 16 != 0
    val sinkConnected: Boolean get() = flags and 32 != 0
    val saving: Boolean get() = flags and 64 != 0
    val captureIdle: Boolean get() = flags and 128 != 0
}

sealed class ServerMessage {
    data class Ack(val ack: HandshakeAck) : ServerMessage()
    data class State(val state: StateReport) : ServerMessage()
    data class Pong(val sequence: Long, val clientTimeUs: Long) : ServerMessage()
    /** MIRROR_CONTROL (0x0071, PROTOCOL 14.4); a wrong payload size decodes to null like any malformed known opcode. */
    data class Mirror(val control: MirrorControl) : ServerMessage()
    data class Unknown(val opcode: Int) : ServerMessage()
}

/** Decodes server-to-client frames. Returns null for a frame that is not SolStream or whose length lies. */
object Decoder {
    fun header(bytes: ByteArray): Header? {
        if (bytes.size < SolStream.HEADER_LEN) return null
        val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        if ((b.get().toInt() and 0xFF) != SolStream.MAGIC) return null
        if ((b.get().toInt() and 0xFF) != SolStream.VERSION) return null
        val opcode = b.short.toInt() and 0xFFFF
        val len = b.int
        if (len != bytes.size - SolStream.HEADER_LEN) return null
        return Header(opcode, len, b.long)
    }

    fun decode(bytes: ByteArray): ServerMessage? {
        val h = header(bytes) ?: return null
        val b = ByteBuffer.wrap(bytes, SolStream.HEADER_LEN, h.payloadLen).order(ByteOrder.LITTLE_ENDIAN)
        return when (h.opcode) {
            SolStream.Op.HANDSHAKE_ACK -> {
                if (h.payloadLen != 16) return null
                ServerMessage.Ack(HandshakeAck(b.int, b.int, b.int, b.int))
            }
            SolStream.Op.STATE -> {
                if (h.payloadLen < 20) return null   // longer STATE frames are compatible additions
                ServerMessage.State(
                    StateReport(
                        governor = b.get().toInt() and 0xFF,
                        flags = b.get().toInt() and 0xFF,
                        mode = b.get().toInt() and 0xFF,
                        inkSource = b.get().toInt() and 0xFF,
                        progress = b.float,
                        msToReturn = b.int.toLong() and 0xFFFFFFFFL,
                        pageIndex = b.short.toInt() and 0xFFFF,
                        strokeCount = b.short.toInt() and 0xFFFF,
                        undoDepth = b.short.toInt() and 0xFFFF,
                        redoDepth = b.short.toInt() and 0xFFFF,
                    )
                )
            }
            SolStream.Op.PONG -> {
                if (h.payloadLen != 16) return null
                ServerMessage.Pong(b.long, b.long)
            }
            SolStream.Op.MIRROR_CONTROL -> MirrorFraming.decodeControlPayload(bytes, h.payloadLen)?.let { ServerMessage.Mirror(it) }
            else -> ServerMessage.Unknown(h.opcode)
        }
    }
}
