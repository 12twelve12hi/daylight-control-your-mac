package com.twelve.daylight.ink.ink

/**
 * The routing half of [PenInput], free of Android classes so the JVM tests drive the same decisions with plain numbers:
 * which pen events reach the [StrokeSession] and which move the [LaserPointer] (SPEC E6, LOOSE_ENDS F3). PenInput
 * filters tool types, unpacks MotionEvents and draws the wet layer; every call into the session for a contact is here.
 *
 * The laser rule both clients share (the web page's `laserIntensity` and `laserTakesSample` say the same):
 * - With the Laser tool selected, a stylus or eraser-end contact moves the laser at contact intensity whatever its
 *   pressure (pressure 0 included) and nothing reaches the session; a stylus hover moves it at hover intensity; an
 *   eraser end in the air never points.
 * - Picking Laser while a stroke or an erase is open lets that contact run to its own pen-up, where it ends normally
 *   (a STROKE_COMMIT, never a STROKE_CANCEL, so the Mac keeps it); the laser starts with the next contact.
 * - Picking another tool while the laser touches: that contact draws nothing; the next pen-down does.
 */
class PenRouter(private val session: StrokeSession) {
    /** How a session contact ended, so the caller settles the wet layer the same way. */
    enum class End { NONE, UP, CANCEL }

    /** Set by the activity; while null the Laser tool sends nothing. */
    var laser: LaserPointer? = null

    /** The pointer of the current pen contact (a stroke, an erase or the laser); -1 when none. */
    var penPointerId: Int = -1
        private set

    /** The current contact went to the session (a stroke, an erase, or a pressure-0 down waiting for pressure). */
    private var sessionContact = false

    /** The Laser tool is selected: contact and stylus hover go to [laser], never to the session or the wet layer. */
    var laserMode: Boolean = false
        set(v) {
            if (v == field) return
            // Laser to another tool while the laser touches: that contact ends here and draws nothing.
            if (field && penPointerId >= 0 && !sessionContact) penPointerId = -1
            field = v
            if (!v) laser?.reset()
        }

    /** A stroke or an erase is open in the session (not merely a pressure-0 down waiting to start). */
    private val strokeOpen: Boolean get() = sessionContact && session.isDrawing

    /** Contact events go to the laser: the Laser tool is selected and no stroke or erase begun before it is still open. */
    val laserTakesContact: Boolean get() = laserMode && !strokeOpen

    /**
     * ACTION_DOWN of a stylus or eraser pointer, in view pixels. Returns true when it went to the session (the caller
     * starts a fresh wet stroke), false when the laser took it.
     */
    fun down(pointerId: Int, viewX: Float, viewY: Float, rawPressure: Float, timeMs: Long, eraserPointer: Boolean): Boolean {
        if (penPointerId >= 0 && sessionContact) session.cancel()     // the last contact never lifted
        sessionContact = false
        penPointerId = pointerId
        if (laserMode) {
            laser?.contact(viewX, viewY)
            return false
        }
        sessionContact = true
        session.down(viewX, viewY, rawPressure, timeMs, eraserPointer)
        return true
    }

    /** ACTION_MOVE of the contact pointer while [laserTakesContact]: its newest position, at contact intensity. */
    fun laserMove(viewX: Float, viewY: Float) {
        if (penPointerId < 0) return
        if (sessionContact) {
            // A pressure-0 down from before Laser was picked never started a stroke: the laser takes the contact.
            session.cancel()
            sessionContact = false
        }
        laser?.contact(viewX, viewY)
    }

    /**
     * One unpacked sample of the session's contact (ACTION_MOVE while not [laserTakesContact]). Returns true when the
     * wet layer should draw the segment into it.
     */
    fun sample(viewX: Float, viewY: Float, rawPressure: Float, timeMs: Long): Boolean {
        val wasDrawing = session.isDrawing
        session.point(viewX, viewY, rawPressure, timeMs)
        return wasDrawing && session.isDrawing && session.tool != Tools.ERASER
    }

    /** ACTION_UP or ACTION_POINTER_UP of `pointerId`; `canceled` is FLAG_CANCELED. */
    fun up(pointerId: Int, canceled: Boolean): End {
        if (pointerId != penPointerId) return End.NONE
        penPointerId = -1
        if (!sessionContact) return End.NONE                         // the laser's contact: nothing to end
        sessionContact = false
        return if (canceled) {
            session.cancel()
            End.CANCEL
        } else {
            session.up()
            End.UP
        }
    }

    /** ACTION_CANCEL. A session contact is cancelled (a STROKE_CANCEL); the laser's contact just ends. */
    fun cancel(): End {
        val laserContact = laserTakesContact
        penPointerId = -1
        sessionContact = false
        if (laserContact) return End.NONE
        session.cancel()
        return End.CANCEL
    }

    /**
     * Stylus hover (ACTION_HOVER_ENTER, _MOVE, _EXIT). It never reaches the session (SPEC D3). With the Laser tool, a
     * stylus hover move points at hover intensity; an eraser end in the air never does (`stylus` false). Returns true
     * when the event was the laser's.
     */
    fun hover(stylus: Boolean, move: Boolean, viewX: Float, viewY: Float): Boolean {
        if (!laserMode || !stylus) return false
        if (move) laser?.hover(viewX, viewY)
        return true
    }
}
