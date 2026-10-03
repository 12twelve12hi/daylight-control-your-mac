package com.twelve.daylight.ink

import com.twelve.daylight.ink.ink.FrameScheduler
import com.twelve.daylight.ink.ink.InkSink
import com.twelve.daylight.ink.ink.LocalPoint
import com.twelve.daylight.ink.ink.LocalStroke
import com.twelve.daylight.ink.ink.MotionLike
import com.twelve.daylight.ink.ink.MotionSamples
import com.twelve.daylight.ink.ink.PageGeometry
import com.twelve.daylight.ink.ink.Pressure
import com.twelve.daylight.ink.ink.StrokeSession
import com.twelve.daylight.ink.ink.Tools
import com.twelve.daylight.ink.ink.Transport
import com.twelve.daylight.ink.protocol.Encoder
import com.twelve.daylight.ink.protocol.SolStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/** SPEC 16 E3 and the numbers of PROTOCOL 4, 6.3, 6.4, 6.6, 6.8. */
class StrokeSessionTest {
    private class FakeTransport : Transport {
        val sent = ArrayList<ByteArray>()
        var queue = 0L
        override var inkAllowed = true
        override fun send(frame: ByteArray): Boolean { sent.add(frame); return true }
        override fun queueBytes(): Long = queue
        fun ops() = Frames.opcodes(sent)
        fun frames(op: Int) = sent.filter { Frame(it).opcode == op }.map { Frame(it) }
    }

    private class FakeSink : InkSink {
        val log = ArrayList<String>()
        var lastRedraw: List<LocalStroke>? = null
        override fun segment(stroke: LocalStroke, from: LocalPoint, to: LocalPoint) { log.add("seg") }
        override fun dot(stroke: LocalStroke, at: LocalPoint) { log.add("dot") }
        override fun committed(stroke: LocalStroke) { log.add("commit") }
        override fun redraw(visible: List<LocalStroke>) { log.add("redraw"); lastRedraw = ArrayList(visible) }
    }

    private class ManualFrames : FrameScheduler {
        var pending: (() -> Unit)? = null
        var requests = 0
        override fun requestFrame(callback: () -> Unit) { requests++; pending = callback }
        fun pump() { val c = pending; pending = null; c?.invoke() }
    }

    private val ts = 1760000000123456L
    private var idCounter = 0
    private fun ids(): UUID = UUID.fromString("00010203-0405-0607-0809-0a0b0c0d0e%02x".format(idCounter++))

    private fun session(): Triple<StrokeSession, FakeTransport, FakeSink> {
        val t = FakeTransport()
        val s = FakeSink()
        frames = ManualFrames()
        val session = StrokeSession(t, Encoder { ts }, s, frames) { ids() }
        session.setViewSize(1200, 1600)
        return Triple(session, t, s)
    }
    private lateinit var frames: ManualFrames

    @Test
    fun historySamplesComeBeforeTheCurrentOneInOrder() {
        val e = object : MotionLike {
            override val historySize = 2
            override fun historicalX(pointerIndex: Int, pos: Int) = 10f * (pos + 1)
            override fun historicalY(pointerIndex: Int, pos: Int) = 1f
            override fun historicalPressure(pointerIndex: Int, pos: Int) = 0.5f
            override fun historicalEventTime(pos: Int) = 100L + pos
            override fun x(pointerIndex: Int) = 30f
            override fun y(pointerIndex: Int) = 1f
            override fun pressure(pointerIndex: Int) = 0.7f
            override val eventTime = 102L
        }
        val samples = MotionSamples.unpack(e, 0)
        assertEquals(listOf(10f, 20f, 30f), samples.map { it.x })
        assertEquals(listOf(100L, 101L, 102L), samples.map { it.timeMs })
        assertEquals(0.7f, samples.last().pressure, 0f)
    }

