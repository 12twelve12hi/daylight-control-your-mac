package com.twelve.daylight.ink.ink

/** The 3:4 page letterboxed inside a view, in view pixels. Pure math (PROTOCOL 4: canvas units are 1200 x 1600). */
data class PageRect(val left: Float, val top: Float, val width: Float, val height: Float) {
    val right: Float get() = left + width
    val bottom: Float get() = top + height
    /** View pixels per canvas unit (the same on both axes because the page keeps its 3:4 aspect). */
    val scale: Float get() = width / PageGeometry.CANVAS_WIDTH

    fun toCanvasX(viewX: Float): Float = (viewX - left) * PageGeometry.CANVAS_WIDTH / width
    fun toCanvasY(viewY: Float): Float = (viewY - top) * PageGeometry.CANVAS_HEIGHT / height
    fun toViewX(canvasX: Float): Float = left + canvasX * width / PageGeometry.CANVAS_WIDTH
    fun toViewY(canvasY: Float): Float = top + canvasY * height / PageGeometry.CANVAS_HEIGHT
}

object PageGeometry {
    const val CANVAS_WIDTH = 1200f
    const val CANVAS_HEIGHT = 1600f
    const val ASPECT = CANVAS_WIDTH / CANVAS_HEIGHT   // 3:4
    const val DPI = 200f                                // informational, HANDSHAKE field

    /** Largest 3:4 rectangle centred in a `viewWidth` x `viewHeight` view (SolOS cream fills the rest). */
    fun fit(viewWidth: Int, viewHeight: Int): PageRect {
        if (viewWidth <= 0 || viewHeight <= 0) return PageRect(0f, 0f, 0f, 0f)
        val w = viewWidth.toFloat()
        val h = viewHeight.toFloat()
        val pageWidth: Float
        val pageHeight: Float
        if (w / h > ASPECT) {           // wider than 3:4: height-limited
            pageHeight = h
            pageWidth = h * ASPECT
        } else {                        // taller than 3:4: width-limited
            pageWidth = w
            pageHeight = w / ASPECT
        }
        return PageRect((w - pageWidth) / 2f, (h - pageHeight) / 2f, pageWidth, pageHeight)
    }
}
