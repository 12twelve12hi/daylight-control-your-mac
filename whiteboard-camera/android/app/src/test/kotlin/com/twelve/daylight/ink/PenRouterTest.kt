package com.twelve.daylight.ink

import com.twelve.daylight.ink.ink.FrameScheduler
import com.twelve.daylight.ink.ink.InkSink
import com.twelve.daylight.ink.ink.LaserPointer
import com.twelve.daylight.ink.ink.LocalPoint
import com.twelve.daylight.ink.ink.LocalStroke
import com.twelve.daylight.ink.ink.PenRouter
import com.twelve.daylight.ink.ink.StrokeSession
import com.twelve.daylight.ink.ink.Transport
import com.twelve.daylight.ink.protocol.Encoder
import com.twelve.daylight.ink.protocol.SolStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/**
 * The routing PenInput runs for every pen event (review F7 and F8), driven here with plain numbers through the real
 * [StrokeSession] and [LaserPointer]: a Laser tool event never reaches the stroke session; any contact is intensity
 * 1.0 (pressure 0 included), stylus hover 0.5, an eraser end in the air never points; picking Laser mid-stroke ends
 * the open stroke normally at its own pen-up (a STROKE_COMMIT with every point, never a STROKE_CANCEL). The web page
 * pins the same three rules in tests/unit/laser.test.ts.
 */
class PenRouterTest {
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

    /** Both the session and the laser ask for frames: every request is kept and a pump runs them all. */
    private class QueueFrames : FrameScheduler {
        private val queue = ArrayList<() -> Unit>()
        override fun requestFrame(callback: () -> Unit) { queue.add(callback) }
        fun pump() {
            val due = ArrayList(queue)
            queue.clear()
            for (c in due) c()
        }
    }

    private val transport = FakeTransport()
    private val frames = QueueFrames()
    private val sink = FakeSink()
    private val session = StrokeSession(transport, Encoder { 1L }, sink, frames) { UUID(0L, 7L) }
    private val laser = LaserPointer(transport, Encoder { 1L }, frames) { session.page }
    private val router = PenRouter(session).also { it.laser = laser }

    init {
        session.setViewSize(1200, 1600)                    // one view pixel per canvas unit
    }

    private fun ops(): List<Int> = transport.sent.map { Frame(it).opcode }
    private fun lasers(): List<Frame> = transport.sent.map { Frame(it) }.filter { it.opcode == SolStream.Op.LASER_POINT }

    /** x, y and intensity of a LASER_POINT (the decay follows). */
    private fun point(f: Frame): Triple<Float, Float, Float> = Triple(f.f32(), f.f32(), f.f32())

    @Test
    fun laserToolContactAndHoverNeverReachTheStrokeSession() {
        session.applyState(2, 1, 0, 2)
        val toolBefore = session.tool
        router.laserMode = true
        assertFalse("the laser takes the down", router.down(5, 100f, 100f, 0.6f, 0L, eraserPointer = false))
        assertTrue(router.laserTakesContact)
        for (i in 1..10) {
            router.laserMove(100f + i * 10, 100f + i * 5)
            frames.pump()
        }
        assertEquals(PenRouter.End.NONE, router.up(5, canceled = false))
        assertTrue(router.hover(stylus = true, move = true, viewX = 300f, viewY = 300f))
        frames.pump()
        assertFalse(router.down(6, 400f, 400f, 0.5f, 10L, eraserPointer = true))
        router.laserMove(410f, 410f)
        frames.pump()
        assertEquals(PenRouter.End.NONE, router.cancel())
        assertFalse(router.down(7, 500f, 500f, 0.9f, 20L, eraserPointer = false))
        frames.pump()
        assertEquals("a FLAG_CANCELED lift of the laser cancels nothing", PenRouter.End.NONE, router.up(7, canceled = true))

        assertTrue(transport.sent.size >= 13)
        assertTrue("only LASER_POINT on the wire", ops().all { it == SolStream.Op.LASER_POINT })
        assertTrue(session.history.isEmpty())
        assertEquals(0, session.visibleCount)
        assertFalse(session.isDrawing)
        assertNull(session.currentStrokeForWet())
        assertEquals(2, session.undoDepth)
        assertEquals(1, session.redoDepth)
        assertEquals(toolBefore, session.tool)
        assertTrue("no wet or dry ink", sink.log.isEmpty())
    }