    @Test
    fun strokeStartIs31BytesStylusContactWithTheFirstPressure() {
        val (s, t, _) = session()
        s.down(10.5f, 20f, 0.73f, 1000)
        val f = t.frames(SolStream.Op.STROKE_START).single()
        assertEquals(16 + 31, f.size)
        f.uuid()
        assertEquals(Tools.PEN, f.u8())
        assertEquals(Tools.PEN_COLOR, f.i32())
        assertEquals(3.2f, f.f32(), 0f)
        assertEquals(0, f.u8())       // pointer_type stylus
        assertEquals(1, f.u8())       // phase contact
        assertEquals(0.73f, f.f32(), 1e-6f)
    }

    @Test
    fun deltaMsCountsFromTheFirstPointAndSaturates() {
        val (s, t, _) = session()
        s.down(0f, 0f, 0.5f, 1000)
        s.point(1f, 1f, 0.5f, 1008)
        s.point(2f, 2f, 0.5f, 1020)
        s.point(3f, 3f, 0.5f, 1000 + 70000)
        frames.pump()
        val pts = t.frames(SolStream.Op.STROKE_CHUNK).single().chunkPoints()
        assertEquals(listOf(0, 8, 20, 65535), pts.map { it.deltaMs })
    }

    @Test
    fun pressureIsNormalisedForUnitAndRawRanges() {
        assertEquals(0.5f, Pressure.normalize(0.5f), 0f)
        assertEquals(1f, Pressure.normalize(1f), 0f)
        assertEquals(1f, Pressure.normalize(4095f), 0f)
        assertEquals(0.5f, Pressure.normalize(2047.5f), 1e-6f)
        assertEquals(0f, Pressure.normalize(-0.1f), 0f)
        assertEquals(0f, Pressure.normalize(Float.NaN), 0f)
        assertTrue(Pressure.looksRaw(2f))
        assertFalse(Pressure.looksRaw(1f))
        val (s, t, _) = session()
        s.down(0f, 0f, 2047.5f, 0)
        s.point(1f, 0f, 4095f, 1)
        s.point(2f, 0f, 0.2f, 2)
        frames.pump()
        val pts = t.frames(SolStream.Op.STROKE_CHUNK).single().chunkPoints()
        assertEquals(listOf(128, 255, 51), pts.map { it.pressure })
    }

    @Test
    fun pointsAreCanvasUnitsTimes32() {
        val (s, t, _) = session()
        s.setViewSize(600, 800)                 // half-size view: canvas x = view x * 2
        s.down(5.25f, -1.625f, 0.5f, 0)
        frames.pump()
        val p = t.frames(SolStream.Op.STROKE_CHUNK).single().chunkPoints().single()
        assertEquals(336, p.x32)                // 10.5 * 32
        assertEquals(-104, p.y32)               // -3.25 * 32
    }

    @Test
    fun cancelSendsStrokeCancelAndNoCommit() {
        val (s, t, sink) = session()
        s.down(0f, 0f, 0.5f, 0)
        s.point(1f, 1f, 0.5f, 5)
        s.cancel()
        assertEquals(listOf(SolStream.Op.STROKE_START, SolStream.Op.STROKE_CANCEL), t.ops())
        assertEquals(0, s.history.size)
        assertEquals("redraw", sink.log.last())
        frames.pump()
        assertEquals(2, t.sent.size)            // the pending points were dropped with the stroke
    }

    @Test
    fun upFlushesThenCommitsWithThePointCount() {
        val (s, t, sink) = session()
        s.down(0f, 0f, 0.5f, 0)
        s.point(1f, 1f, 0.5f, 5)
        s.point(2f, 2f, 0.5f, 9)
        s.up()
        assertEquals(listOf(SolStream.Op.STROKE_START, SolStream.Op.STROKE_CHUNK, SolStream.Op.STROKE_COMMIT), t.ops())
        val commit = t.frames(SolStream.Op.STROKE_COMMIT).single()
        commit.uuid()
        assertEquals(3L, commit.u32())
        assertEquals(1, s.history.size)
        assertEquals(1, s.visibleCount)
        assertEquals("commit", sink.log.last())
    }

