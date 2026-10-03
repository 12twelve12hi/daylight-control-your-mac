package com.twelve.daylight.ink

import com.twelve.daylight.ink.protocol.SolStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

/** Test-side reader for client-to-server frames (the app only decodes server frames). */
class Frame(bytes: ByteArray) {
    private val b: ByteBuffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
    val magic: Int = b.get().toInt() and 0xFF
    val version: Int = b.get().toInt() and 0xFF
    val opcode: Int = b.short.toInt() and 0xFFFF
    val payloadLen: Int = b.int
    val timestampUs: Long = b.long
    val size: Int = bytes.size

    init {
        check(magic == SolStream.MAGIC && version == SolStream.VERSION) { "not a SolStream frame" }
        check(payloadLen == bytes.size - SolStream.HEADER_LEN) { "payload_len lies" }
    }

    fun uuid(): UUID = UUID(ByteBuffer.wrap(ByteArray(8).also { b.get(it) }).long, ByteBuffer.wrap(ByteArray(8).also { b.get(it) }).long)
    fun u8(): Int = b.get().toInt() and 0xFF
    fun i8(): Int = b.get().toInt()
    fun u16(): Int = b.short.toInt() and 0xFFFF
    fun i32(): Int = b.int
    fun u32(): Long = b.int.toLong() and 0xFFFFFFFFL
    fun f32(): Float = b.float
    fun u64(): Long = b.long

    data class Point(val x32: Int, val y32: Int, val pressure: Int, val deltaMs: Int)

    /** STROKE_CHUNK payload after the header: uuid, count, points. */
    fun chunkPoints(): List<Point> {
        uuid()
        val n = u16()
        return (0 until n).map { Point(i32(), i32(), u8(), u16()) }
    }
}

object Frames {
    fun of(bytes: ByteArray) = Frame(bytes)
    fun opcodes(frames: List<ByteArray>): List<Int> = frames.map { Frame(it).opcode }
}
