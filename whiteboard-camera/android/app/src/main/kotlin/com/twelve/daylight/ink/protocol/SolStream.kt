package com.twelve.daylight.ink.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

/** SolStream-v1 constants (docs/PROTOCOL.md). Pure JVM: no Android imports, so the golden test runs on the host. */
object SolStream {
    const val MAGIC: Int = 0xDA
    const val VERSION: Int = 0x01
    const val HEADER_LEN: Int = 16
    const val POINT_LEN: Int = 11
    const val MAX_POINTS_PER_CHUNK: Int = 4096
    const val MAX_ERASED_PER_MESSAGE: Int = 1024
    const val MAX_NAME_LENGTH: Int = 200
    const val DEFAULT_PORT: Int = 7788
    const val SERVICE_TYPE: String = "_daylight-camera._tcp"
    const val SUBPROTOCOL: String = "solstream.v1"
    const val CANVAS_WIDTH: Int = 1200
    const val CANVAS_HEIGHT: Int = 1600
    const val NO_RETURN_SCHEDULED: Long = 0xFFFFFFFFL

    object Op {
        const val HANDSHAKE = 0x0001
        const val HANDSHAKE_ACK = 0x0002
        const val STROKE_START = 0x0010
        const val STROKE_CHUNK = 0x0011
        const val STROKE_COMMIT = 0x0012
        const val STROKE_CANCEL = 0x0013
        const val UNDO = 0x0014
        const val REDO = 0x0015
        const val ERASE_STROKES = 0x0020
        const val LASER_POINT = 0x0030
        const val CLEAR_CANVAS = 0x0040
        const val PAGE_CHANGE = 0x0050
        const val AUTO_ENGAGE_RETURN = 0x0060
        const val TOGGLE_PIN = 0x0061
        const val STATE = 0x0070
        const val MIRROR_CONTROL = 0x0071      // PROTOCOL 14, server to client
        const val MIRROR_HELLO = 0x0080        // PROTOCOL 14, client to server
        const val MIRROR_PACKET = 0x0081
        const val MIRROR_STATUS = 0x0082
        const val PING = 0x00FE
        const val PONG = 0x00FF
    }

    object Tool {
        const val PEN = 0
        const val HIGHLIGHTER = 1
        const val ERASER = 2
        const val LASSO = 3
    }

    /** UUID to 16 bytes in RFC 4122 order: write msb then lsb into a BIG-endian buffer (little-endian is the classic bug). */
    fun uuidBytes(id: UUID): ByteArray {
        val b = ByteBuffer.allocate(16).order(ByteOrder.BIG_ENDIAN)
        b.putLong(id.mostSignificantBits)
        b.putLong(id.leastSignificantBits)
        return b.array()
    }

    fun uuidFromBytes(bytes: ByteArray, offset: Int = 0): UUID {
        val b = ByteBuffer.wrap(bytes, offset, 16).order(ByteOrder.BIG_ENDIAN)
        return UUID(b.long, b.long)
    }

    val ZERO_UUID: UUID = UUID(0L, 0L)
}

/** One point in canvas units; deltaMs is milliseconds since the FIRST point of the stroke. */
class WirePoint(val x: Float, val y: Float, val pressure: Float, val deltaMs: Int)

/**
 * Builds SolStream frames into one reusable little-endian buffer. Not thread safe: one instance per connection.
 * [nowUs] is the sender clock in microseconds since the epoch (System.currentTimeMillis() * 1000 on Android).
 */
class Encoder(private val nowUs: () -> Long) {
    private val buf: ByteBuffer = ByteBuffer.allocate(65536).order(ByteOrder.LITTLE_ENDIAN)

    private fun begin(opcode: Int) {
        buf.clear()
        buf.put(SolStream.MAGIC.toByte())
        buf.put(SolStream.VERSION.toByte())
        buf.putShort(opcode.toShort())
        buf.putInt(0)              // payload_len, patched in finish()
        buf.putLong(nowUs())
    }

    private fun finish(): ByteArray {
        val len = buf.position()
        buf.putInt(4, len - SolStream.HEADER_LEN)
        val out = ByteArray(len)
        buf.flip()
        buf.get(out)
        return out
    }

    private fun putUuid(id: UUID) {
        buf.put(SolStream.uuidBytes(id))
    }