    @Test
    fun perFrameBatchingByDefaultPerEventWhenAsked() {
        val (s, t, _) = session()
        s.down(0f, 0f, 0.5f, 0)
        s.point(1f, 1f, 0.5f, 1)
        s.point(2f, 2f, 0.5f, 2)
        assertEquals(0, t.frames(SolStream.Op.STROKE_CHUNK).size)
        assertEquals(1, frames.requests)
        frames.pump()
        val chunks = t.frames(SolStream.Op.STROKE_CHUNK)
        assertEquals(1, chunks.size)
        assertEquals(3, chunks[0].chunkPoints().size)

        val (s2, t2, _) = session()
        s2.sendPerEvent = true
        s2.down(0f, 0f, 0.5f, 0)
        s2.point(1f, 1f, 0.5f, 1)
        s2.point(2f, 2f, 0.5f, 2)
        assertEquals(3, t2.frames(SolStream.Op.STROKE_CHUNK).size)
        assertEquals(0, frames.requests)
    }

    @Test
    fun aPressureZeroDownNeverStartsAStrokeUntilPressureArrives() {
        val (s, t, sink) = session()
        s.down(0f, 0f, 0f, 0)                   // side button pressed in the air
        s.point(1f, 1f, 0f, 1)
        assertTrue(t.sent.isEmpty())
        assertTrue(sink.log.isEmpty())
        s.up()
        assertTrue(t.sent.isEmpty())
        s.down(0f, 0f, 0f, 10)
        s.point(1f, 1f, 0.4f, 12)               // the first positive sample starts the stroke
        assertEquals(listOf(SolStream.Op.STROKE_START), t.ops())
        val start = t.frames(SolStream.Op.STROKE_START).single()
        start.uuid(); start.u8(); start.i32(); start.f32(); start.u8(); start.u8()
        assertEquals(0.4f, start.f32(), 1e-6f)
    }

    @Test
    fun backPressureThinsToTheNewestPointPerFrame() {
        val (s, t, _) = session()
        s.down(0f, 0f, 0.5f, 0)
        frames.pump()                           // the first point goes out alone
        t.queue = StrokeSession.THIN_QUEUE_BYTES + 1
        s.point(1f, 1f, 0.5f, 1)
        s.point(2f, 2f, 0.5f, 2)
        s.point(3f, 3f, 0.5f, 3)
        frames.pump()
        val chunks = t.frames(SolStream.Op.STROKE_CHUNK)
        assertEquals(2, chunks.size)
        val thinned = chunks[1].chunkPoints()
        assertEquals(1, thinned.size)
        assertEquals(3 * 32, thinned[0].x32)
        s.up()
        val commit = t.frames(SolStream.Op.STROKE_COMMIT).single()
        commit.uuid()
        assertEquals(2L, commit.u32())           // point_count is what was sent
    }

    @Test
    fun chunksSplitAt4096Points() {
        val (s, t, _) = session()
        s.down(0f, 0f, 0.5f, 0)
        for (i in 1..4100) s.point(i.toFloat(), 0f, 0.5f, i.toLong())
        frames.pump()
        val chunks = t.frames(SolStream.Op.STROKE_CHUNK)
        assertEquals(2, chunks.size)
        assertEquals(4096, chunks[0].chunkPoints().size)
        assertEquals(5, chunks[1].chunkPoints().size)
    }

    @Test
    fun eraserSendsEraseStrokesWithRadius12AndRemovesHitsLocally() {
        val (s, t, sink) = session()
        s.down(100f, 100f, 0.5f, 0); s.point(200f, 100f, 0.5f, 5); s.up()       // stroke along y = 100
        s.down(100f, 400f, 0.5f, 10); s.point(200f, 400f, 0.5f, 15); s.up()     // stroke along y = 400
        t.sent.clear()
        s.tool = Tools.ERASER
        s.down(150f, 95f, 0.5f, 20)
        s.point(160f, 95f, 0.5f, 22)
        s.up()
        val erases = t.frames(SolStream.Op.ERASE_STROKES)
        assertEquals(2, erases.size)
        assertTrue(t.frames(SolStream.Op.STROKE_START).isEmpty())
        val e = erases[0]
        assertEquals(150f, e.f32(), 0f); assertEquals(95f, e.f32(), 0f)
        assertEquals(150f, e.f32(), 0f); assertEquals(95f, e.f32(), 0f)
        assertEquals(12f, e.f32(), 0f)
        assertEquals(1, e.u16())
        assertEquals(1, s.history.size)
        assertEquals(400f, s.history[0].points[0].y, 0f)
        assertEquals(1, sink.lastRedraw!!.size)
        val e2 = erases[1]
        e2.f32(); e2.f32(); e2.f32(); e2.f32(); e2.f32()
        assertEquals(0, e2.u16())               // nothing left to hit
    }

