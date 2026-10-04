package com.twelve.daylight.ink

import com.twelve.daylight.ink.ink.FrameScheduler
import com.twelve.daylight.ink.ink.InkSink
import com.twelve.daylight.ink.ink.LaserPointer
import com.twelve.daylight.ink.ink.LocalPoint
import com.twelve.daylight.ink.ink.LocalStroke
import com.twelve.daylight.ink.ink.StrokeSession
import com.twelve.daylight.ink.ink.Tools
import com.twelve.daylight.ink.ink.Transport
import com.twelve.daylight.ink.protocol.Encoder
import com.twelve.daylight.ink.protocol.SolStream
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/** LOOSE_ENDS F3: the Laser tool sends LASER_POINT (PROTOCOL 6.9) and nothing else. */
class LaserPointerTest {
    private class FakeTransport : Transport {
        val sent = ArrayList<ByteArray>()
        override var inkAllowed = true
        override fun send(frame: ByteArray): Boolean { sent.add(frame); return true }
        override fun queueBytes(): Long = 0L
    }

    private class FakeSink : InkSink {
        val log = ArrayList<String>()
        override fun segment(stroke: LocalStroke, from: LocalPoint, to: LocalPoint) { log.add("seg") }
        override fun dot(stroke: LocalStroke, at: LocalPoint) { log.add("dot") }
        override fun committed(stroke: LocalStroke) { log.add("commit") }
        override fun redraw(visible: List<LocalStroke>) { log.add("redraw") }
    }

    private class ManualFrames : FrameScheduler {
        var pending: (() -> Unit)? = null
        var requests = 0
        override fun requestFrame(callback: () -> Unit) { requests++; pending = callback }
        fun pump() { val c = pending; pending = null; c?.invoke() }
    }

    /** PROTOCOL.md section 12.1, row laser_point: (600, 800), intensity 1.0, decay 0.5 s. */
    private val goldenHex = "da0130001000000040e2cfeeb540060000001644000048440000803f0000003f"
    private val manifest: JSONObject = JSONObject(
        requireNotNull(javaClass.classLoader?.getResourceAsStream("solstream-v1.json")) { "golden manifest missing" }
            .readBytes().toString(Charsets.UTF_8)
    )
    private val ts = manifest.getLong("timestamp_us")

