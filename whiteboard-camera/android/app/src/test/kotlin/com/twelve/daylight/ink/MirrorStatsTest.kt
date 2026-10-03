package com.twelve.daylight.ink

import com.twelve.daylight.ink.mirror.EncoderSizing
import com.twelve.daylight.ink.mirror.MirrorStats
import org.junit.Assert.assertEquals
import org.junit.Test

/** PROTOCOL 14.3 `fps_x10` and `sent_bps` over a 1 s window, and the 14.4 `max_size` encoder sizing. */
class MirrorStatsTest {
    @Test
    fun thirtyAccessUnitsInOneSecondAre300() {
        val s = MirrorStats()
        for (i in 0 until 30) s.record(1000L + i * 33, 1000, accessUnit = true)
        assertEquals(300, s.fpsX10(1999))
        assertEquals(30 * 1000 * 8L, s.sentBps(1999))
    }

    @Test
    fun configAndSessionPacketsCountAsBytesNotFrames() {
        val s = MirrorStats()
        s.record(0, 84, accessUnit = false)            // HELLO
        s.record(0, 28, accessUnit = false)            // session
        s.record(1, 48, accessUnit = false)            // config
        s.record(2, 1000, accessUnit = true)
        assertEquals(10, s.fpsX10(500))
        assertEquals((84 + 28 + 48 + 1000) * 8L, s.sentBps(500))
    }

    @Test
    fun packetsLeaveTheWindowAfterExactlyOneSecond() {
        val s = MirrorStats()
        s.record(1000, 500, true)
        s.record(1500, 500, true)
        assertEquals(20, s.fpsX10(1999))
        assertEquals(10, s.fpsX10(2000))               // the first is 1000 ms old: out
        assertEquals(4000L, s.sentBps(2000))
        assertEquals(0, s.fpsX10(2500))
        assertEquals(0L, s.sentBps(2500))
    }

    @Test
    fun theGoldenStreamingNumbersAreReachable() {
        // 6,543,210 bps is 817,901.25 bytes a second: 30 frames of 27,263 bytes plus one 11-byte packet are 817,901.
        val s = MirrorStats()
        for (i in 0 until 30) s.record(i * 33L, 27_263, true)
        s.record(999, 11, false)
        assertEquals(300, s.fpsX10(999))
        assertEquals(817_901L * 8, s.sentBps(999))
    }

    @Test
    fun resetEmptiesTheWindow() {
        val s = MirrorStats()
        s.record(0, 100, true)
        s.reset()
        assertEquals(0, s.fpsX10(1))
        assertEquals(0L, s.sentBps(1))
    }

    @Test
    fun theDc1PortraitScreenEncodesAt1200By1600() {
        assertEquals(EncoderSizing.Size(1200, 1600), EncoderSizing.fit(1200, 1600, 1600))
        assertEquals(EncoderSizing.Size(1600, 1200), EncoderSizing.fit(1600, 1200, 1600))
    }

    @Test
    fun theLongSideIsCappedTheAspectKeptAndBothSidesAreMultiplesOf16() {
        assertEquals(EncoderSizing.Size(960, 1280), EncoderSizing.fit(1200, 1600, 1280))
        // 1080 x 2400 at 1600: short side 720 exactly.
        assertEquals(EncoderSizing.Size(720, 1600), EncoderSizing.fit(1080, 2400, 1600))
        // 1000 x 1333 at 1600: no upscaling, 1333 -> 1328, 1000 * 1328 / 1333 = 996.2 -> 992.
        assertEquals(EncoderSizing.Size(992, 1328), EncoderSizing.fit(1000, 1333, 1600))
        for (s in listOf(EncoderSizing.fit(1234, 1777, 1600), EncoderSizing.fit(1777, 1234, 333))) {
            assertEquals(0, s.width % 16)
            assertEquals(0, s.height % 16)
        }
    }

    @Test
    fun fallbackSizesShrinkFromTheRequestedOne() {
        val c = EncoderSizing.candidates(1200, 1600, 1600)
        assertEquals(EncoderSizing.Size(1200, 1600), c.first())
        assertEquals(EncoderSizing.Size(960, 1280), c[1])
        assertEquals(EncoderSizing.Size(768, 1024), c[2])
        assertEquals(EncoderSizing.Size(240, 320), c.last())
        val longs = c.map { maxOf(it.width, it.height) }
        assertEquals(longs.sortedDescending(), longs)
        assertEquals(longs.distinct(), longs)
        assertEquals(EncoderSizing.Size(720, 960), EncoderSizing.candidates(1200, 1600, 960).first())
    }
}
