package com.twelve.daylight.ink.ui

import android.graphics.drawable.GradientDrawable

/** SolOS design tokens (SPEC 3). LivePaper is a transflective LCD: flat fills, 1.5 dp borders, zero elevation. */
object Tokens {
    const val INK_BLACK: Int = 0xFF111111.toInt()
    const val INK_SUBTLE: Int = 0xFF1E1D1B.toInt()
    const val TEXT_MUTED: Int = 0xFF736F68.toInt()
    const val PAPER_BG: Int = 0xFFFAF8F5.toInt()
    const val SURFACE_CREAM: Int = 0xFFEAE5DC.toInt()
    const val CARD_BG: Int = 0xFFFFFFFF.toInt()
    const val BORDER_SUBTLE: Int = 0xFFCDC6B8.toInt()
    const val AMBER: Int = 0xFFD97706.toInt()
    const val AMBER_DEEP: Int = 0xFFC87D20.toInt()
    const val TERRACOTTA: Int = 0xFF9C271D.toInt()
    const val INDIGO: Int = 0xFF1E3A8A.toInt()

    const val BORDER_DP = 1.5f

    /** A flat pill or card: fill, 1.5 dp border, no shadow. */
    fun pill(fill: Int, border: Int, radiusPx: Float, borderPx: Int): GradientDrawable = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = radiusPx
        setColor(fill)
        setStroke(borderPx, border)
    }

    /** Divider colour during the pre-warning: `mix(InkBlack, Amber, breath)` (SPEC 6.2), reused for the chip dot. */
    fun mix(a: Int, b: Int, t: Double): Int {
        val k = t.coerceIn(0.0, 1.0)
        fun ch(shift: Int): Int {
            val ca = (a shr shift) and 0xFF
            val cb = (b shr shift) and 0xFF
            return (ca + (cb - ca) * k).toInt().coerceIn(0, 255)
        }
        return (0xFF shl 24) or (ch(16) shl 16) or (ch(8) shl 8) or ch(0)
    }
}
