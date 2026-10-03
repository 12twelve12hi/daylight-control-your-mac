package com.twelve.daylight.ink.ink

import com.twelve.daylight.ink.protocol.Encoder
import com.twelve.daylight.ink.protocol.SolStream
import com.twelve.daylight.ink.protocol.WirePoint
import java.util.UUID

/** Where frames go. Implemented by InkConnection; faked in the JVM tests. */
interface Transport {
    /** False when the socket is closing or its queue overflowed (OkHttp semantics); the caller reconnects. */
    fun send(frame: ByteArray): Boolean
    /** Bytes queued and not yet written (OkHttp `queueSize()`); above [StrokeSession.THIN_QUEUE_BYTES] points are thinned. */
    fun queueBytes(): Long
    /** True only after HANDSHAKE_ACK status 0 (ink from a pending client would be dropped by the Mac anyway). */
    val inkAllowed: Boolean
}

/** Local feedback: the dry layer. All coordinates are canvas units; the view scales them. */
interface InkSink {
    fun segment(stroke: LocalStroke, from: LocalPoint, to: LocalPoint)
    fun dot(stroke: LocalStroke, at: LocalPoint)
    /** The stroke is complete; the wet layer may hand it over. */
    fun committed(stroke: LocalStroke)
    /** Something other than an append changed: redraw exactly these strokes (undo, redo, erase, cancel, clear). */
    fun redraw(visible: List<LocalStroke>)
}

/** One callback at the next display frame (Choreographer on the device, a manual pump in tests). */
interface FrameScheduler {
    fun requestFrame(callback: () -> Unit)
}

/**
 * The stroke state machine of SPEC E3 and PROTOCOL 6.3 to 6.8, free of Android classes.
 * Input arrives in view pixels (already filtered to stylus or eraser tool types by PenInput); points leave in
 * canvas units, batched one STROKE_CHUNK per frame unless [sendPerEvent] is on.
 */
