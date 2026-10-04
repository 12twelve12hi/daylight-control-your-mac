package com.twelve.daylight.ink

import com.twelve.daylight.ink.ink.FrameScheduler
import com.twelve.daylight.ink.ink.InkSink
import com.twelve.daylight.ink.ink.LocalPoint
import com.twelve.daylight.ink.ink.LocalStroke
import com.twelve.daylight.ink.ink.StrokeSession
import com.twelve.daylight.ink.ink.Tools
import com.twelve.daylight.ink.ink.Transport
import com.twelve.daylight.ink.protocol.Encoder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * MainActivity recreation (the front-buffer setting's `recreate()`, ActivityScenario.recreate in the instrumented
 * tests): the new instance's session takes over the old one's strokes, page, tool and sync counters.
 */
class StrokeSessionRestoreTest {
    private class FakeTransport : Transport {
        val sent = ArrayList<ByteArray>()
        override var inkAllowed = true
        override fun send(frame: ByteArray): Boolean { sent.add(frame); return true }
        override fun queueBytes(): Long = 0L
    }

    private class FakeSink : InkSink {
        var redraws = 0
        var lastRedraw: List<LocalStroke> = emptyList()
        override fun segment(stroke: LocalStroke, from: LocalPoint, to: LocalPoint) {}
        override fun dot(stroke: LocalStroke, at: LocalPoint) {}
        override fun committed(stroke: LocalStroke) {}
        override fun redraw(visible: List<LocalStroke>) { redraws++; lastRedraw = ArrayList(visible) }
    }

    private object NoFrames : FrameScheduler {
        override fun requestFrame(callback: () -> Unit) {}
    }

    private fun session(sink: InkSink = FakeSink(), t: Transport = FakeTransport()): StrokeSession =
        StrokeSession(t, Encoder { 1L }, sink, NoFrames).also { it.setViewSize(1200, 1600) }

    private fun draw(s: StrokeSession, x: Float) {
        s.down(x, 100f, 0.5f, 0L)
        s.point(x + 50f, 120f, 0.6f, 8L)
        s.point(x + 100f, 140f, 0.7f, 16L)
        s.up()
    }

    @Test
    fun aRestoredSessionShowsTheSameStrokesAndRedrawsThem() {
        val old = session()
        draw(old, 100f)
        draw(old, 300f)
        old.tool = Tools.HIGHLIGHTER
        val sink = FakeSink()
        val fresh = session(sink)
        fresh.restore(old.snapshot())
        assertEquals(2, fresh.visibleCount)
        assertEquals(old.visible.map { it.id }, fresh.visible.map { it.id })
        assertEquals(Tools.HIGHLIGHTER, fresh.tool)
        assertEquals(old.pageId, fresh.pageId)
        assertEquals(1, sink.redraws)
        assertEquals(old.visible.map { it.id }, sink.lastRedraw.map { it.id })
    }

    @Test
    fun theSnapshotIsACopyNotALiveView() {
        val old = session()
        draw(old, 100f)
        val snap = old.snapshot()
        draw(old, 300f)
        assertEquals(1, snap.history.size)
    }

    @Test
    fun syncCountersTravelSoAStaleStateStillCannotHideAFreshStroke() {
        // Before recreation: one stroke synced, a second one not yet seen by the Mac.
        val old = session()
        draw(old, 100f)
        old.applyState(undoDepth = 1, redoDepth = 0, pageIndex = 0, strokeCount = 1)
        draw(old, 300f)
        val fresh = session()
        fresh.restore(old.snapshot())
        // The stale 1 Hz STATE (depth 1) arrives after the recreation: the unsynced stroke stays visible.
        fresh.applyState(undoDepth = 1, redoDepth = 0, pageIndex = 0, strokeCount = 1)
        assertEquals(2, fresh.visibleCount)
        fresh.applyState(undoDepth = 2, redoDepth = 0, pageIndex = 0, strokeCount = 2)
        assertEquals(2, fresh.visibleCount)
    }

    @Test
    fun anOpenStrokeOfTheNewSessionIsCancelledByARestore() {
        val old = session()
        draw(old, 100f)
        val fresh = session()
        fresh.down(500f, 500f, 0.5f, 0L)
        assertTrue(fresh.isDrawing)
        fresh.restore(old.snapshot())
        assertFalse(fresh.isDrawing)
        assertEquals(1, fresh.visibleCount)
    }

    @Test
    fun aNewStrokeAfterARestoreAppendsToTheRestoredPage() {
        val old = session()
        draw(old, 100f)
        val fresh = session()
        fresh.restore(old.snapshot())
        draw(fresh, 300f)
        assertEquals(2, fresh.visibleCount)
        assertEquals(old.visible[0].id, fresh.visible[0].id)
    }
}
