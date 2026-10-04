package com.twelve.daylight.ink.ink

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.PorterDuff
import android.util.Log
import android.view.InputDevice
import android.view.MotionEvent
import android.view.SurfaceView
import androidx.graphics.lowlatency.CanvasFrontBufferedRenderer
import kotlin.math.max

/** One wet segment in view pixels; immutable so it can cross to the renderer thread. */
data class Seg(val x0: Float, val y0: Float, val x1: Float, val y1: Float, val width: Float, val color: Int)

/**
 * The wet layer (research-android-ink 2.2 and 10.1): a translucent SurfaceView above the window driven by
 * CanvasFrontBufferedRenderer. The dry view below draws the same segment at normal latency, so the multi-buffered
 * layer only clears. `renderer == null` (creation failed or the setting is off) means wet ink is the dry view's.
 */
class WetInkSurface(context: Context) : SurfaceView(context) {
    companion object { const val TAG = "DaylightInk.ink" }

    private val callback = object : CanvasFrontBufferedRenderer.Callback<Seg> {
        private val paint = Paint().apply { isAntiAlias = true; style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND }
        override fun onDrawFrontBufferedLayer(canvas: Canvas, bufferWidth: Int, bufferHeight: Int, param: Seg) {
            paint.color = param.color
            paint.strokeWidth = max(param.width, 1f)
            canvas.drawLine(param.x0, param.y0, param.x1, param.y1, paint)
        }
        override fun onDrawMultiBufferedLayer(canvas: Canvas, bufferWidth: Int, bufferHeight: Int, params: Collection<Seg>) {
            canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)   // the dry layer below already shows the stroke
        }
    }

    private var renderer: CanvasFrontBufferedRenderer<Seg>? = null
    var input: PenInput? = null
    /** Logged device fact (LOOSE_ENDS D14). */
    var onRendererResult: ((Boolean, String) -> Unit)? = null

    val frontBufferAvailable: Boolean get() = renderer?.isValid() == true

    init {
        setZOrderOnTop(true)                       // must happen before the window attaches
        holder.setFormat(PixelFormat.TRANSLUCENT)
        val result = runCatching { CanvasFrontBufferedRenderer(this, callback) }
        renderer = result.getOrNull()
        result.onFailure { Log.w(TAG, "CanvasFrontBufferedRenderer unavailable, wet ink falls back to the dry view: $it") }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        requestUnbufferedDispatch(InputDevice.SOURCE_CLASS_POINTER)   // API 30 overload; effective once attached on Android 13
        val ok = frontBufferAvailable
        onRendererResult?.invoke(ok, if (ok) "renderer valid" else "renderer missing")
    }

    override fun onDetachedFromWindow() {
        renderer?.release(cancelPending = true)
        renderer = null
        super.onDetachedFromWindow()
    }

    override fun onTouchEvent(event: MotionEvent): Boolean = input?.onTouch(this, event) ?: true
    override fun onGenericMotionEvent(event: MotionEvent): Boolean = input?.onGenericMotion(this, event) ?: super.onGenericMotionEvent(event)
    // Hover reaches a view through dispatchHoverEvent and onHoverEvent, not onGenericMotionEvent.
    override fun onHoverEvent(event: MotionEvent): Boolean = input?.onHover(event) == true || super.onHoverEvent(event)

    fun segment(seg: Seg) {
        val r = renderer ?: return
        if (r.isValid()) r.renderFrontBufferedLayer(seg)
    }

    fun commit() { renderer?.let { if (it.isValid()) it.commit() } }
    fun cancel() { renderer?.let { if (it.isValid()) it.cancel() } }
}