    @Test
    fun invertedPenPointerErasesWhateverTheToolbarSays() {
        val (s, t, _) = session()
        s.down(100f, 100f, 0.5f, 0); s.point(200f, 100f, 0.5f, 5); s.up()
        t.sent.clear()
        s.tool = Tools.PEN
        s.down(150f, 100f, 0.5f, 20, eraserPointer = true)
        s.up()
        assertEquals(listOf(SolStream.Op.ERASE_STROKES), t.ops())
        assertEquals(0, s.history.size)
    }

    @Test
    fun undoAndRedoWaitForTheMacsDepths() {
        val (s, t, sink) = session()
        s.down(0f, 0f, 0.5f, 0); s.up()
        s.down(10f, 10f, 0.5f, 10); s.up()
        sink.log.clear(); t.sent.clear()
        s.undo()
        assertEquals(listOf(SolStream.Op.UNDO), t.ops())
        val undo = t.frames(SolStream.Op.UNDO).single()
        assertEquals(SolStream.ZERO_UUID, undo.uuid())   // all-zero page id = current page
        assertEquals(ts, undo.u64())
        assertEquals(2, s.visibleCount)                   // nothing local yet
        assertTrue(sink.log.isEmpty())
        s.applyState(undoDepth = 1, redoDepth = 1, pageIndex = 0)
        assertEquals(1, s.visibleCount)
        assertEquals(listOf("redraw"), sink.log)
        assertEquals(1, sink.lastRedraw!!.size)
        s.redo()
        assertEquals(SolStream.Op.REDO, Frame(t.sent.last()).opcode)
        s.applyState(undoDepth = 2, redoDepth = 0, pageIndex = 0)
        assertEquals(2, s.visibleCount)
        assertEquals(2, s.undoDepth)
        assertEquals(0, s.redoDepth)
    }

    @Test
    fun aNewStrokeAfterAnUndoDropsTheRedoTail() {
        val (s, _, _) = session()
        s.down(0f, 0f, 0.5f, 0); s.up()
        s.down(1f, 1f, 0.5f, 1); s.up()
        s.undo()
        s.applyState(undoDepth = 1, redoDepth = 1, pageIndex = 0)
        s.down(2f, 2f, 0.5f, 2); s.up()
        assertEquals(2, s.history.size)
        assertEquals(2f, s.history[1].points[0].x, 0f)
    }

    @Test
    fun clearAndNewPageSendTheirOpcodesAndBlankTheLocalList() {
        val (s, t, sink) = session()
        s.down(0f, 0f, 0.5f, 0); s.up()
        t.sent.clear()
        s.clear()
        assertEquals(listOf(SolStream.Op.CLEAR_CANVAS), t.ops())
        assertEquals(16 + 24, t.sent[0].size)
        assertEquals(0, s.visibleCount)
        assertEquals(0, sink.lastRedraw!!.size)
        t.sent.clear()
        s.newPage()
        val pc = t.frames(SolStream.Op.PAGE_CHANGE).single()
        assertEquals(16 + 28, pc.size)
        assertEquals(s.pageId, pc.uuid())
        assertEquals(1200f, pc.f32(), 0f)
        assertEquals(1600f, pc.f32(), 0f)
        assertEquals(1L, pc.u32())
        assertEquals(1, s.pageIndex)
    }

