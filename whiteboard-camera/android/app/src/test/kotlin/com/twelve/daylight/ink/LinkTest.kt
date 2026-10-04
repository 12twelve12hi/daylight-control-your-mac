package com.twelve.daylight.ink

import com.twelve.daylight.ink.net.Backoff
import com.twelve.daylight.ink.net.Candidates
import com.twelve.daylight.ink.net.Identity
import com.twelve.daylight.ink.net.Link
import com.twelve.daylight.ink.net.LinkActions
import com.twelve.daylight.ink.net.Phase
import com.twelve.daylight.ink.protocol.Encoder
import com.twelve.daylight.ink.protocol.MirrorControl
import com.twelve.daylight.ink.protocol.SolStream
import com.twelve.daylight.ink.protocol.StateReport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** PROTOCOL 1 (subprotocol, backoff), 7 (identity), 8 (ACK rules) and 9 (ink gate), without a socket. */
class LinkTest {
    private class Recorder : LinkActions {
        val dials = ArrayList<Pair<String, Long>>()
        val sent = ArrayList<ByteArray>()
        val closes = ArrayList<Int>()
        val phases = ArrayList<Phase>()
        var states = 0
        var allowedCount = 0
        val controls = ArrayList<MirrorControl>()
        override fun dial(url: String, afterMs: Long) { dials.add(url to afterMs) }
        override fun send(frame: ByteArray): Boolean { sent.add(frame); return true }
        override fun close(code: Int, reason: String) { closes.add(code) }
        override fun phaseChanged(phase: Phase) { phases.add(phase) }
        override fun stateChanged(state: StateReport) { states++ }
        override fun pong(sequence: Long, rttMs: Long) {}
        override fun allowed() { allowedCount++ }
        override fun mirrorControl(control: MirrorControl) { controls.add(control) }
    }

    private val ackOk = unhex("da0102001000000040e2cfeeb540060080070000380400001e00000000000000")
    private val ackPending = unhex("da0102001000000040e2cfeeb540060080070000380400001e00000001000000")
    private val ackDenied = unhex("da0102001000000040e2cfeeb540060080070000380400001e00000002000000")
    private val ackUnsupported = unhex("da0102001000000040e2cfeeb540060080070000380400001e00000003000000")
    private val ackStatus4 = unhex("da0102001000000040e2cfeeb540060080070000380400001e00000004000000")
    private val ackStatusMax = unhex("da0102001000000040e2cfeeb540060080070000380400001e000000ffffffff")
    private val ackShort = unhex("da0102000c00000040e2cfeeb540060080070000380400001e000000")
    private val stateLivePinned = unhex("da0170001400000040e2cfeeb5400600020d00010000803fffffffff0000030003000000")
    private val mirrorStart = unhex("da0171000c00000040e2cfeeb540060001004006c0cf6a001e00d007")   // golden mirror_control_start
    private fun unhex(s: String) = ByteArray(s.length / 2) { i -> s.substring(i * 2, i * 2 + 2).toInt(16).toByte() }

    private fun link(r: Recorder, random: Double = 0.5): Link {
        val c = Candidates()
        c.setManual("192.168.1.40")
        val l = Link(r, Encoder { 1760000000123456L }, c, Backoff { random }) { 5000L }
        l.configure(Identity.ROLE_INK, "6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b", "Mike's DC-1")
        return l
    }

    private fun open(l: Link, r: Recorder) {
        val (url, _) = r.dials.last()
        l.dialing(url)
        l.opened(SolStream.SUBPROTOCOL)
    }

