package com.twelve.daylight.ink.ink

import com.twelve.daylight.ink.protocol.SolStream
import java.util.UUID

/** One sample in canvas units; `deltaMs` is milliseconds since the FIRST point of the stroke (PROTOCOL 4). */
data class LocalPoint(val x: Float, val y: Float, val pressure: Float, val deltaMs: Int)

/** Tool constants and defaults of PROTOCOL 6.3. */
object Tools {
    const val PEN = SolStream.Tool.PEN
    const val HIGHLIGHTER = SolStream.Tool.HIGHLIGHTER
    const val ERASER = SolStream.Tool.ERASER

    const val PEN_COLOR: Int = 0xFF111111.toInt()          // InkBlack
    const val HIGHLIGHTER_COLOR: Int = 0x80D97706.toInt()  // Amber at 50 percent
    const val PEN_WIDTH = 3.2f                              // canvas units
    const val HIGHLIGHTER_WIDTH = 12.0f
    const val ERASER_RADIUS = 12.0f

    fun color(tool: Int): Int = if (tool == HIGHLIGHTER) HIGHLIGHTER_COLOR else PEN_COLOR
    fun baseWidth(tool: Int): Float = when (tool) {
        HIGHLIGHTER -> HIGHLIGHTER_WIDTH
        ERASER -> ERASER_RADIUS
        else -> PEN_WIDTH
    }

    /** SPEC 6.6: stroke width per segment is `baseWidth * (0.55 + 0.9 * pressure)`. */
    fun segmentWidth(baseWidth: Float, pressure: Float): Float = baseWidth * (0.55f + 0.9f * pressure.coerceIn(0f, 1f))
}

/** A stroke as the tablet remembers it: the same points it sent, in canvas units. */
class LocalStroke(val id: UUID, val tool: Int, val color: Int, val baseWidth: Float) {
    val points: MutableList<LocalPoint> = ArrayList(64)

    /** Squared distance from (x, y) to the nearest segment (or point) of this stroke. */
    fun distanceSq(x: Float, y: Float): Float {
        if (points.isEmpty()) return Float.MAX_VALUE
        if (points.size == 1) return Geometry.distanceSq(x, y, points[0].x, points[0].y)
        var best = Float.MAX_VALUE
        for (i in 1 until points.size) {
            val d = Geometry.pointToSegmentSq(x, y, points[i - 1].x, points[i - 1].y, points[i].x, points[i].y)
            if (d < best) best = d
        }
        return best
    }

    /** The Mac's rule mirrored as a hint: hit when the eraser centre is within `radius + baseWidth / 2`. */
    fun hit(x: Float, y: Float, radius: Float): Boolean {
        val reach = radius + baseWidth / 2f
        return distanceSq(x, y) <= reach * reach
    }
}

object Geometry {
    fun distanceSq(ax: Float, ay: Float, bx: Float, by: Float): Float {
        val dx = ax - bx
        val dy = ay - by
        return dx * dx + dy * dy
    }

    fun pointToSegmentSq(px: Float, py: Float, ax: Float, ay: Float, bx: Float, by: Float): Float {
        val vx = bx - ax
        val vy = by - ay
        val lenSq = vx * vx + vy * vy
        if (lenSq <= 0f) return distanceSq(px, py, ax, ay)
        val t = (((px - ax) * vx + (py - ay) * vy) / lenSq).coerceIn(0f, 1f)
        return distanceSq(px, py, ax + t * vx, ay + t * vy)
    }
}