    @Test
    fun nothingLeavesWhileThePendingAllowButLocalInkStillShows() {
        val (s, t, sink) = session()
        t.inkAllowed = false
        s.down(0f, 0f, 0.5f, 0)
        s.point(1f, 1f, 0.5f, 1)
        frames.pump()
        s.up()
        assertTrue(t.sent.isEmpty())
        assertEquals(listOf("dot", "seg", "commit"), sink.log)
        assertEquals(1, s.history.size)
    }

    @Test
    fun pageGeometryLetterboxesThreeByFour() {
        val full = PageGeometry.fit(1200, 1600)
        assertEquals(0f, full.left, 0f); assertEquals(1200f, full.width, 0f); assertEquals(1600f, full.height, 0f)
        val shortView = PageGeometry.fit(1200, 1400)      // height-limited: 1050 x 1400, 75 px cream each side
        assertEquals(1400f, shortView.height, 0f); assertEquals(1050f, shortView.width, 0f); assertEquals(75f, shortView.left, 0f); assertEquals(0f, shortView.top, 0f)
        val narrow = PageGeometry.fit(900, 1600)           // width-limited: 900 x 1200, 200 px cream top and bottom
        assertEquals(900f, narrow.width, 0f); assertEquals(1200f, narrow.height, 0f); assertEquals(200f, narrow.top, 0f)
        assertEquals(600f, narrow.toCanvasX(450f), 1e-4f)
        assertEquals(800f, narrow.toCanvasY(800f), 1e-4f)
        assertEquals(0.75f, narrow.scale, 0f)
        assertEquals(1184f, PageGeometry.fit(1184, 1584).width, 0f)    // the SolOS viewport (1184 x 1584) is a hair taller than 3:4: width-limited
        assertEquals(Tools.PEN_WIDTH * 1.45f, Tools.segmentWidth(Tools.PEN_WIDTH, 1f), 1e-6f)
        assertEquals(Tools.PEN_WIDTH * 0.55f, Tools.segmentWidth(Tools.PEN_WIDTH, 0f), 1e-6f)
    }
}

class StrokeSessionStateTest {
    private class FakeTransport : com.twelve.daylight.ink.ink.Transport {
        val sent = ArrayList<ByteArray>()
        override var inkAllowed = true
        override fun send(frame: ByteArray): Boolean { sent.add(frame); return true }
        override fun queueBytes(): Long = 0L
    }
    private class FakeSink : InkSink {
        var redraws = 0
        var lastRedraw: List<LocalStroke>? = null
        override fun segment(stroke: LocalStroke, from: LocalPoint, to: LocalPoint) {}
        override fun dot(stroke: LocalStroke, at: LocalPoint) {}
        override fun committed(stroke: LocalStroke) {}
        override fun redraw(visible: List<LocalStroke>) { redraws++; lastRedraw = ArrayList(visible) }
    }
    private val frames = object : FrameScheduler { override fun requestFrame(callback: () -> Unit) { callback() } }

    private fun twoStrokes(): Triple<StrokeSession, FakeTransport, FakeSink> {
        val t = FakeTransport(); val k = FakeSink()
        val s = StrokeSession(t, Encoder { 0L }, k, frames)
        s.setViewSize(1200, 1600)
        s.down(0f, 0f, 0.5f, 0); s.up()
        s.down(1f, 1f, 0.5f, 1); s.up()
        return Triple(s, t, k)
    }

    @Test
    fun aStateBetweenStartAndCommitNeverHidesTheFreshStroke() {
        val (s, _, k) = twoStrokes()
        k.redraws = 0
        s.applyState(undoDepth = 1, redoDepth = 0, pageIndex = 0, strokeCount = 1)   // the Mac has not seen the COMMIT yet
        assertEquals(2, s.visibleCount)
        assertEquals(0, k.redraws)
        s.applyState(undoDepth = 2, redoDepth = 0, pageIndex = 0, strokeCount = 2)
        assertEquals(2, s.visibleCount)
        assertEquals(0, k.redraws)
    }

    @Test
    fun ourOwnUndoIsHonouredEvenWhenOutOfSync() {
        val (s, _, k) = twoStrokes()                                                    // two commits, no STATE yet
        s.undo()
        s.applyState(undoDepth = 1, redoDepth = 1, pageIndex = 0, strokeCount = 1)
        assertEquals(1, s.visibleCount)
        assertEquals(1, k.lastRedraw!!.size)
    }