    @Test
    fun startDialsTheFirstCandidateAtOnceAndHandshakesOnOpen() {
        val r = Recorder()
        val l = link(r)
        l.start()
        assertEquals(listOf("ws://127.0.0.1:7788/ink" to 0L), r.dials)
        open(l, r)
        assertEquals(Phase.CONNECTING, l.phase)
        val f = Frame(r.sent.single())
        assertEquals(SolStream.Op.HANDSHAKE, f.opcode)
        assertEquals(1200f, f.f32(), 0f); assertEquals(1600f, f.f32(), 0f); assertEquals(200f, f.f32(), 0f)
        val n = f.u16()
        val name = ByteArray(n).also { b -> for (i in 0 until n) b[i] = f.u8().toByte() }.toString(Charsets.UTF_8)
        assertEquals("ink;6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b;Mike's DC-1", name)
        assertFalse(l.inkAllowed)
    }

    @Test
    fun pingWaitsForTheAck() {
        val r = Recorder(); val l = link(r); l.start()
        l.ping()
        assertEquals(0, r.sent.size)                       // searching: no socket
        l.dialing(r.dials.last().first)
        l.ping()
        assertEquals(0, r.sent.size)                       // dialing: the Mac would close 1002 on a PING before HANDSHAKE
        l.opened(SolStream.SUBPROTOCOL)
        assertEquals(1, r.sent.size)                       // the HANDSHAKE only
        l.ping()
        assertEquals(1, r.sent.size)                       // still waiting for the ACK
        l.received(ackPending)
        l.ping()
        assertEquals(2, r.sent.size)                       // PENDING: a PING keeps the socket alive while the owner decides
        assertEquals(SolStream.Op.PING, Frame(r.sent.last()).opcode)
        l.received(ackOk)
        l.ping()
        assertEquals(3, r.sent.size)
    }

    @Test
    fun ackOkOpensTheInkGateAndStateFlows() {
        val r = Recorder(); val l = link(r); l.start(); open(l, r)
        l.received(ackOk)
        assertEquals(Phase.LIVE, l.phase)
        assertTrue(l.inkAllowed)
        l.received(stateLivePinned)
        assertEquals(1, r.states)
        assertNotNull(l.lastState)
        assertTrue(l.lastState!!.pinned)
        assertEquals(5000L, l.lastStateAtMs)
    }

    @Test
    fun ackPendingKeepsInkShutUntilAckOkArrives() {
        val r = Recorder(); val l = link(r); l.start(); open(l, r)
        l.received(ackPending)
        assertEquals(Phase.PENDING, l.phase)
        assertFalse(l.inkAllowed)
        l.received(ackOk)
        assertEquals(Phase.LIVE, l.phase)
        assertTrue(l.inkAllowed)
    }

    @Test
    fun deniedAndUnsupportedStopTheRedialUntilTheOwnerTaps() {
        for (ack in listOf(ackDenied, ackUnsupported)) {
            val r = Recorder(); val l = link(r); l.start(); open(l, r)
            l.received(ack)
            val expected = if (ack === ackDenied) Phase.DENIED else Phase.INCOMPATIBLE
            assertEquals(expected, l.phase)
            val dialsBefore = r.dials.size
            l.closed(failure = false)
            assertEquals(dialsBefore, r.dials.size)
            assertEquals(expected, l.phase)
            l.userRetry()
            assertEquals(Phase.SEARCHING, l.phase)
            assertEquals(dialsBefore + 1, r.dials.size)
            assertEquals(0L, r.dials.last().second)
        }
    }

    @Test
    fun anAckThatDoesNotDecodeIsIncompatibleInsteadOfHangingAtConnecting() {
        // FZ-3: the decoder drops an ACK whose status is outside 0..3 (PROTOCOL 10). Link has no handshake timeout, so
        // while it waits for an ACK it treats such a frame as a newer Mac: "Update Daylight", close, no re-dial.
        for (bad in listOf(ackStatus4, ackStatusMax, ackShort)) {
            val r = Recorder(); val l = link(r); l.start(); open(l, r)
            l.received(bad)
            assertEquals(Phase.INCOMPATIBLE, l.phase)
            assertEquals(listOf(1002), r.closes)
            assertFalse(l.inkAllowed)
            assertEquals(null, l.lastAck)
            l.closed(failure = false)
            assertEquals(1, r.dials.size)
            assertEquals(Phase.INCOMPATIBLE, l.phase)
            l.userRetry()
            assertEquals(Phase.SEARCHING, l.phase)
            assertEquals(2, r.dials.size)
        }
        // PENDING still waits for the owner's answer, so an unreadable second ACK is incompatible too.
        val r = Recorder(); val l = link(r); l.start(); open(l, r)
        l.received(ackPending)
        l.received(ackStatus4)
        assertEquals(Phase.INCOMPATIBLE, l.phase)
        assertEquals(listOf(1002), r.closes)
    }

