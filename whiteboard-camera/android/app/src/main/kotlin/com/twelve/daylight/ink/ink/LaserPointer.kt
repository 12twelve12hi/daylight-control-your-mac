package com.twelve.daylight.ink.ink

import com.twelve.daylight.ink.protocol.Encoder

/**
 * The Laser tool (PROTOCOL 6.9, LOOSE_ENDS F3), free of Android classes. While it is selected PenInput hands it the
 * stylus position in view pixels: contact at [CONTACT_INTENSITY], hover at [HOVER_INTENSITY]. Positions are mapped to
 * canvas units by the same [PageRect] the strokes use, coalesced to the newest one and sent as one LASER_POINT per
 * display frame, only while the Mac accepts ink. It never opens a stroke, never draws wet or dry ink, never touches
 * undo and keeps nothing: it holds no stroke session and no ink sink, only the transport.
 */
class LaserPointer(
    private val transport: Transport,
    private val encoder: Encoder,
    private val frames: FrameScheduler,
    private val page: () -> PageRect,
) {
    companion object {
        /** The pen touches the glass. */
        const val CONTACT_INTENSITY = 1.0f
        /** The pen hovers above the glass. */
        const val HOVER_INTENSITY = 0.5f
        /** Seconds the Mac keeps fading a laser point after the last one. */
        const val DECAY_S = 0.5f

        fun intensity(contact: Boolean): Float = if (contact) CONTACT_INTENSITY else HOVER_INTENSITY
    }

    private var pendingX = 0f
    private var pendingY = 0f
    private var pendingIntensity = 0f
    private var hasPending = false
    private var frameRequested = false

    /** A position is waiting for the next frame. */
    val isPending: Boolean get() = hasPending

    /** Stylus contact (ACTION_DOWN or ACTION_MOVE of the pen pointer), in view pixels. */
    fun contact(viewX: Float, viewY: Float) = move(viewX, viewY, intensity(contact = true))

    /** Stylus hover (ACTION_HOVER_MOVE), in view pixels. */
    fun hover(viewX: Float, viewY: Float) = move(viewX, viewY, intensity(contact = false))

    /** Choreographer frame: ship the newest position gathered since the last one. */
    fun onFrame() {
        frameRequested = false
        if (!hasPending) return
        hasPending = false
        if (!transport.inkAllowed) return
        transport.send(encoder.laserPoint(pendingX, pendingY, pendingIntensity, DECAY_S))
    }

    /** Another tool was selected: a position not yet sent is dropped. */
    fun reset() {
        hasPending = false
    }

    private fun move(viewX: Float, viewY: Float, intensity: Float) {
        val p = page()
        if (p.width <= 0f || p.height <= 0f) return
        pendingX = p.toCanvasX(viewX)
        pendingY = p.toCanvasY(viewY)
        pendingIntensity = intensity
        hasPending = true
        if (!frameRequested) {
            frameRequested = true
            frames.requestFrame { onFrame() }
        }
    }
}
