package com.twelve.daylight.ink.overlay

import com.twelve.daylight.ink.net.Phase
import com.twelve.daylight.ink.protocol.StateReport
import com.twelve.daylight.ink.ui.Texts

/** What the two pills show, from the link phase and the last STATE (IMPLEMENTATION-PLAN 8 step 5). */
data class PillsLook(
    val pinLabel: String,
    /** Pinned: the Pin pill is filled InkBlack with PaperBg text. */
    val pinFilled: Boolean,
    /** Amber dot on the Pin pill while the board is up (ENGAGING or LIVE). */
    val liveDot: Boolean,
    /** Both pills enabled only while the Mac accepted us. */
    val enabled: Boolean,
)

object PillsState {
    fun view(phase: Phase, state: StateReport?): PillsLook {
        val connected = phase == Phase.LIVE && (state?.allowed ?: true)
        if (!connected || state == null) return PillsLook(Texts.PILL_PIN, pinFilled = false, liveDot = false, enabled = connected)
        val boardUp = state.governor == 1 || state.governor == 2
        return if (state.pinned) PillsLook(Texts.PILL_KEEP, pinFilled = true, liveDot = false, enabled = true)
        else PillsLook(Texts.PILL_PIN, pinFilled = false, liveDot = boardUp, enabled = true)
    }
}

/**
 * Where the pill window sits (SPEC E5): WRAP_CONTENT, top centre, entirely inside the top `pillStripHeight` px that the
 * Mac crops away in mirror mode (SPEC D40, default 96). Sizes are device pixels on purpose: the strip is in pixels.
 */
object PillsLayout {
    const val DEFAULT_STRIP_PX = 96
    const val ROW_HEIGHT_PX = 48
    const val MARGIN_Y_PX = 24
    const val PILL_PADDING_X_PX = 28
    const val GAP_PX = 16
    const val BORDER_PX = 2          // about 1.5 dp on the DC-1
    const val TEXT_PX = 22

    enum class Position { TOP, BOTTOM }

    data class Placement(val position: Position, val y: Int, val rowHeight: Int)

    fun placement(position: Position, stripPx: Int = DEFAULT_STRIP_PX): Placement {
        val row = ROW_HEIGHT_PX.coerceAtMost(stripPx - 2 * MARGIN_Y_PX).coerceAtLeast(32)
        val y = ((stripPx - row) / 2).coerceAtLeast(0)
        return Placement(position, y, row)
    }

    fun positionFrom(extra: String?): Position = if (extra?.trim()?.lowercase() == "bottom") Position.BOTTOM else Position.TOP
}