    @Test
    fun anUndecodableAckOnALiveLinkIsDroppedAndOtherBadFramesNeverChangeThePhase() {
        val r = Recorder(); val l = link(r); l.start(); open(l, r)
        l.received(unhex("da0170001400000040e2cfeeb5400600040d00010000803fffffffff0000030003000000"))   // governor 4
        l.received(unhex("da01fd0000000000"))                                                            // short header
        assertEquals(Phase.CONNECTING, l.phase)                                                          // only an ACK opcode counts
        assertTrue(r.closes.isEmpty())
        l.received(ackOk)
        l.received(ackStatus4)
        assertEquals(Phase.LIVE, l.phase)                                                                // decided: dropped
        assertTrue(r.closes.isEmpty())
        assertEquals(0, r.states)
    }

    @Test
    fun aServerThatDoesNotEchoTheSubprotocolIsIncompatible() {
        val r = Recorder(); val l = link(r); l.start()
        l.dialing(r.dials.last().first)
        l.opened(null)
        assertEquals(Phase.INCOMPATIBLE, l.phase)
        assertEquals(listOf(1002), r.closes)
        assertTrue(r.sent.isEmpty())
        l.closed(failure = false)
        assertEquals(1, r.dials.size)
    }

    @Test
    fun failuresWalkTheCandidatesThenBackOffWithJitter() {
        val r = Recorder(); val l = link(r, random = 1.0)
        l.start()
        assertEquals("ws://127.0.0.1:7788/ink", r.dials[0].first)
        l.dialing(r.dials[0].first); l.closed(failure = true)
        assertEquals("ws://192.168.1.40:7788/ink" to 0L, r.dials[1])      // next candidate, no wait
        l.dialing(r.dials[1].first); l.closed(failure = true)
        assertEquals("ws://127.0.0.1:7788/ink", r.dials[2].first)          // rotation restarted: wait
        assertEquals(600L, r.dials[2].second)                              // 500 ms * 1.2 (jitter at +20 percent)
        l.dialing(r.dials[2].first); l.closed(failure = true)
        l.dialing(r.dials[3].first); l.closed(failure = true)
        assertEquals(1200L, r.dials[4].second)                             // 1000 ms * 1.2
    }

    @Test
    fun backoffDoublesFromHalfASecondToEightSecondsWithTwentyPercentJitter() {
        val low = Backoff { 0.0 }
        assertEquals(listOf(400L, 800L, 1600L, 3200L, 6400L, 6400L), (1..6).map { low.nextDelayMs() })
        val high = Backoff { 1.0 }
        assertEquals(listOf(600L, 1200L, 2400L, 4800L, 9600L, 9600L), (1..6).map { high.nextDelayMs() })
        val mid = Backoff { 0.5 }
        assertEquals(listOf(500L, 1000L, 2000L, 4000L, 8000L, 8000L, 8000L), (1..7).map { mid.nextDelayMs() })
        mid.reset()
        assertEquals(500L, mid.nextDelayMs())
    }

    @Test
    fun aDropAfterLiveRedialsAfterABackoffAndClearsState() {
        val r = Recorder(); val l = link(r, random = 0.5); l.start(); open(l, r)
        l.received(ackOk); l.received(stateLivePinned)
        l.closed(failure = true)
        assertEquals(Phase.SEARCHING, l.phase)
        assertEquals(500L, r.dials.last().second)
        assertEquals(null, l.lastState)
        assertFalse(l.inkAllowed)
    }