    fun handshake(canvasWidth: Float, canvasHeight: Float, dpi: Float, name: String): ByteArray {
        val nameBytes = name.toByteArray(Charsets.UTF_8)
        require(nameBytes.size in 1..SolStream.MAX_NAME_LENGTH) { "handshake name must be 1..200 UTF-8 bytes" }
        begin(SolStream.Op.HANDSHAKE)
        buf.putFloat(canvasWidth)
        buf.putFloat(canvasHeight)
        buf.putFloat(dpi)
        buf.putShort(nameBytes.size.toShort())
        buf.put(nameBytes)
        return finish()
    }

    fun strokeStart(id: UUID, tool: Int, colorArgb: Int, baseWidth: Float, pressure: Float): ByteArray {
        begin(SolStream.Op.STROKE_START)
        putUuid(id)
        buf.put(tool.toByte())
        buf.putInt(colorArgb)
        buf.putFloat(baseWidth)
        buf.put(0)                 // pointer_type stylus
        buf.put(1)                 // phase contact
        buf.putFloat(pressure)
        return finish()
    }

    fun strokeChunk(id: UUID, points: List<WirePoint>): ByteArray {
        require(points.size in 1..SolStream.MAX_POINTS_PER_CHUNK) { "chunk needs 1..4096 points" }
        begin(SolStream.Op.STROKE_CHUNK)
        putUuid(id)
        buf.putShort(points.size.toShort())
        for (p in points) {
            buf.putInt(Math.round(p.x * 32f))
            buf.putInt(Math.round(p.y * 32f))
            buf.put(Math.round(p.pressure.coerceIn(0f, 1f) * 255f).toByte())
            buf.putShort(p.deltaMs.coerceIn(0, 65535).toShort())
        }
        return finish()
    }

    fun strokeCommit(id: UUID, pointCount: Int): ByteArray {
        begin(SolStream.Op.STROKE_COMMIT)
        putUuid(id)
        buf.putInt(pointCount)
        return finish()
    }

    fun strokeCancel(id: UUID): ByteArray {
        begin(SolStream.Op.STROKE_CANCEL)
        putUuid(id)
        return finish()
    }

    private fun pageAndTime(opcode: Int, pageId: UUID?, timeUs: Long): ByteArray {
        begin(opcode)
        putUuid(pageId ?: SolStream.ZERO_UUID)
        buf.putLong(timeUs)
        return finish()
    }

    fun undo(pageId: UUID?, timeUs: Long = nowUs()): ByteArray = pageAndTime(SolStream.Op.UNDO, pageId, timeUs)
    fun redo(pageId: UUID?, timeUs: Long = nowUs()): ByteArray = pageAndTime(SolStream.Op.REDO, pageId, timeUs)
    fun clear(pageId: UUID?, timeUs: Long = nowUs()): ByteArray = pageAndTime(SolStream.Op.CLEAR_CANVAS, pageId, timeUs)

    fun erase(x1: Float, y1: Float, x2: Float, y2: Float, radius: Float, ids: List<UUID>): ByteArray {
        require(ids.size <= SolStream.MAX_ERASED_PER_MESSAGE) { "erase carries at most 1024 ids" }
        begin(SolStream.Op.ERASE_STROKES)
        buf.putFloat(x1); buf.putFloat(y1); buf.putFloat(x2); buf.putFloat(y2); buf.putFloat(radius)
        buf.putShort(ids.size.toShort())
        for (id in ids) putUuid(id)
        return finish()
    }

    fun laserPoint(x: Float, y: Float, intensity: Float, decayS: Float): ByteArray {
        begin(SolStream.Op.LASER_POINT)
        buf.putFloat(x); buf.putFloat(y); buf.putFloat(intensity); buf.putFloat(decayS)
        return finish()
    }

    fun pageChange(pageId: UUID, width: Float, height: Float, index: Int): ByteArray {
        begin(SolStream.Op.PAGE_CHANGE)
        putUuid(pageId)
        buf.putFloat(width)
        buf.putFloat(height)
        buf.putInt(index)
        return finish()
    }

    fun returnNow(timeUs: Long = nowUs()): ByteArray {
        begin(SolStream.Op.AUTO_ENGAGE_RETURN)
        buf.putLong(timeUs)
        return finish()
    }

    fun togglePin(value: Int, timeUs: Long = nowUs()): ByteArray {
        require(value in -1..1) { "pin value is -1, 0 or 1" }
        begin(SolStream.Op.TOGGLE_PIN)
        buf.put(value.toByte())
        buf.putLong(timeUs)
        return finish()
    }

    fun ping(sequence: Long, timeUs: Long = nowUs()): ByteArray {
        begin(SolStream.Op.PING)
        buf.putLong(sequence)
        buf.putLong(timeUs)
        return finish()
    }
}