    @Test
    fun anyContactIsFullIntensityStylusHoverHalfAndAnEraserEndInTheAirNeverPoints() {
        router.laserMode = true
        router.down(1, 10f, 10f, 0f, 0L, eraserPointer = false)          // rule 1: pressure 0 is still contact
        frames.pump()
        router.up(1, canceled = false)
        router.down(2, 20f, 20f, 0.8f, 1L, eraserPointer = true)         // rule 2: the eraser end on the glass
        frames.pump()
        router.up(2, canceled = false)
        assertTrue(router.hover(stylus = true, move = false, viewX = 25f, viewY = 25f))   // ENTER: consumed, nothing sent
        assertTrue(router.hover(stylus = true, move = true, viewX = 30f, viewY = 30f))
        frames.pump()
        assertFalse("an eraser end in the air never points", router.hover(stylus = false, move = true, viewX = 40f, viewY = 40f))
        frames.pump()
        val sent = lasers().map { point(it) }
        assertEquals(listOf(Triple(10f, 10f, 1.0f), Triple(20f, 20f, 1.0f), Triple(30f, 30f, 0.5f)), sent)
        assertFalse("the pressure-0 contact never armed a stroke", session.isDrawing)
        assertTrue(sink.log.isEmpty())
        // Another tool: hover is not the laser's and nothing more is sent.
        router.laserMode = false
        assertFalse(router.hover(stylus = true, move = true, viewX = 50f, viewY = 50f))
        frames.pump()
        assertEquals(3, transport.sent.size)
    }

    @Test
    fun pickingLaserMidStrokeEndsTheStrokeNormallyAtItsPenUp() {
        assertTrue(router.down(3, 100f, 100f, 0.5f, 0L, eraserPointer = false))
        assertTrue("the wet layer draws the segment", router.sample(150f, 120f, 0.5f, 10L))
        frames.pump()
        router.laserMode = true                                           // picked with the pen still down
        assertFalse("the open stroke keeps its contact", router.laserTakesContact)
        assertTrue(router.sample(200f, 140f, 0.5f, 20L))
        assertEquals(PenRouter.End.UP, router.up(3, canceled = false))
        frames.pump()

        val ops = ops()
        assertEquals(SolStream.Op.STROKE_START, ops.first())
        assertFalse("never a STROKE_CANCEL: the Mac keeps the stroke", ops.contains(SolStream.Op.STROKE_CANCEL))
        assertFalse(ops.contains(SolStream.Op.LASER_POINT))
        val commit = transport.sent.map { Frame(it) }.single { it.opcode == SolStream.Op.STROKE_COMMIT }
        commit.uuid()
        assertEquals("every point, the one after the switch included", 3L, commit.u32())
        assertEquals(1, session.history.size)
        assertEquals(3, session.history[0].points.size)
        assertEquals("commit", sink.log.last())

        // The stroke is over: the next contact is the laser's.
        assertTrue(router.laserTakesContact)
        assertFalse(router.down(3, 300f, 300f, 0.5f, 30L, eraserPointer = false))
        frames.pump()
        assertEquals(SolStream.Op.LASER_POINT, ops().last())
        assertEquals(1, session.history.size)
        assertFalse(session.isDrawing)
    }

    @Test
    fun anOpenStrokeCancelledBySystemAfterTheSwitchIsStillACancel() {
        // ACTION_CANCEL (the system took the gesture) is a real cancel, Laser or not.
        assertTrue(router.down(4, 100f, 100f, 0.5f, 0L, eraserPointer = false))
        router.sample(150f, 150f, 0.5f, 10L)
        router.laserMode = true
        assertEquals(PenRouter.End.CANCEL, router.cancel())
        assertTrue(ops().contains(SolStream.Op.STROKE_CANCEL))
        assertTrue(session.history.isEmpty())
    }

    @Test
    fun pickingAnotherToolWhileTheLaserTouchesDrawsNothingUntilTheNextDown() {
        router.laserMode = true
        router.down(9, 100f, 100f, 0.7f, 0L, eraserPointer = false)
        frames.pump()
        router.laserMode = false
        assertEquals("that contact ends here", -1, router.penPointerId)
        assertEquals(PenRouter.End.NONE, router.up(9, canceled = false))
        assertTrue(session.history.isEmpty())
        assertFalse(session.isDrawing)
        assertTrue(router.down(10, 200f, 200f, 0.7f, 10L, eraserPointer = false))
        router.sample(250f, 250f, 0.7f, 20L)
        assertEquals(PenRouter.End.UP, router.up(10, canceled = false))
        frames.pump()
        assertEquals(1, session.history.size)
        assertEquals(1, lasers().size)
    }
}
