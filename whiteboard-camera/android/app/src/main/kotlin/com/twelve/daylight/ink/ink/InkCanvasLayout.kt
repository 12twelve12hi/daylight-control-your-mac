package com.twelve.daylight.ink.ink

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.view.View
import android.view.ViewGroup
import com.twelve.daylight.ink.ui.Tokens

/**
 * Letterboxes the 3:4 page (dry view plus the optional wet surface) in SolOS cream with a 1.5 dp BorderSubtle line.
 * Children are laid out exactly on the page rectangle, so their coordinates are page coordinates.
 */
class InkCanvasLayout(context: Context) : ViewGroup(context) {
    private var page = PageRect(0f, 0f, 0f, 0f)
    private val borderPaint = Paint().apply {
        color = Tokens.BORDER_SUBTLE; style = Paint.Style.STROKE
        strokeWidth = Tokens.BORDER_DP * resources.displayMetrics.density
    }
    var onPageSize: ((Int, Int) -> Unit)? = null

    init {
        setWillNotDraw(false)
        setBackgroundColor(Tokens.SURFACE_CREAM)
    }

    val pageRect: PageRect get() = page

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        val h = MeasureSpec.getSize(heightMeasureSpec)
        val availW = (w - paddingLeft - paddingRight).coerceAtLeast(0)
        val availH = (h - paddingTop - paddingBottom).coerceAtLeast(0)
        page = PageGeometry.fit(availW, availH)
        val pw = page.width.toInt()
        val ph = page.height.toInt()
        for (i in 0 until childCount) {
            getChildAt(i).measure(MeasureSpec.makeMeasureSpec(pw, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(ph, MeasureSpec.EXACTLY))
        }
        setMeasuredDimension(w, h)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val left = paddingLeft + page.left.toInt()
        val top = paddingTop + page.top.toInt()
        val pw = page.width.toInt()
        val ph = page.height.toInt()
        for (i in 0 until childCount) getChildAt(i).layout(left, top, left + pw, top + ph)
        onPageSize?.invoke(pw, ph)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val left = paddingLeft + page.left
        val top = paddingTop + page.top
        canvas.drawRect(left, top, left + page.width, top + page.height, borderPaint)
    }

    fun addLayer(v: View) { addView(v) }
}
