package com.twelve.daylight.ink.net

/** PROTOCOL 1 reconnect policy for the APK: 0.5 s doubling to 8 s with 20 percent jitter. */
class Backoff(private val random: () -> Double = { Math.random() }) {
    companion object {
        const val BASE_MS = 500L
        const val CAP_MS = 8000L
        const val JITTER = 0.2
    }

    private var attempt = 0

    /** Delay before the next dial; grows on every call until [reset]. */
    fun nextDelayMs(): Long {
        val base = (BASE_MS shl attempt.coerceAtMost(4)).coerceAtMost(CAP_MS)
        if (attempt < 30) attempt++
        val factor = 1.0 + (random() * 2.0 - 1.0) * JITTER
        return (base * factor).toLong().coerceAtLeast(1L)
    }

    fun reset() { attempt = 0 }
}