    private val transport = FakeTransport()
    private val frames = ManualFrames()
    private val sink = FakeSink()
    private val session = StrokeSession(transport, Encoder { ts }, sink, frames) { UUID(0L, 1L) }
    private val laser = LaserPointer(transport, Encoder { ts }, frames) { session.page }

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 0xFF) }
    private fun unhex(s: String): ByteArray = ByteArray(s.length / 2) { i -> s.substring(i * 2, i * 2 + 2).toInt(16).toByte() }

    private fun goldenFromManifest(): String {
        val arr = manifest.getJSONArray("cases")
        for (i in 0 until arr.length()) {
            val c = arr.getJSONObject(i)
            if (c.getString("name") == "laser_point") return c.getString("hex")
        }
        throw AssertionError("laser_point missing from the golden manifest")
    }

    @Test
    fun contactAtTheCanvasCentreEncodesTheGoldenVector() {
        assertEquals("PROTOCOL.md and the manifest agree", goldenHex, goldenFromManifest())
        session.setViewSize(1200, 1600)                    // one view pixel per canvas unit
        laser.contact(600f, 800f)
        frames.pump()
        val bytes = transport.sent.single()
        assertEquals(goldenHex, hex(bytes))
        val f = Frame(bytes)
        val golden = Frame(unhex(goldenHex))
        assertEquals(SolStream.Op.LASER_POINT, f.opcode)
        assertEquals(golden.opcode, f.opcode)
        assertEquals(16, f.payloadLen)
        assertEquals(golden.payloadLen, f.payloadLen)
        assertEquals(hex(unhex(goldenHex).copyOfRange(SolStream.HEADER_LEN, unhex(goldenHex).size)), hex(bytes.copyOfRange(SolStream.HEADER_LEN, bytes.size)))
        assertEquals(600f, f.f32(), 0f)
        assertEquals(800f, f.f32(), 0f)
        assertEquals(LaserPointer.CONTACT_INTENSITY, f.f32(), 0f)
        assertEquals(LaserPointer.DECAY_S, f.f32(), 0f)
    }

    @Test
    fun contactIsFullIntensityAndHoverIsHalf() {
        assertEquals(1.0f, LaserPointer.CONTACT_INTENSITY, 0f)
        assertEquals(0.5f, LaserPointer.HOVER_INTENSITY, 0f)
        assertEquals(0.5f, LaserPointer.DECAY_S, 0f)
        assertEquals(1.0f, LaserPointer.intensity(contact = true), 0f)
        assertEquals(0.5f, LaserPointer.intensity(contact = false), 0f)
        session.setViewSize(1200, 1600)
        laser.hover(100f, 200f)
        frames.pump()
        laser.contact(300f, 400f)
        frames.pump()
        val (hover, contact) = transport.sent.map { Frame(it) }
        assertEquals(100f, hover.f32(), 0f); assertEquals(200f, hover.f32(), 0f)
        assertEquals(0.5f, hover.f32(), 0f); assertEquals(0.5f, hover.f32(), 0f)
        assertEquals(300f, contact.f32(), 0f); assertEquals(400f, contact.f32(), 0f)
        assertEquals(1.0f, contact.f32(), 0f); assertEquals(0.5f, contact.f32(), 0f)
    }

    @Test
    fun positionsMapToCanvasUnitsLikeStrokePoints() {
        session.setViewSize(600, 800)                      // half size: two canvas units per view pixel
        laser.contact(150f, 400f)
        frames.pump()
        val f = Frame(transport.sent.single())
        assertEquals(session.page.toCanvasX(150f), f.f32(), 0f)
        assertEquals(session.page.toCanvasY(400f), f.f32(), 0f)
        assertEquals(300f, session.page.toCanvasX(150f), 1e-4f)
        assertEquals(800f, session.page.toCanvasY(400f), 1e-4f)
    }

    @Test
    fun movesWithinOneFrameCoalesceToTheNewestPoint() {
        session.setViewSize(1200, 1600)
        laser.contact(10f, 10f)
        laser.hover(20f, 20f)
        laser.contact(30f, 40f)
        assertEquals("one frame request for the whole burst", 1, frames.requests)
        assertTrue(transport.sent.isEmpty())
        assertTrue(laser.isPending)
        frames.pump()
        val f = Frame(transport.sent.single())
        assertEquals(30f, f.f32(), 0f)
        assertEquals(40f, f.f32(), 0f)
        assertEquals(LaserPointer.CONTACT_INTENSITY, f.f32(), 0f)
        assertFalse(laser.isPending)
        // An empty frame sends nothing; the next move asks for the next frame.
        laser.onFrame()
        assertEquals(1, transport.sent.size)
        laser.hover(50f, 60f)
        assertEquals(2, frames.requests)
        frames.pump()
        assertEquals(2, transport.sent.size)
    }

    @Test
    fun nothingIsSentUntilTheMacAcceptsInkOrAfterAReset() {
        session.setViewSize(1200, 1600)
        transport.inkAllowed = false
        laser.contact(600f, 800f)
        frames.pump()
        assertTrue(transport.sent.isEmpty())
        transport.inkAllowed = true
        laser.contact(600f, 800f)
        laser.reset()                                      // another tool was selected before the frame
        frames.pump()
        assertTrue(transport.sent.isEmpty())
    }

    @Test
    fun theLaserNeverMakesAStrokeOrTouchesUndo() {
        session.setViewSize(1200, 1600)
        session.applyState(2, 1, 0, 2)
        val toolBefore = session.tool
        for (i in 0 until 20) {
            laser.contact(100f + i, 100f + i)
            laser.hover(200f + i, 200f + i)
            frames.pump()
        }
        assertEquals(20, transport.sent.size)
        assertTrue(transport.sent.all { Frame(it).opcode == SolStream.Op.LASER_POINT })
        assertTrue(session.history.isEmpty())
        assertEquals(0, session.visibleCount)
        assertFalse(session.isDrawing)
        assertEquals(null, session.currentStrokeForWet())
        assertEquals(2, session.undoDepth)
        assertEquals(1, session.redoDepth)
        assertEquals(toolBefore, session.tool)
        assertTrue("no wet or dry ink", sink.log.isEmpty())
        assertTrue(Tools.LASER != Tools.PEN && Tools.LASER != Tools.HIGHLIGHTER && Tools.LASER != Tools.ERASER)
    }
}
