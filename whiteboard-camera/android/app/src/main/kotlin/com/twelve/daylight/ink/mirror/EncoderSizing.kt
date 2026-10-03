package com.twelve.daylight.ink.mirror

/**
 * The encoder size (PROTOCOL 14.4 `max_size`): the long side at most `maxSize`, the display aspect kept, both sides
 * multiples of 16 (rounded down, at least 16). When the encoder refuses to configure, smaller long sides are tried in
 * turn, the way scrcpy retries with a smaller size.
 */
object EncoderSizing {
    /** Long sides tried after the requested one, largest first. */
    val FALLBACK_LONG_SIDES = intArrayOf(1600, 1280, 1024, 960, 800, 640, 480, 320)

    data class Size(val width: Int, val height: Int)

    fun fit(displayWidth: Int, displayHeight: Int, maxSize: Int): Size {
        require(displayWidth > 0 && displayHeight > 0) { "display size must be positive" }
        val portrait = displayHeight >= displayWidth
        val long = if (portrait) displayHeight else displayWidth
        val short = if (portrait) displayWidth else displayHeight
        val targetLong = minOf(long, maxSize)
        val longOut = (targetLong / 16 * 16).coerceAtLeast(16)
        // Scale the short side with the same factor, then round down to a multiple of 16.
        val shortExact = short.toLong() * longOut / long
        val shortOut = (shortExact / 16 * 16).toInt().coerceAtLeast(16)
        return if (portrait) Size(shortOut, longOut) else Size(longOut, shortOut)
    }

    /** The requested size first, then each smaller fallback, without duplicates. */
    fun candidates(displayWidth: Int, displayHeight: Int, maxSize: Int): List<Size> {
        val out = LinkedHashSet<Size>()
        out.add(fit(displayWidth, displayHeight, maxSize))
        for (l in FALLBACK_LONG_SIDES) if (l < maxSize) out.add(fit(displayWidth, displayHeight, l))
        return out.toList()
    }
}
