package com.twelve.daylight.ink.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Button
import kotlin.math.max

/**
 * One flat pill (SPEC 10 look: tokens only, 1.5 dp InkBlack border, zero elevation): text, optional amber dot,
 * tap and optional long press. Sizes are given in pixels by the caller (the overlay needs exact pixels, the toolbar dp).
 *
 * The text is drawn, not held by a TextView, so it is handed to accessibility explicitly: the content description
 * follows [text], the node reads as a Button with that text, the selected look is the View's selected state, and an
 * accessibility click (TalkBack, UI Automator, Espresso) runs [onTap] through [performClick] like a finger tap does.
 */
class PillView(context: Context) : View(context) {
    var text: String = ""
        set(v) {
            if (field != v) { field = v; requestLayout(); invalidate() }
            if (contentDescription?.toString() != v) contentDescription = v
        }
    var fill: Int = Tokens.PAPER_BG
        set(v) { field = v; invalidate() }
    var border: Int = Tokens.INK_BLACK
        set(v) { field = v; invalidate() }
    var textColor: Int = Tokens.INK_BLACK
        set(v) { field = v; invalidate() }
    var dotColor: Int? = null
        set(v) { field = v; requestLayout(); invalidate() }
    var dotAlpha: Float = 1f
        set(v) { field = v; invalidate() }
    var selectedLook: Boolean = false
        set(v) { field = v; isSelected = v; invalidate() }

    var heightPx: Int = (44 * resources.displayMetrics.density).toInt()
    var paddingXPx: Int = (18 * resources.displayMetrics.density).toInt()
    var textSizePx: Float = 15f * resources.displayMetrics.scaledDensity
        set(v) { field = v; textPaint.textSize = v; requestLayout() }
    var borderPx: Float = Tokens.BORDER_DP * resources.displayMetrics.density
    var longPressMs: Long = 0L

    var onTap: (() -> Unit)? = null
    var onLongPress: (() -> Unit)? = null
        set(v) { field = v; isLongClickable = v != null }

    private val fillPaint = Paint().apply { style = Paint.Style.FILL; isAntiAlias = true }
    private val borderPaint = Paint().apply { style = Paint.Style.STROKE; isAntiAlias = true }
    private val textPaint = Paint().apply { isAntiAlias = true; textSize = textSizePx; isFakeBoldText = true }
    private val dotPaint = Paint().apply { style = Paint.Style.FILL; isAntiAlias = true }
    private val rect = RectF()
    private var longFired = false
    private var pressed = false
    private val longPressRunnable = Runnable { longFired = true; onLongPress?.invoke() }

    init { isClickable = true; isFocusable = true }

    override fun getAccessibilityClassName(): CharSequence = Button::class.java.name

    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.text = text
    }

    /** Finger taps and accessibility clicks both end here; a disabled pill does nothing. */
    override fun performClick(): Boolean {
        if (!isEnabled) return false
        super.performClick()
        onTap?.invoke()
        return true
    }

    override fun performLongClick(): Boolean {
        val l = onLongPress ?: return super.performLongClick()
        if (!isEnabled) return false
        l.invoke()
        return true
    }

    private val dotSize: Float get() = textSizePx * 0.6f

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val textW = textPaint.measureText(text)
        val dotW = if (dotColor != null) dotSize + textSizePx * 0.5f else 0f
        val w = (textW + dotW + 2 * paddingXPx).toInt()
        setMeasuredDimension(resolveSize(max(w, heightPx), widthMeasureSpec), resolveSize(heightPx, heightMeasureSpec))
    }

    override fun onDraw(canvas: Canvas) {
        val inset = borderPx / 2f
        rect.set(inset, inset, width - inset, height - inset)
        val r = height / 2f
        fillPaint.color = fill
        fillPaint.alpha = if (isEnabled) 255 else 140
        canvas.drawRoundRect(rect, r, r, fillPaint)
        borderPaint.color = border
        borderPaint.strokeWidth = if (selectedLook) borderPx * 2f else borderPx
        borderPaint.alpha = if (isEnabled) 255 else 120
        canvas.drawRoundRect(rect, r, r, borderPaint)
        val textW = textPaint.measureText(text)
        val dot = dotColor
        val dotW = if (dot != null) dotSize + textSizePx * 0.5f else 0f
        var x = (width - textW - dotW) / 2f
        val baseline = height / 2f - (textPaint.descent() + textPaint.ascent()) / 2f
        if (dot != null) {
            dotPaint.color = dot
            dotPaint.alpha = (255 * dotAlpha.coerceIn(0.15f, 1f)).toInt()
            canvas.drawCircle(x + dotSize / 2f, height / 2f, dotSize / 2f, dotPaint)
            x += dotW
        }
        textPaint.color = textColor
        textPaint.alpha = if (isEnabled) 255 else 120
        canvas.drawText(text, x, baseline, textPaint)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!isEnabled) return true
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                pressed = true; longFired = false
                if (longPressMs > 0 && onLongPress != null) postDelayed(longPressRunnable, longPressMs)
            }
            MotionEvent.ACTION_UP -> {
                removeCallbacks(longPressRunnable)
                if (pressed && !longFired) performClick()
                pressed = false
            }
            MotionEvent.ACTION_CANCEL -> { removeCallbacks(longPressRunnable); pressed = false }
        }
        return true
    }
}