class StrokeSession(
    private val transport: Transport,
    private val encoder: Encoder,
    private val sink: InkSink,
    private val frames: FrameScheduler,
    private val newId: () -> UUID = { UUID.randomUUID() },
) {
    companion object {
        /** ARCHITECTURE 3.4: OkHttp queue above 256 KiB -> thin points. */
        const val THIN_QUEUE_BYTES = 256L * 1024L
        const val MAX_POINTS_PER_CHUNK = SolStream.MAX_POINTS_PER_CHUNK
    }

    var tool: Int = Tools.PEN
    /** A/B setting (SPEC D49): one chunk per MotionEvent instead of one per frame. */
    var sendPerEvent: Boolean = false

    var page: PageRect = PageGeometry.fit(1200, 1600)
        private set
    var pageIndex: Int = 0
        private set
    var pageId: UUID = newId()
        private set

    /** Committed strokes in commit order; the first [visibleCount] are shown (the Mac's undo depth decides). */
    val history: MutableList<LocalStroke> = ArrayList()
    var visibleCount: Int = 0
        private set
    val visible: List<LocalStroke> get() = history.subList(0, visibleCount.coerceAtMost(history.size))

    /** Depths last reported by STATE (PROTOCOL 6.14); the toolbar enables undo and redo from them. */
    var undoDepth: Int = 0
        private set
    var redoDepth: Int = 0
        private set

    private var current: LocalStroke? = null
    private var currentStartSent = false
    private var strokeStartMs = 0L
    private var sentPoints = 0
    private val pending = ArrayList<WirePoint>(128)
    private var frameRequested = false
    /** A pen-down with pressure 0 (the side button pressed in the air): wait for a positive sample before starting. */
    private var waitingForPressure = false
    private var eraserTool = false
    private var eraseLastX = 0f
    private var eraseLastY = 0f
    private var eraseLastValid = false

    val isDrawing: Boolean get() = current != null || eraseLastValid

    /** The open pen or highlighter stroke, for the wet layer's segment colour and width (null while erasing or idle). */
    fun currentStrokeForWet(): LocalStroke? = current

    fun setViewSize(width: Int, height: Int) {
        page = PageGeometry.fit(width, height)
    }

    // ---- pen input (view pixels) ----

    /** ACTION_DOWN of a stylus or eraser pointer. `eraserPointer` is TOOL_TYPE_ERASER (the inverted pen). */
    fun down(viewX: Float, viewY: Float, rawPressure: Float, timeMs: Long, eraserPointer: Boolean = false) {
        if (current != null || eraseLastValid) cancel()
        eraserTool = eraserPointer || tool == Tools.ERASER
        val p = Pressure.normalize(rawPressure)
        if (p <= 0f) {
            waitingForPressure = true      // PROTOCOL 11: never a STROKE_START for a pressure-0 down
            return
        }
        waitingForPressure = false
        begin(viewX, viewY, p, timeMs)
    }

    /** One sample of ACTION_MOVE (history first, then current; the caller unpacks). */
    fun point(viewX: Float, viewY: Float, rawPressure: Float, timeMs: Long) {
        val p = Pressure.normalize(rawPressure)
        if (current == null && !eraseLastValid) {
            if (waitingForPressure && p > 0f) {
                waitingForPressure = false
                begin(viewX, viewY, p, timeMs)
            }
            return
        }
        val cx = page.toCanvasX(viewX)
        val cy = page.toCanvasY(viewY)
        if (eraserTool) {
            erase(cx, cy)
            return
        }
        val s = current ?: return
        val delta = (timeMs - strokeStartMs).coerceIn(0L, 65535L).toInt()
        val lp = LocalPoint(cx, cy, p, delta)
        val prev = s.points.last()
        s.points.add(lp)
        sink.segment(s, prev, lp)
        enqueue(lp)
    }

    /** ACTION_UP (or ACTION_POINTER_UP without FLAG_CANCELED). */
    fun up() {
        waitingForPressure = false
        if (eraseLastValid) {
            eraseLastValid = false
            eraserTool = false
            return
        }
        val s = current ?: return
        flush()
        if (currentStartSent) transport.send(encoder.strokeCommit(s.id, sentPoints))
        // A new stroke after an undo discards the redo tail (the Mac does the same).
        while (history.size > visibleCount) history.removeAt(history.size - 1)
        history.add(s)
        visibleCount = history.size
        current = null
        currentStartSent = false
        sink.committed(s)
    }

    /** ACTION_CANCEL or FLAG_CANCELED: STROKE_CANCEL, never a COMMIT (PROTOCOL 6.6). */
    fun cancel() {
        waitingForPressure = false
        eraseLastValid = false
        eraserTool = false
        val s = current ?: return
        pending.clear()
        if (currentStartSent) transport.send(encoder.strokeCancel(s.id))
        current = null
        currentStartSent = false
        sink.redraw(visible)
    }

    /** Choreographer frame: ship the points gathered since the last one as one STROKE_CHUNK. */
    fun onFrame() {
        frameRequested = false
        flush()
    }

    // ---- toolbar actions ----

    /** The Mac is the source of truth: nothing changes locally until STATE brings new depths (PROTOCOL 6.7). */
    fun undo() { transport.send(encoder.undo(null)) }
    fun redo() { transport.send(encoder.redo(null)) }

    /** SPEC 7 Clear: the Mac saves, clears both layers and returns to camera unless pinned. */
    fun clear() {
        if (current != null) cancel()
        transport.send(encoder.clear(null))
        history.clear()
        visibleCount = 0
        sink.redraw(visible)
    }

    /** SPEC 7 New page: the Mac saves the current page; the board stays up. */
    fun newPage() {
        if (current != null) cancel()
        pageIndex += 1
        pageId = newId()
        transport.send(encoder.pageChange(pageId, PageGeometry.CANVAS_WIDTH, PageGeometry.CANVAS_HEIGHT, pageIndex))
        history.clear()
        visibleCount = 0
        sink.redraw(visible)
    }

    /** STATE arrived: redraw from the Mac's depths (the two lists hold the same strokes in the same order). */
    fun applyState(undoDepth: Int, redoDepth: Int, pageIndex: Int) {
        this.undoDepth = undoDepth
        this.redoDepth = redoDepth
        if (pageIndex != this.pageIndex && history.isNotEmpty()) {
            // The Mac moved to another page (hotkey or another client): our strokes belong to the old one.
            history.clear()
        }
        this.pageIndex = pageIndex
        val newVisible = undoDepth.coerceIn(0, history.size)
        if (newVisible != visibleCount) {
            visibleCount = newVisible
            sink.redraw(visible)
        }
    }

    // ---- internals ----

    private fun begin(viewX: Float, viewY: Float, p: Float, timeMs: Long) {
        val cx = page.toCanvasX(viewX)
        val cy = page.toCanvasY(viewY)
        if (eraserTool) {
            eraseLastX = cx
            eraseLastY = cy
            eraseLastValid = true
            erase(cx, cy)
            return
        }
        val t = if (tool == Tools.ERASER) Tools.PEN else tool
        val s = LocalStroke(newId(), t, Tools.color(t), Tools.baseWidth(t))
        strokeStartMs = timeMs
        sentPoints = 0
        pending.clear()
        val first = LocalPoint(cx, cy, p, 0)
        s.points.add(first)
        current = s
        currentStartSent = transport.inkAllowed
        if (currentStartSent) transport.send(encoder.strokeStart(s.id, t, s.color, s.baseWidth, p))
        sink.dot(s, first)
        enqueue(first)
    }

    private fun enqueue(p: LocalPoint) {
        pending.add(WirePoint(p.x, p.y, p.pressure, p.deltaMs))
        if (sendPerEvent) {
            flush()
        } else if (!frameRequested) {
            frameRequested = true
            frames.requestFrame { onFrame() }
        }
    }

    private fun flush() {
        val s = current ?: run { pending.clear(); return }
        if (pending.isEmpty()) return
        if (!currentStartSent) { pending.clear(); return }
        if (transport.queueBytes() > THIN_QUEUE_BYTES && pending.size > 1) {
            // Back-pressure: keep the newest sample of this frame (and the stroke's first point, which carries delta 0).
            val last = pending.last()
            val first = pending.first()
            pending.clear()
            if (first.deltaMs == 0 && sentPoints == 0) pending.add(first)
            if (pending.isEmpty() || pending[0] !== last) pending.add(last)
        }
        var offset = 0
        while (offset < pending.size) {
            val end = (offset + MAX_POINTS_PER_CHUNK).coerceAtMost(pending.size)
            val slice = if (offset == 0 && end == pending.size) pending else pending.subList(offset, end)
            transport.send(encoder.strokeChunk(s.id, slice))
            sentPoints += slice.size
            offset = end
        }
        pending.clear()
    }

    private fun erase(cx: Float, cy: Float) {
        val hits = ArrayList<UUID>(4)
        var changed = false
        var i = 0
        while (i < history.size) {
            val s = history[i]
            if (i < visibleCount && s.hit(cx, cy, Tools.ERASER_RADIUS)) {
                hits.add(s.id)
                history.removeAt(i)
                visibleCount -= 1
                changed = true
            } else {
                i += 1
            }
        }
        if (transport.inkAllowed) {
            transport.send(encoder.erase(eraseLastX, eraseLastY, cx, cy, Tools.ERASER_RADIUS, hits.take(SolStream.MAX_ERASED_PER_MESSAGE)))
        }
        eraseLastX = cx
        eraseLastY = cy
        eraseLastValid = true
        if (changed) sink.redraw(visible)
    }
}
