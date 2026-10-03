package com.twelve.daylight.ink.ui

import android.os.SystemClock
import com.twelve.daylight.ink.net.Phase
import com.twelve.daylight.ink.protocol.StateReport

/**
 * Binds [ChipState] to a [PillView]: local countdown ticks every 250 ms during the pre-warning, the amber dot breathing
 * at 0.5 Hz in phase with the Mac divider, tap = pin toggle (or retry, or explain), long press 600 ms = return.
 */
class Chip(val view: PillView, private val onAction: (ChipTap) -> Unit, private val onReturn: () -> Unit) {
    private var phase: Phase = Phase.SEARCHING
    private var state: StateReport? = null
    private var stateAtMs: Long = 0L
    private var preWarnSinceMs: Long = -1L
    var current: ChipView = ChipState.view(phase, null)
        private set

    private val tick = object : Runnable {
        override fun run() {
            render()
            if (current.kind == ChipKind.PREWARN) view.postDelayed(this, ChipState.COUNTDOWN_TICK_MS)
        }
    }
    private val breathe = object : Runnable {
        override fun run() {
            if (current.breathing) {
                val t = (SystemClock.uptimeMillis() - preWarnSinceMs) / 1000.0
                view.dotAlpha = (0.25 + 0.75 * ChipState.breath(t)).toFloat()
                view.postOnAnimation(this)
            } else {
                view.dotAlpha = 1f
            }
        }
    }

    init {
        view.longPressMs = ChipState.LONG_PRESS_MS
        view.onTap = { if (current.tap != ChipTap.NONE) onAction(current.tap) }
        view.onLongPress = { if (current.longPressReturns) onReturn() }
        render()
    }

    fun bind(phase: Phase, state: StateReport?, stateAtMs: Long) {
        this.phase = phase
        this.state = state
        this.stateAtMs = stateAtMs
        val pre = state?.preWarning == true
        if (pre && preWarnSinceMs < 0) preWarnSinceMs = SystemClock.uptimeMillis()
        if (!pre) preWarnSinceMs = -1L
        render()
        view.removeCallbacks(tick)
        if (current.kind == ChipKind.PREWARN) view.postDelayed(tick, ChipState.COUNTDOWN_TICK_MS)
        view.removeCallbacks(breathe)
        if (current.breathing) view.postOnAnimation(breathe) else view.dotAlpha = 1f
    }

    private fun render() {
        val elapsed = if (state != null) (SystemClock.uptimeMillis() - stateAtMs).coerceAtLeast(0L) else 0L
        current = ChipState.view(phase, state, elapsed)
        view.text = current.text
        view.dotColor = if (current.dot) Tokens.AMBER else null
        when (current.kind) {
            ChipKind.SEARCHING -> look(Tokens.PAPER_BG, Tokens.INK_BLACK, Tokens.TEXT_MUTED)
            ChipKind.PENDING, ChipKind.INACTIVE, ChipKind.RETURNING -> look(Tokens.PAPER_BG, Tokens.INK_BLACK, Tokens.INK_BLACK)
            ChipKind.DENIED, ChipKind.INCOMPATIBLE -> look(Tokens.PAPER_BG, Tokens.INK_BLACK, Tokens.TERRACOTTA)
            ChipKind.CAMERA -> look(Tokens.SURFACE_CREAM, Tokens.INK_BLACK, Tokens.INK_BLACK)
            ChipKind.LIVE, ChipKind.PREWARN -> look(Tokens.PAPER_BG, Tokens.INK_BLACK, Tokens.INK_BLACK)
            ChipKind.PINNED -> look(Tokens.INK_BLACK, Tokens.INK_BLACK, Tokens.PAPER_BG)
        }
    }

    private fun look(fill: Int, border: Int, text: Int) {
        view.fill = fill; view.border = border; view.textColor = text
    }
}
