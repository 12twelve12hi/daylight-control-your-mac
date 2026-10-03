package com.twelve.daylight.ink.ink

import android.util.Log
import android.view.MotionEvent
import android.view.View
import com.twelve.daylight.ink.prefs.Prefs

/**
 * MotionEvent -> StrokeSession, shared by the wet and dry views (whichever is on top receives the events).
 * SPEC E6: only TOOL_TYPE_STYLUS and TOOL_TYPE_ERASER draw; hover never draws; ACTION_CANCEL and FLAG_CANCELED cancel;
 * a pressure-0 down never starts a stroke (PROTOCOL 11). Fingers are swallowed so nothing under the canvas scrolls.
 */
class PenInput(
    private val session: StrokeSession,
    private val prefs: Prefs?,
    private val wet: WetInkSurface?,
) {
    companion object { const val TAG = "DaylightInk.ink" }

    var unbufferedPerStroke: Boolean = true
    private var penPointerId: Int = -1
    private var factPressureLogged = false
    private var factButtonLogged = false
    private var lastViewX = 0f
    private var lastViewY = 0f
    private var wetStroke: LocalStroke? = null

    /** Adapter so [MotionSamples] (pure) can read a MotionEvent. One instance, no allocation per event. */
    private val adapter = object : MotionLike {
        lateinit var e: MotionEvent
        override val historySize: Int get() = e.historySize
        override fun historicalX(pointerIndex: Int, pos: Int) = e.getHistoricalX(pointerIndex, pos)
        override fun historicalY(pointerIndex: Int, pos: Int) = e.getHistoricalY(pointerIndex, pos)
        override fun historicalPressure(pointerIndex: Int, pos: Int) = e.getHistoricalPressure(pointerIndex, pos)
        override fun historicalEventTime(pos: Int) = e.getHistoricalEventTime(pos)
        override fun x(pointerIndex: Int) = e.getX(pointerIndex)
        override fun y(pointerIndex: Int) = e.getY(pointerIndex)
        override fun pressure(pointerIndex: Int) = e.getPressure(pointerIndex)
        override val eventTime: Long get() = e.eventTime
    }
    private val samples = ArrayList<RawSample>(16)

    private fun isPen(e: MotionEvent, index: Int): Boolean {
        val t = e.getToolType(index)
        return t == MotionEvent.TOOL_TYPE_STYLUS || t == MotionEvent.TOOL_TYPE_ERASER
    }

    fun onTouch(view: View, e: MotionEvent): Boolean {
        val idx = e.actionIndex
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                if (!isPen(e, idx)) return true                 // fingers and palms: swallowed, never drawn
                if (penPointerId >= 0) session.cancel()
                penPointerId = e.getPointerId(idx)
                if (unbufferedPerStroke) view.requestUnbufferedDispatch(e)
                val raw = e.getPressure(idx)
                logPressureFact(raw)
                if ((e.buttonState and (MotionEvent.BUTTON_STYLUS_PRIMARY or MotionEvent.BUTTON_STYLUS_SECONDARY)) != 0) logButtonFact(e.buttonState, "buttonState while touching")
                lastViewX = e.getX(idx); lastViewY = e.getY(idx)
                session.down(lastViewX, lastViewY, raw, e.eventTime, eraserPointer = e.getToolType(idx) == MotionEvent.TOOL_TYPE_ERASER)
                wetStroke = null
            }
            MotionEvent.ACTION_MOVE -> {
                if (penPointerId < 0) return true
                val pi = e.findPointerIndex(penPointerId)
                if (pi < 0) return true
                adapter.e = e
                samples.clear()
                MotionSamples.unpack(adapter, pi, samples)
                for (s in samples) {
                    val wasDrawing = session.isDrawing
                    session.point(s.x, s.y, s.pressure, s.timeMs)
                    if (wasDrawing && session.isDrawing && session.tool != Tools.ERASER) wetSegment(s)
                    lastViewX = s.x; lastViewY = s.y
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                if (e.getPointerId(idx) != penPointerId) return true
                penPointerId = -1
                val canceled = (e.flags and MotionEvent.FLAG_CANCELED) != 0
                if (canceled) { session.cancel(); wet?.cancel() } else { session.up(); wet?.commit() }
            }
            MotionEvent.ACTION_CANCEL -> {
                penPointerId = -1
                session.cancel()
                wet?.cancel()
            }
        }
        return true
    }

    /** Hover and the barrel button arrive here. Hover never draws (SPEC D3); the button is logged once (LOOSE_ENDS D4). */
    fun onGenericMotion(view: View, e: MotionEvent): Boolean {
        if (e.actionMasked == MotionEvent.ACTION_BUTTON_PRESS) {
            logButtonFact(e.actionButton, "ACTION_BUTTON_PRESS")
            return true
        }
        return false
    }

    private fun wetSegment(s: RawSample) {
        val w = wet ?: return
        if (!w.frontBufferAvailable) return
        val stroke = session.currentStrokeForWet() ?: return
        val p = Pressure.normalize(s.pressure)
        val widthPx = Tools.segmentWidth(stroke.baseWidth, p) * session.page.scale
        w.segment(Seg(lastViewX, lastViewY, s.x, s.y, widthPx, stroke.color))
    }

    private fun logPressureFact(raw: Float) {
        if (factPressureLogged) return
        factPressureLogged = true
        val fact = if (Pressure.looksRaw(raw)) "raw ADC (first sample $raw, divided by 4095)" else "normalised 0..1 (first sample $raw)"
        Log.i(TAG, "pressure range: $fact")
        prefs?.factPressureRaw = fact
    }

    private fun logButtonFact(button: Int, where: String) {
        if (factButtonLogged) return
        factButtonLogged = true
        val name = when {
            button and MotionEvent.BUTTON_STYLUS_PRIMARY != 0 -> "BUTTON_STYLUS_PRIMARY"
            button and MotionEvent.BUTTON_STYLUS_SECONDARY != 0 -> "BUTTON_STYLUS_SECONDARY"
            else -> "button 0x${Integer.toHexString(button)}"
        }
        Log.i(TAG, "side button: $name ($where)")
        prefs?.factActionButton = "$name ($where)"
    }
}
