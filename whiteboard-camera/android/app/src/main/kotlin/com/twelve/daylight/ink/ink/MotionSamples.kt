package com.twelve.daylight.ink.ink

/**
 * The slice of a MotionEvent the ink path needs, as an interface so the JVM tests can feed fakes
 * (research-android-ink 1.3: history samples first, in order, then the current sample).
 */
interface MotionLike {
    val historySize: Int
    fun historicalX(pointerIndex: Int, pos: Int): Float
    fun historicalY(pointerIndex: Int, pos: Int): Float
    fun historicalPressure(pointerIndex: Int, pos: Int): Float
    fun historicalEventTime(pos: Int): Long
    fun x(pointerIndex: Int): Float
    fun y(pointerIndex: Int): Float
    fun pressure(pointerIndex: Int): Float
    val eventTime: Long
}

/** One raw sample in view pixels; `pressure` is still the driver value (normalised later by [Pressure]). */
data class RawSample(val x: Float, val y: Float, val pressure: Float, val timeMs: Long)

object MotionSamples {
    /** History samples (oldest first), then the current one. Non-finite coordinates are dropped. */
    fun unpack(e: MotionLike, pointerIndex: Int, out: MutableList<RawSample> = ArrayList(e.historySize + 1)): MutableList<RawSample> {
        for (h in 0 until e.historySize) {
            val x = e.historicalX(pointerIndex, h)
            val y = e.historicalY(pointerIndex, h)
            if (x.isFinite() && y.isFinite()) out.add(RawSample(x, y, e.historicalPressure(pointerIndex, h), e.historicalEventTime(h)))
        }
        val x = e.x(pointerIndex)
        val y = e.y(pointerIndex)
        if (x.isFinite() && y.isFinite()) out.add(RawSample(x, y, e.pressure(pointerIndex), e.eventTime))
        return out
    }
}
