package com.twelve.daylight.ink.overlay

import android.content.Context
import android.view.Gravity
import android.widget.LinearLayout
import com.twelve.daylight.ink.ui.PillView
import com.twelve.daylight.ink.ui.Texts
import com.twelve.daylight.ink.ui.Tokens

/**
 * The two floating pills, Pin and Clear, sized in device pixels so the row sits inside the strip the Mac crops away
 * (PillsLayout). Touches on the pills are handled here; everything else is outside the window (research 4.4).
 */
class PillsView(context: Context, placement: PillsLayout.Placement, private val onPin: () -> Unit, private val onClear: () -> Unit) : LinearLayout(context) {
    private val pin = PillView(context)
    private val clear = PillView(context)

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER
        for (p in listOf(pin, clear)) {
            p.heightPx = placement.rowHeight
            p.paddingXPx = PillsLayout.PILL_PADDING_X_PX
            p.textSizePx = PillsLayout.TEXT_PX.toFloat()
            p.borderPx = PillsLayout.BORDER_PX.toFloat()
            p.fill = Tokens.PAPER_BG
            p.border = Tokens.INK_BLACK
        }
        pin.text = Texts.PILL_PIN
        clear.text = Texts.PILL_CLEAR
        pin.onTap = onPin
        clear.onTap = onClear
        addView(pin, LayoutParams(LayoutParams.WRAP_CONTENT, placement.rowHeight).apply { marginEnd = PillsLayout.GAP_PX })
        addView(clear, LayoutParams(LayoutParams.WRAP_CONTENT, placement.rowHeight))
    }

    fun bind(v: PillsLook) {
        pin.text = v.pinLabel
        pin.fill = if (v.pinFilled) Tokens.INK_BLACK else Tokens.PAPER_BG
        pin.textColor = if (v.pinFilled) Tokens.PAPER_BG else Tokens.INK_BLACK
        pin.dotColor = if (v.liveDot) Tokens.AMBER else null
        pin.isEnabled = v.enabled
        clear.isEnabled = v.enabled
        pin.invalidate(); clear.invalidate()
    }
}
