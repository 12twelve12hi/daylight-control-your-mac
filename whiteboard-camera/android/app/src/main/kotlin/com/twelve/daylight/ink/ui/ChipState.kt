package com.twelve.daylight.ink.ui

import com.twelve.daylight.ink.net.Phase
import com.twelve.daylight.ink.protocol.StateReport
import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.cos

/** The SPEC section 10 chip as a pure function of the connection phase and the last STATE. */
enum class ChipKind { SEARCHING, PENDING, DENIED, INCOMPATIBLE, INACTIVE, CAMERA, LIVE, PREWARN, RETURNING, PINNED }

enum class ChipTap { NONE, PIN, RETRY, EXPLAIN }

data class ChipView(
    val kind: ChipKind,
    val text: String,
    /** Amber dot next to the text. */
    val dot: Boolean,
    /** The dot breathes in phase with the Mac divider (pre-warning only). */
    val breathing: Boolean,
    val tap: ChipTap,
    /** A 600 ms long press sends AUTO_ENGAGE_RETURN. */
    val longPressReturns: Boolean,
)

object ChipState {
    const val LONG_PRESS_MS = 600L
    /** The chip refreshes its local countdown this often between STATE messages. */
    const val COUNTDOWN_TICK_MS = 250L

    /** Pre-warning breath weight at `t` seconds since the pre-warning was first seen: `0.5 * (1 - cos(2 pi t / 2))`. */
    fun breath(tSeconds: Double): Double = 0.5 * (1.0 - cos(2.0 * PI * tSeconds / 2.0))

    /** "Returning in N": ceil(ms / 1000), never below 1 while a return is scheduled. */
    fun returningSeconds(msToReturn: Long): Int = ceil(msToReturn / 1000.0).toInt().coerceAtLeast(1)

    private fun simple(kind: ChipKind, text: String, dot: Boolean = false, tap: ChipTap = ChipTap.NONE, longPress: Boolean = false) =
        ChipView(kind, text, dot, false, tap, longPress)

    /** `msSinceState` is the time since the STATE carrying `state` arrived (local countdown, PROTOCOL 6.14). */
    fun view(phase: Phase, state: StateReport?, msSinceState: Long = 0L): ChipView {
        when (phase) {
            Phase.SEARCHING, Phase.CONNECTING -> return simple(ChipKind.SEARCHING, Texts.LOOKING)
            Phase.PENDING -> return simple(ChipKind.PENDING, Texts.LOOK_AT_MAC, dot = true)
            Phase.DENIED -> return simple(ChipKind.DENIED, Texts.NOT_ALLOWED, tap = ChipTap.RETRY)
            Phase.INCOMPATIBLE -> return simple(ChipKind.INCOMPATIBLE, Texts.UPDATE_MAC, tap = ChipTap.RETRY)
            Phase.LIVE -> {}
        }
        if (state == null) return simple(ChipKind.SEARCHING, Texts.LOOKING)
        if (!state.allowed) return simple(ChipKind.PENDING, Texts.LOOK_AT_MAC, dot = true)
        if (!state.activeSource) return simple(ChipKind.INACTIVE, Texts.inkSourceIs(Texts.inkSourceName(state.inkSource)), tap = ChipTap.EXPLAIN)
        if (state.pinned) return simple(ChipKind.PINNED, Texts.KEEP, tap = ChipTap.PIN, longPress = true)
        if (state.preWarning && state.msToReturn != 0xFFFFFFFFL) {
            val remaining = (state.msToReturn - msSinceState).coerceAtLeast(0L)
            return ChipView(ChipKind.PREWARN, Texts.returningIn(returningSeconds(remaining)), dot = true, breathing = true, tap = ChipTap.PIN, longPressReturns = true)
        }
        return when (state.governor) {
            0 -> simple(ChipKind.CAMERA, Texts.CAMERA, tap = ChipTap.PIN)
            3 -> simple(ChipKind.RETURNING, Texts.RETURNING, dot = true, tap = ChipTap.PIN)
            else -> simple(ChipKind.LIVE, Texts.LIVE, dot = true, tap = ChipTap.PIN, longPress = true)
        }
    }
}
