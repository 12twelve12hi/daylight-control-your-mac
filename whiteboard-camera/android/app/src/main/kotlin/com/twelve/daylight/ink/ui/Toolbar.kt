package com.twelve.daylight.ink.ui

import android.content.Context
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import com.twelve.daylight.ink.ink.Tools

/**
 * The bottom row: Pen, Highlight, Erase | Undo, Redo | the chip (centre) | New page, Clear, Settings.
 * Undo and redo are enabled from STATE depths only (the Mac's truth). Padded 16 dp above the bottom edge (DC-1 rule).
 */
class Toolbar(context: Context) : LinearLayout(context) {
    interface Actions {
        fun selectTool(tool: Int)
        fun undo(); fun redo(); fun newPage(); fun clear(); fun openSettings()
    }

    val chip: PillView = PillView(context)
    private val pen = pill(Texts.TOOL_PEN)
    private val highlight = pill(Texts.TOOL_HIGHLIGHT)
    private val erase = pill(Texts.TOOL_ERASE)
    private val undo = pill(Texts.TOOL_UNDO)
    private val redo = pill(Texts.TOOL_REDO)
    private val newPage = pill(Texts.TOOL_NEW_PAGE)
    private val clear = pill(Texts.TOOL_CLEAR)
    private val settings = pill(Texts.TOOL_SETTINGS)
    var actions: Actions? = null
    private val d = resources.displayMetrics.density

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setBackgroundColor(Tokens.SURFACE_CREAM)
        val pad = (12 * d).toInt()
        setPadding(pad, pad, pad, (16 * d).toInt())
        for (v in listOf(pen, highlight, erase)) add(v)
        add(gap())
        add(undo); add(redo)
        add(spacer())
        chip.heightPx = (46 * d).toInt()
        add(chip)
        add(spacer())
        add(newPage); add(clear)
        add(gap())
        add(settings)
        pen.onTap = { actions?.selectTool(Tools.PEN) }
        highlight.onTap = { actions?.selectTool(Tools.HIGHLIGHTER) }
        erase.onTap = { actions?.selectTool(Tools.ERASER) }
        undo.onTap = { actions?.undo() }
        redo.onTap = { actions?.redo() }
        newPage.onTap = { actions?.newPage() }
        clear.onTap = { actions?.clear() }
        settings.onTap = { actions?.openSettings() }
        setTool(Tools.PEN)
        setDepths(0, 0)
    }

    private fun pill(text: String): PillView = PillView(context).apply {
        this.text = text
        heightPx = (40 * d).toInt()
        paddingXPx = (14 * d).toInt()
        textSizePx = 14f * resources.displayMetrics.scaledDensity
        border = Tokens.BORDER_SUBTLE
    }

    private fun add(v: View) {
        val lp = LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT)
        lp.marginEnd = (6 * d).toInt()
        addView(v, lp)
    }

    private fun gap(): View = View(context).apply { layoutParams = LayoutParams((10 * d).toInt(), 1) }
    private fun spacer(): View = View(context).apply { layoutParams = LayoutParams(0, 1, 1f) }

    fun setTool(tool: Int) {
        pen.selectedLook = tool == Tools.PEN
        highlight.selectedLook = tool == Tools.HIGHLIGHTER
        erase.selectedLook = tool == Tools.ERASER
        pen.border = if (tool == Tools.PEN) Tokens.INK_BLACK else Tokens.BORDER_SUBTLE
        highlight.border = if (tool == Tools.HIGHLIGHTER) Tokens.INK_BLACK else Tokens.BORDER_SUBTLE
        erase.border = if (tool == Tools.ERASER) Tokens.INK_BLACK else Tokens.BORDER_SUBTLE
    }

    fun setDepths(undoDepth: Int, redoDepth: Int) {
        undo.isEnabled = undoDepth > 0
        redo.isEnabled = redoDepth > 0
        undo.invalidate(); redo.invalidate()
    }
}
