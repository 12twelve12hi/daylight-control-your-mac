package com.twelve.daylight.ink.ink

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BlendMode
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.view.MotionEvent
import android.view.View
import com.twelve.daylight.ink.ui.Tokens
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * The dry layer: committed ink in a Bitmap the size of the page, one `invalidate(Rect)` per new segment
 * (research-android-ink 2.1 option A). Pen segments go straight into the bitmap; a highlighter stroke is kept as one
 * Path while wet and baked once on commit with BlendMode.MULTIPLY, so its own joints never darken.
 * The view is exactly the 3:4 page, so view pixels per canvas unit is `width / 1200`.
 */
class DryInkView(context: Context) : View(context), InkSink {
    private var bitmap: Bitmap? = null
    private var bitmapCanvas: Canvas? = null
    private var page = PageRect(0f, 0f, 1200f, 1600f)
    private var lastVisible: List<LocalStroke> = emptyList()

    private val paperPaint = Paint().apply { color = Tokens.PAPER_BG; style = Paint.Style.FILL }
    private val inkPaint = Paint().apply {
        isAntiAlias = true; style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
    }
    private val dotPaint = Paint().apply { isAntiAlias = true; style = Paint.Style.FILL }
    private val highlightPaint = Paint().apply {
        isAntiAlias = true; style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
        blendMode = BlendMode.MULTIPLY
    }
    private val wetPath = Path()
    private var wetStroke: LocalStroke? = null
    private val dirty = Rect()

    /** Strokes the bitmap is rebuilt from on a size change (read by the instrumented rotation test too). */
    val replayCount: Int get() = lastVisible.size

    /** Pen events reach whichever layer is on top; both hand them to the same router. */
    var input: PenInput? = null

    init {
        setBackgroundColor(Tokens.PAPER_BG)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w <= 0 || h <= 0) return
        page = PageRect(0f, 0f, w.toFloat(), h.toFloat())
        bitmap?.recycle()
        val b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        bitmap = b
        bitmapCanvas = Canvas(b)
        replay(lastVisible)
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), paperPaint)
        bitmap?.let { canvas.drawBitmap(it, 0f, 0f, null) }
        val ws = wetStroke
        if (ws != null && !wetPath.isEmpty) {
            highlightPaint.color = ws.color
            highlightPaint.strokeWidth = Tools.segmentWidth(ws.baseWidth, 0.5f) * page.scale
            canvas.drawPath(wetPath, highlightPaint)
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean = input?.onTouch(this, event) ?: true
    override fun onGenericMotionEvent(event: MotionEvent): Boolean = input?.onGenericMotion(this, event) ?: super.onGenericMotionEvent(event)

    // ---- InkSink (canvas units in, view pixels drawn) ----

    override fun segment(stroke: LocalStroke, from: LocalPoint, to: LocalPoint) {
        val x0 = page.toViewX(from.x); val y0 = page.toViewY(from.y)
        val x1 = page.toViewX(to.x); val y1 = page.toViewY(to.y)
        val w = Tools.segmentWidth(stroke.baseWidth, to.pressure) * page.scale
        if (stroke.tool == Tools.HIGHLIGHTER) {
            if (wetStroke !== stroke) { wetPath.reset(); wetPath.moveTo(x0, y0); wetStroke = stroke }
            wetPath.lineTo(x1, y1)
            invalidateSegment(x0, y0, x1, y1, Tools.segmentWidth(stroke.baseWidth, 1f) * page.scale)
            return
        }
        val c = bitmapCanvas ?: return
        inkPaint.color = stroke.color
        inkPaint.strokeWidth = max(w, 1f)
        c.drawLine(x0, y0, x1, y1, inkPaint)
        invalidateSegment(x0, y0, x1, y1, w)
    }

    override fun dot(stroke: LocalStroke, at: LocalPoint) {
        val x = page.toViewX(at.x); val y = page.toViewY(at.y)
        val w = Tools.segmentWidth(stroke.baseWidth, at.pressure) * page.scale
        if (stroke.tool == Tools.HIGHLIGHTER) {
            wetPath.reset(); wetPath.moveTo(x, y); wetPath.lineTo(x + 0.01f, y); wetStroke = stroke
            invalidateSegment(x, y, x, y, Tools.segmentWidth(stroke.baseWidth, 1f) * page.scale)
            return
        }
        val c = bitmapCanvas ?: return
        dotPaint.color = stroke.color
        c.drawCircle(x, y, max(w / 2f, 0.75f), dotPaint)
        invalidateSegment(x, y, x, y, w)
    }

    override fun committed(stroke: LocalStroke) {
        // The replay list must include every committed stroke: a size change (rotation, a toolbar inset change)
        // recreates the bitmap from it, and pen segments were only ever drawn straight into the old bitmap.
        lastVisible = lastVisible + stroke
        if (stroke.tool == Tools.HIGHLIGHTER) {
            bitmapCanvas?.let { drawHighlighter(it, stroke) }
            wetPath.reset(); wetStroke = null
            invalidate()
        }
    }

    override fun redraw(visible: List<LocalStroke>) {
        wetPath.reset(); wetStroke = null
        replay(visible)
        invalidate()
    }

    private fun replay(visible: List<LocalStroke>) {
        lastVisible = ArrayList(visible)
        val c = bitmapCanvas ?: return
        c.drawColor(0, BlendMode.CLEAR)
        for (s in visible) if (s.tool == Tools.HIGHLIGHTER) drawHighlighter(c, s)
        for (s in visible) if (s.tool != Tools.HIGHLIGHTER) drawPen(c, s)
    }

    private fun drawPen(c: Canvas, s: LocalStroke) {
        val pts = s.points
        if (pts.isEmpty()) return
        if (pts.size == 1) {
            dotPaint.color = s.color
            val p = pts[0]
            c.drawCircle(page.toViewX(p.x), page.toViewY(p.y), max(Tools.segmentWidth(s.baseWidth, p.pressure) * page.scale / 2f, 0.75f), dotPaint)
            return
        }
        inkPaint.color = s.color
        for (i in 1 until pts.size) {
            val a = pts[i - 1]; val b = pts[i]
            inkPaint.strokeWidth = max(Tools.segmentWidth(s.baseWidth, b.pressure) * page.scale, 1f)
            c.drawLine(page.toViewX(a.x), page.toViewY(a.y), page.toViewX(b.x), page.toViewY(b.y), inkPaint)
        }
    }

    private fun drawHighlighter(c: Canvas, s: LocalStroke) {
        val pts = s.points
        if (pts.isEmpty()) return
        val path = Path()
        path.moveTo(page.toViewX(pts[0].x), page.toViewY(pts[0].y))
        if (pts.size == 1) path.lineTo(page.toViewX(pts[0].x) + 0.01f, page.toViewY(pts[0].y))
        for (i in 1 until pts.size) path.lineTo(page.toViewX(pts[i].x), page.toViewY(pts[i].y))
        highlightPaint.color = s.color
        highlightPaint.strokeWidth = Tools.segmentWidth(s.baseWidth, 0.5f) * page.scale
        c.drawPath(path, highlightPaint)
    }

    private fun invalidateSegment(x0: Float, y0: Float, x1: Float, y1: Float, w: Float) {
        val pad = w + 2f
        dirty.set(
            floor(min(x0, x1) - pad).toInt(), floor(min(y0, y1) - pad).toInt(),
            ceil(max(x0, x1) + pad).toInt(), ceil(max(y0, y1) + pad).toInt(),
        )
        invalidate(dirty)
    }
}