    @Test
    fun aRoleChangeWhileConnectedReopensTheSocket() {
        val r = Recorder(); val l = link(r); l.start(); open(l, r); l.received(ackOk)
        l.configure(Identity.ROLE_OVERLAY, "6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b", "Mike's DC-1")
        assertEquals(listOf(1000), r.closes)
        assertEquals(Phase.SEARCHING, l.phase)
        assertEquals(2, r.dials.size)
        open(l, r)
        val f = Frame(r.sent.last()); f.f32(); f.f32(); f.f32()
        val n = f.u16()
        val name = ByteArray(n).also { b -> for (i in 0 until n) b[i] = f.u8().toByte() }.toString(Charsets.UTF_8)
        assertTrue(name.startsWith("overlay;6f1a2b3c"))
    }

    @Test
    fun pingCarriesASequenceAndTheClock() {
        val r = Recorder(); val l = link(r); l.start(); open(l, r); l.received(ackOk)
        r.sent.clear()
        l.ping(); l.ping()
        val f = Frame(r.sent[1])
        assertEquals(SolStream.Op.PING, f.opcode)
        assertEquals(2L, f.u64())
        assertEquals(5000L * 1000L, f.u64())
    }

    @Test
    fun everyAckOkSignalsAllowedSoTheMirrorStatusFollowsIt() {
        val r = Recorder(); val l = link(r); l.start(); open(l, r)
        l.received(ackPending)
        assertEquals(0, r.allowedCount)
        l.received(ackOk)
        assertEquals(1, r.allowedCount)
        l.closed(failure = false)
        open(l, r)
        l.received(ackOk)
        assertEquals(2, r.allowedCount)                       // once per connection (PROTOCOL 14.3)
    }

    @Test
    fun mirrorControlReachesTheMirrorOnlyOnAnAllowedConnection() {
        val r = Recorder(); val l = link(r); l.start(); open(l, r)
        l.received(mirrorStart)
        assertEquals(0, r.controls.size)                      // before ACK 0
        l.received(ackPending)
        l.received(mirrorStart)
        assertEquals(0, r.controls.size)                      // pending
        l.received(ackOk)
        l.received(mirrorStart)
        assertEquals(listOf(MirrorControl(MirrorControl.START, 1600, 7_000_000L, 30, 2000)), r.controls)
        assertEquals(0, r.states)                             // a MIRROR_CONTROL is not a STATE
        assertEquals(Phase.LIVE, l.phase)
    }

    @Test
    fun stopClosesAndNothingIsSentAfterwards() {
        val r = Recorder(); val l = link(r); l.start(); open(l, r); l.received(ackOk)
        l.stop()
        assertEquals(listOf(1000), r.closes)
        assertFalse(l.inkAllowed)
        val before = r.sent.size
        l.ping()
        assertEquals(before, r.sent.size)
    }

    @Test
    fun identityClampsTheLabelAndKeepsTheName() {
        assertEquals("ink;abc;Mike's DC-1", Identity.handshakeName("ink", "abc", "Mike's DC-1"))
        assertEquals("overlay;abc;no semicolons here", Identity.handshakeName("overlay", "abc", "no;semicolons;here"))
        val long = "x".repeat(100)
        assertEquals(64, Identity.clampLabel(long).toByteArray(Charsets.UTF_8).size)
        val emoji = "😀".repeat(20)           // 4 bytes each: 80 bytes -> 16 emoji (64 bytes), never a half pair
        val clamped = Identity.clampLabel(emoji)
        assertEquals(64, clamped.toByteArray(Charsets.UTF_8).size)
        assertEquals(16, clamped.codePointCount(0, clamped.length))
        assertEquals("Daylight Ink on DC-1", Identity.defaultLabel("DC-1"))
        assertEquals("Daylight Ink", Identity.defaultLabel(null))
        assertEquals("Daylight Ink", Identity.clampLabel(";;"))
    }
}
