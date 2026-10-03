package com.twelve.daylight.ink

import com.twelve.daylight.ink.net.Phase
import com.twelve.daylight.ink.overlay.PillsLayout
import com.twelve.daylight.ink.overlay.PillsState
import com.twelve.daylight.ink.protocol.StateReport
import com.twelve.daylight.ink.ui.ChipKind
import com.twelve.daylight.ink.ui.ChipState
import com.twelve.daylight.ink.ui.ChipTap
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** SPEC section 10 (the chip table) and the pills of IMPLEMENTATION-PLAN 8 step 5. */
class ChipStateTest {
    private fun state(governor: Int, flags: Int, inkSource: Int = 1, msToReturn: Long = 0xFFFFFFFFL, undo: Int = 0, redo: Int = 0) =
        StateReport(governor, flags, 0, inkSource, if (governor == 0) 0f else 1f, msToReturn, 0, undo, undo, redo)

    private val allowedActive = 0x0C   // bit2 allowed, bit3 active source

    @Test
    fun connectionPhasesBeforeAnyState() {
        assertEquals("Looking for your Mac", ChipState.view(Phase.SEARCHING, null).text)
        assertEquals("Looking for your Mac", ChipState.view(Phase.CONNECTING, null).text)
        assertEquals("Looking for your Mac", ChipState.view(Phase.LIVE, null).text)
        val pending = ChipState.view(Phase.PENDING, null)
        assertEquals("Look at your Mac", pending.text); assertTrue(pending.dot); assertEquals(ChipTap.NONE, pending.tap)
        val denied = ChipState.view(Phase.DENIED, null)
        assertEquals("Not allowed by the Mac", denied.text); assertEquals(ChipTap.RETRY, denied.tap)
        val incompatible = ChipState.view(Phase.INCOMPATIBLE, null)
        assertEquals("Update Daylight on your Mac", incompatible.text); assertEquals(ChipTap.RETRY, incompatible.tap)
    }

    @Test
    fun stateRowsOfSpecSection10() {
        assertEquals("Look at your Mac", ChipState.view(Phase.LIVE, state(0, 0x00)).text)
        val inactive = ChipState.view(Phase.LIVE, state(2, 0x04, inkSource = 0))
        assertEquals("Ink source is web on the Mac", inactive.text); assertEquals(ChipTap.EXPLAIN, inactive.tap)
        assertEquals("Ink source is mirror on the Mac", ChipState.view(Phase.LIVE, state(2, 0x04, inkSource = 2)).text)
        assertEquals("Ink source is Daylight Ink on the Mac", ChipState.view(Phase.LIVE, state(2, 0x04, inkSource = 1)).text)
        val camera = ChipState.view(Phase.LIVE, state(0, allowedActive))
        assertEquals("Camera", camera.text); assertEquals(ChipKind.CAMERA, camera.kind); assertFalse(camera.dot); assertEquals(ChipTap.PIN, camera.tap); assertFalse(camera.longPressReturns)
        val live = ChipState.view(Phase.LIVE, state(2, allowedActive))
        assertEquals("LIVE", live.text); assertTrue(live.dot); assertFalse(live.breathing); assertTrue(live.longPressReturns)
        assertEquals("LIVE", ChipState.view(Phase.LIVE, state(1, allowedActive)).text)
        val returning = ChipState.view(Phase.LIVE, state(3, allowedActive, msToReturn = 0))
        assertEquals("Returning", returning.text); assertTrue(returning.dot); assertEquals(ChipTap.PIN, returning.tap)
        val pinned = ChipState.view(Phase.LIVE, state(2, allowedActive or 0x01))
        assertEquals("KEEP WHITEBOARD", pinned.text); assertEquals(ChipKind.PINNED, pinned.kind); assertFalse(pinned.dot)
        assertEquals("KEEP WHITEBOARD", ChipState.view(Phase.LIVE, state(1, allowedActive or 0x01)).text)
    }

    @Test
    fun preWarningCountsDownLocallyWithCeilSeconds() {
        val s = state(2, allowedActive or 0x02, msToReturn = 4200)
        val v0 = ChipState.view(Phase.LIVE, s, 0)
        assertEquals("Returning in 5", v0.text); assertTrue(v0.breathing); assertTrue(v0.dot); assertEquals(ChipKind.PREWARN, v0.kind)
        assertEquals("Returning in 4", ChipState.view(Phase.LIVE, s, 250).text)
        assertEquals("Returning in 1", ChipState.view(Phase.LIVE, s, 3900).text)
        assertEquals("Returning in 1", ChipState.view(Phase.LIVE, s, 9000).text)   // never below 1 while scheduled
        assertEquals(5, ChipState.returningSeconds(4200)); assertEquals(5, ChipState.returningSeconds(5000)); assertEquals(1, ChipState.returningSeconds(0))
        assertEquals("LIVE", ChipState.view(Phase.LIVE, state(2, allowedActive or 0x02)).text)   // pre_warning with no return scheduled: nothing to count
    }

    @Test
    fun breathIsHalfHertzInPhaseWithTheMacDivider() {
        assertEquals(0.0, ChipState.breath(0.0), 1e-9)
        assertEquals(0.5, ChipState.breath(0.5), 1e-9)
        assertEquals(1.0, ChipState.breath(1.0), 1e-9)
        assertEquals(0.5, ChipState.breath(1.5), 1e-9)
        assertEquals(0.0, ChipState.breath(2.0), 1e-9)
        assertEquals(600L, ChipState.LONG_PRESS_MS)
    }

    @Test
    fun pillsFollowThePinFlagAndTheBoard() {
        val off = PillsState.view(Phase.SEARCHING, null)
        assertEquals("Pin", off.pinLabel); assertFalse(off.enabled); assertFalse(off.liveDot)
        val camera = PillsState.view(Phase.LIVE, state(0, allowedActive))
        assertEquals("Pin", camera.pinLabel); assertTrue(camera.enabled); assertFalse(camera.liveDot); assertFalse(camera.pinFilled)
        val live = PillsState.view(Phase.LIVE, state(2, allowedActive))
        assertTrue(live.liveDot); assertFalse(live.pinFilled)
        val pinned = PillsState.view(Phase.LIVE, state(2, allowedActive or 0x01))
        assertEquals("KEEP", pinned.pinLabel); assertTrue(pinned.pinFilled); assertFalse(pinned.liveDot)
        assertTrue(PillsState.view(Phase.LIVE, state(2, 0x08, inkSource = 2)).enabled.not())   // bit2 clear: pending
    }

    @Test
    fun pillRowSitsInsideTheTop96PixelStrip() {
        val p = PillsLayout.placement(PillsLayout.Position.TOP)
        assertEquals(24, p.y)
        assertEquals(48, p.rowHeight)
        assertTrue(p.y + p.rowHeight <= PillsLayout.DEFAULT_STRIP_PX)
        assertEquals(96, PillsLayout.DEFAULT_STRIP_PX)
        val tight = PillsLayout.placement(PillsLayout.Position.TOP, 72)
        assertTrue(tight.y + tight.rowHeight <= 72)
        assertEquals(PillsLayout.Position.BOTTOM, PillsLayout.positionFrom("bottom"))
        assertEquals(PillsLayout.Position.TOP, PillsLayout.positionFrom("top"))
        assertEquals(PillsLayout.Position.TOP, PillsLayout.positionFrom(null))
    }
}
