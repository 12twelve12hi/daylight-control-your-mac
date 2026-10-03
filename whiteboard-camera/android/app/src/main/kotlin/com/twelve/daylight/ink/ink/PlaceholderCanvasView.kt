package com.twelve.daylight.ink.ink

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View

/**
 * A 3:4 paper page letterboxed in SolOS cream. Only TOOL_TYPE_STYLUS and TOOL_TYPE_ERASER draw
 * (fingers and palms never draw, never engage); history samples are consumed before the current one.
 * The wet/dry split with CanvasFrontBufferedRenderer replaces this in M4.
 */
class PlaceholderCanvasView(context: Context) : View(context) {
    private val creamPaint = Paint().apply { color = Color.parseColor("#EAE5DC"); style = Paint.Style.FILL }
    private val paperPaint = Paint().apply { color = Color.parseColor("#FAF8F5"); style = Paint.Style.FILL }
    private val borderPaint = Paint().apply {
        color = Color.parseColor("#CDC6B8"); style = Paint.Style.STROKE; strokeWidth = 1.5f * resources.displayMetrics.density
    }
    private val inkPaint = Paint().apply {
        color = Color.parseColor("#111111"); style = Paint.Style.STROKE; strokeWidth = 4f
        strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND; isAntiAlias = true
    }
    private val page = RectF()
    private val strokes = ArrayList<Path>()
    private var current: Path? = null

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        requestUnbufferedDispatch(InputDevice.SOURCE_CLASS_POINTER)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        val aspect = 3f / 4f
        val pageWidth: Float
        val pageHeight: Float
        if (w.toFloat() / h.toFloat() > aspect) { pageHeight = h.toFloat(); pageWidth = pageHeight * aspect } else { pageWidth = w.toFloat(); pageHeight = pageWidth / aspect }
        page.set((w - pageWidth) / 2f, (h - pageHeight) / 2f, (w + pageWidth) / 2f, (h + pageHeight) / 2f)
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), creamPaint)
        canvas.drawRect(page, paperPaint)
        canvas.drawRect(page, borderPaint)
        for (path in strokes) canvas.drawPath(path, inkPaint)
        current?.let { canvas.drawPath(it, inkPaint) }
    }

    private fun isPen(event: MotionEvent, index: Int): Boolean {
        val type = event.getToolType(index)
        return type == MotionEvent.TOOL_TYPE_STYLUS || type == MotionEvent.TOOL_TYPE_ERASER
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val index = event.actionIndex
        if (!isPen(event, index)) return true
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                requestUnbufferedDispatch(event)
                current = Path().apply { moveTo(event.x, event.y) }
            }
            MotionEvent.ACTION_MOVE -> {
                val path = current ?: return true
                for (h in 0 until event.historySize) path.lineTo(event.getHistoricalX(index, h), event.getHistoricalY(index, h))
                path.lineTo(event.getX(index), event.getY(index))
                invalidate()
            }
            MotionEvent.ACTION_UP -> {
                current?.let { strokes.add(it) }
                current = null
                invalidate()
            }
            MotionEvent.ACTION_CANCEL -> {
                current = null
                invalidate()
            }
        }
        return true
    }
}
