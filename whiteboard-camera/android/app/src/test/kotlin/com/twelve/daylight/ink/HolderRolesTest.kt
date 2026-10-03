package com.twelve.daylight.ink

import com.twelve.daylight.ink.net.Backoff
import com.twelve.daylight.ink.net.Candidates
import com.twelve.daylight.ink.net.HolderRoles
import com.twelve.daylight.ink.net.Identity
import com.twelve.daylight.ink.net.Link
import com.twelve.daylight.ink.net.LinkActions
import com.twelve.daylight.ink.net.Phase
import com.twelve.daylight.ink.protocol.Encoder
import com.twelve.daylight.ink.protocol.SolStream
import com.twelve.daylight.ink.protocol.StateReport
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * PROTOCOL 7 and 8 roles for the shared socket's holders, driven the way InkConnection drives [Link]: leaving or
 * returning to a Daylight Ink screen while the screen is shared must not redial (and so end the stream) for a role
 * flip, but the upgrade to `ink` and the downgrade with the pills present still happen at once.
 */
class HolderRolesTest {
    private val ackOk = unhex("da0102001000000040e2cfeeb540060080070000380400001e00000000000000")
    private fun unhex(s: String) = ByteArray(s.length / 2) { i -> s.substring(i * 2, i * 2 + 2).toInt(16).toByte() }

    /** InkConnection's acquire, release and phaseChanged rules on a [Link] with a recording [LinkActions]. */
    private class Conn {
        val holders = LinkedHashMap<String, String>()
        val closes = ArrayList<String>()
        val dials = ArrayList<String>()
        val link: Link
        init {
            val c = Candidates()
            c.setManual("192.168.1.40")
            val actions = object : LinkActions {
                override fun dial(url: String, afterMs: Long) { dials.add(url) }
                override fun send(frame: ByteArray): Boolean = true
                override fun close(code: Int, reason: String) { closes.add("$code $reason") }
                override fun phaseChanged(phase: Phase) {
                    if (phase == Phase.SEARCHING && holders.isNotEmpty()) applyIdentity()
                }
                override fun stateChanged(state: StateReport) {}
                override fun pong(sequence: Long, rttMs: Long) {}
            }
            link = Link(actions, Encoder { 1760000000123456L }, c, Backoff { 0.5 }) { 5000L }
        }
        fun applyIdentity() = link.configure(HolderRoles.role(holders, link.role, link.phase == Phase.LIVE), "id", "DC-1")
        fun acquire(tag: String, role: String) {
            holders[tag] = role
            applyIdentity()
            link.start()
        }
        fun release(tag: String) {
            holders.remove(tag)
            if (holders.isEmpty()) link.stop() else applyIdentity()
        }
        fun live(ack: ByteArray) {
            link.dialing(dials.last())
            link.opened(SolStream.SUBPROTOCOL)
            link.received(ack)
            assertEquals(Phase.LIVE, link.phase)
        }
    }

    @Test
    fun holderTagsMatchTheScreenShareAndThePills() {
        assertEquals("screen", HolderRoles.SCREEN)
        assertEquals("overlay", HolderRoles.PILLS)
        assertEquals(HolderRoles.SCREEN, com.twelve.daylight.ink.mirror.MirrorController.HOLDER)
        assertEquals(HolderRoles.PILLS, com.twelve.daylight.ink.overlay.OverlayService.HOLDER)
    }

    @Test
    fun leavingSettingsWhileSharingKeepsTheLiveSocket() {
        val c = Conn()
        c.acquire("settings", Identity.ROLE_INK)
        c.acquire(HolderRoles.SCREEN, Identity.ROLE_OVERLAY)
        c.live(ackOk)
        c.release("settings")                                   // Home: Settings stops
        assertEquals(emptyList<String>(), c.closes)             // no "role change" close, the stream goes on
        assertEquals(Phase.LIVE, c.link.phase)
        assertEquals(Identity.ROLE_INK, c.link.role)
        c.acquire("settings", Identity.ROLE_INK)                // and back: still no redial
        assertEquals(emptyList<String>(), c.closes)
    }

    @Test
    fun theDeferredDowngradeAppliesWhenTheShareEndsOrTheSocketRedials() {
        val c = Conn()
        c.acquire("settings", Identity.ROLE_INK)
        c.acquire(HolderRoles.SCREEN, Identity.ROLE_OVERLAY)
        c.acquire("other", Identity.ROLE_OVERLAY)
        c.live(ackOk)
        c.release("settings")
        c.release(HolderRoles.SCREEN)                           // the share ended
        assertEquals(listOf("1000 role change"), c.closes)
        assertEquals(Identity.ROLE_OVERLAY, c.link.role)

        val d = Conn()
        d.acquire("settings", Identity.ROLE_INK)
        d.acquire(HolderRoles.SCREEN, Identity.ROLE_OVERLAY)
        d.live(ackOk)
        d.release("settings")
        d.link.closed(failure = false)                          // Wi-Fi drop: the next dial is overlay
        assertEquals(Identity.ROLE_OVERLAY, d.link.role)
        assertEquals(emptyList<String>(), d.closes)
    }

    @Test
    fun withThePillsPresentTheDowngradeIsNotDeferred() {
        val c = Conn()
        c.acquire("settings", Identity.ROLE_INK)
        c.acquire(HolderRoles.SCREEN, Identity.ROLE_OVERLAY)
        c.acquire(HolderRoles.PILLS, Identity.ROLE_OVERLAY)
        c.live(ackOk)
        c.release("settings")
        assertEquals(listOf("1000 role change"), c.closes)
        assertEquals(Identity.ROLE_OVERLAY, c.link.role)
    }

    @Test
    fun theUpgradeToInkIsNeverDeferred() {
        val c = Conn()
        c.acquire(HolderRoles.SCREEN, Identity.ROLE_OVERLAY)
        c.live(ackOk)
        assertEquals(Identity.ROLE_OVERLAY, c.link.role)
        c.acquire("main", Identity.ROLE_INK)                    // the canvas opens
        assertEquals(listOf("1000 role change"), c.closes)
        assertEquals(Identity.ROLE_INK, c.link.role)
    }

    @Test
    fun withoutAScreenShareTheDowngradeIsImmediate() {
        val c = Conn()
        c.acquire("settings", Identity.ROLE_INK)
        c.acquire("other", Identity.ROLE_OVERLAY)
        c.live(ackOk)
        c.release("settings")
        assertEquals(listOf("1000 role change"), c.closes)
        assertEquals(Identity.ROLE_OVERLAY, HolderRoles.role(mapOf("other" to Identity.ROLE_OVERLAY), Identity.ROLE_INK, live = true))
        assertEquals(Identity.ROLE_OVERLAY, HolderRoles.role(mapOf(HolderRoles.SCREEN to Identity.ROLE_OVERLAY), Identity.ROLE_INK, live = false))
        assertEquals(Identity.ROLE_INK, HolderRoles.role(mapOf(HolderRoles.SCREEN to Identity.ROLE_OVERLAY), Identity.ROLE_INK, live = true))
    }
}
