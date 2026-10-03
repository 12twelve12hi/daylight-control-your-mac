package com.twelve.daylight.ink.ink

/**
 * Stylus pressure normalisation. Android documents AXIS_PRESSURE as 0..1 "although values higher than 1 may be
 * generated"; the sibling DC-1 app sees raw 12-bit ADC values (0..4095). UNVERIFIED which one the DC-1 driver reports
 * (research-android-ink 1.2), so both are accepted: anything above 1 is treated as a raw ADC reading.
 */
object Pressure {
    const val RAW_MAX = 4095f

    fun normalize(raw: Float): Float {
        if (raw.isNaN()) return 0f
        val p = if (raw > 1f) raw / RAW_MAX else raw
        return p.coerceIn(0f, 1f)
    }

    /** True when the driver is handing out raw ADC values (logged once as a device fact, LOOSE_ENDS D3). */
    fun looksRaw(raw: Float): Boolean = raw > 1f
}