    @Test
    fun aDecreaseWhileInSyncIsTrustedAndWhileOutOfSyncIsNot() {
        val (s, _, k) = twoStrokes()
        s.applyState(undoDepth = 2, redoDepth = 0, pageIndex = 0, strokeCount = 2)   // in sync now
        s.applyState(undoDepth = 1, redoDepth = 1, pageIndex = 0, strokeCount = 1)   // the Mac really has fewer
        assertEquals(1, s.visibleCount)
        s.down(7f, 7f, 0.5f, 7); s.up()                                                 // out of sync again
        k.redraws = 0
        s.applyState(undoDepth = 1, redoDepth = 0, pageIndex = 0, strokeCount = 1)   // stale: our third stroke not counted yet
        assertEquals(2, s.visibleCount)
        assertEquals(0, k.redraws)
        s.applyState(undoDepth = 2, redoDepth = 0, pageIndex = 0, strokeCount = 2)
        assertEquals(2, s.visibleCount)
    }

    @Test
    fun aStaleEmptyStateAfterTheFirstCommitKeepsTheStroke() {
        val t = FakeTransport(); val k = FakeSink()
        val s = StrokeSession(t, Encoder { 0L }, k, frames)
        s.setViewSize(1200, 1600)
        s.applyState(0, 0, 0, 0)                                                        // the Mac's fresh page
        s.down(0f, 0f, 0.5f, 0); s.up()
        s.applyState(0, 0, 0, 0)                                                        // 1 Hz report from before the COMMIT
        assertEquals(1, s.visibleCount)
        assertEquals(1, s.history.size)
        s.applyState(1, 0, 0, 1)
        assertEquals(1, s.visibleCount)
    }

    @Test
    fun aStalePageIndexAfterOurNewPageIsIgnoredAndTheNewPageSurvives() {
        val (s, _, _) = twoStrokes()
        s.applyState(2, 0, 0, 2)
        s.newPage()                                                                     // page 1
        s.down(3f, 3f, 0.5f, 3); s.up()
        s.applyState(2, 0, 0, 2)                                                        // emitted before the PAGE_CHANGE arrived
        assertEquals(1, s.pageIndex)
        assertEquals(1, s.history.size)
        s.applyState(1, 0, 1, 1)                                                        // the Mac is on page 1 with our stroke
        assertEquals(1, s.visibleCount)
        assertEquals(1, s.history.size)
        s.applyState(0, 0, 2, 0)                                                        // somebody else turned the page
        assertEquals(2, s.pageIndex)
        assertEquals(0, s.history.size)
    }

    @Test
    fun anEmptyMacPageBlanksTheTablet() {
        val (s, _, k) = twoStrokes()
        s.applyState(undoDepth = 2, redoDepth = 0, pageIndex = 0, strokeCount = 2)   // in sync
        s.applyState(undoDepth = 0, redoDepth = 0, pageIndex = 0, strokeCount = 0)   // Clear from the Mac hotkey
        assertEquals(0, s.visibleCount)
        assertEquals(0, s.history.size)
        assertEquals(0, k.lastRedraw!!.size)
    }

    @Test
    fun aNewStrokeForgetsAnUnansweredUndo() {
        val (s, _, _) = twoStrokes()
        s.undo()                                                                        // dropped by the Mac, say
        s.down(5f, 5f, 0.5f, 5); s.up()
        s.applyState(undoDepth = 2, redoDepth = 0, pageIndex = 0, strokeCount = 2)   // in flight: the third COMMIT not yet counted
        assertEquals(3, s.visibleCount)
    }

    @Test
    fun aLargerDepthRevealsRedoneStrokes() {
        val (s, _, _) = twoStrokes()
        s.undo(); s.applyState(1, 1, 0, 1)
        s.redo(); s.applyState(2, 0, 0, 2)
        assertEquals(2, s.visibleCount)
    }
}
