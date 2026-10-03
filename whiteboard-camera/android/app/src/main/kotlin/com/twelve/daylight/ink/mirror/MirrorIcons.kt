package com.twelve.daylight.ink.mirror

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.drawable.Icon
import com.twelve.daylight.ink.ui.Tokens

/** The notification icon of the screen sharing: an amber ring, drawn in code (no drawable resources). */
object MirrorIcons {
    fun icon(): Icon {
        val size = 96
        val b = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val c = Canvas(b)
        val p = Paint().apply { isAntiAlias = true; color = Tokens.AMBER; style = Paint.Style.STROKE; strokeWidth = 14f }
        c.drawRoundRect(12f, 20f, size - 12f, size - 20f, 10f, 10f, p)
        p.style = Paint.Style.FILL
        c.drawCircle(size / 2f, size / 2f, 10f, p)
        return Icon.createWithBitmap(b)
    }
}
