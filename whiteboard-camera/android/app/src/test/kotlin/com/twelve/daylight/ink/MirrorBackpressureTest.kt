package com.twelve.daylight.ink

import com.twelve.daylight.ink.mirror.MirrorBackpressure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PROTOCOL 14.2 backpressure: drop above 1 MiB queued, never key or config, one sync frame once below 256 KiB, and no
 * delta after a drop until a key frame.
 */
class MirrorBackpressureTest {
    private val mib = 1_048_576L
    private val kib256 = 262_144L

    @Test
    fun thresholdsAreOneMebibyteAnd256Kibibytes() {
        assertEquals(mib, MirrorBackpressure.HIGH_BYTES)
        assertEquals(kib256, MirrorBackpressure.LOW_BYTES)
    }

    @Test
    fun deltaFramesAreSentUpToAndIncludingOneMebibyteQueued() {
        val b = MirrorBackpressure()
        assertTrue(b.admit(0, keyOrConfig = false))
        assertTrue(b.admit(mib, keyOrConfig = false))
        assertEquals(0L, b.dropped)
        assertFalse(b.takeReportFlag())
    }

    @Test
    fun aDeltaFrameAboveOneMebibyteIsDroppedAndCounted() {
        val b = MirrorBackpressure()
        assertFalse(b.admit(mib + 1, keyOrConfig = false))
        assertFalse(b.admit(5 * mib, keyOrConfig = false))
        assertEquals(2L, b.dropped)
    }

    @Test
    fun keyFramesAndConfigAreNeverDropped() {
        val b = MirrorBackpressure()
        assertTrue(b.admit(10 * mib, keyOrConfig = true))
        assertEquals(0L, b.dropped)
        assertFalse(b.takeReportFlag())
        assertFalse(b.syncFrameWanted(0))
    }

    @Test
    fun theReportFlagIsSetByADropAndClearedByReading() {
        val b = MirrorBackpressure()
        b.admit(mib + 1, false)
        assertTrue(b.takeReportFlag())
        assertFalse(b.takeReportFlag())                 // "since the previous report"
        b.admit(mib + 1, false)
        assertTrue(b.takeReportFlag())
        assertEquals(2L, b.dropped)                     // the count keeps growing
    }

    @Test
    fun oneSyncFrameIsRequestedOnceTheQueueDrainsBelow256Kibibytes() {
        val b = MirrorBackpressure()
        assertFalse(b.syncFrameWanted(0))               // nothing dropped: no request
        b.admit(mib + 1, false)
        assertFalse(b.syncFrameWanted(mib))
        assertFalse(b.syncFrameWanted(kib256))          // not below yet
        assertTrue(b.syncFrameWanted(kib256 - 1))
        assertFalse(b.syncFrameWanted(0))               // once
        b.admit(2 * mib, false)
        b.admit(2 * mib, false)
        assertTrue(b.syncFrameWanted(100))              // a new episode, again once
        assertFalse(b.syncFrameWanted(100))
    }

    @Test
    fun afterADropEveryDeltaIsDroppedUntilAKeyFrame() {
        val b = MirrorBackpressure()
        val kib512 = 524_288L
        assertFalse(b.admit(2 * mib, false))
        assertFalse(b.admit(kib512, false))             // the queue is fine again, but this delta references a gap
        assertFalse(b.admit(0, false))
        assertEquals(3L, b.dropped)
        assertTrue(b.syncFrameWanted(0))                // the key frame is still requested once
        assertTrue(b.admit(kib512, true))               // the key frame ends the gap
        assertTrue(b.admit(kib512, false))
        assertTrue(b.admit(mib, false))
        assertEquals(3L, b.dropped)
    }

    @Test
    fun anOversizeGapDropsDeltasUntilAKeyFrame() {
        val b = MirrorBackpressure()
        b.markGap()
        assertFalse(b.admit(0, false))
        assertEquals(1L, b.dropped)
        assertTrue(b.admit(0, true))
        assertTrue(b.admit(0, false))
    }

    @Test
    fun resetEndsAGap() {
        val b = MirrorBackpressure()
        b.markGap()
        b.reset()                                       // a new stream starts with a key frame of its own
        assertTrue(b.admit(0, false))
    }

    @Test
    fun resetForgetsAPendingEpisodeButNotTheCount() {
        val b = MirrorBackpressure()
        b.admit(mib + 1, false)
        b.reset()
        assertFalse(b.syncFrameWanted(0))
        assertFalse(b.takeReportFlag())
        assertEquals(1L, b.dropped)
    }
}
