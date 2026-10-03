package com.twelve.daylight.ink

import com.twelve.daylight.ink.net.Candidates
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** SPEC 16 E4: mDNS, 127.0.0.1:7788, manual host, --es host; de-duplication; failure rotation. */
class CandidatesTest {
    private val loop = "ws://127.0.0.1:7788/ink"

    @Test
    fun orderIsDiscoveryLoopbackManualIntent() {
        val c = Candidates()
        c.setIntentHost("100.64.1.2")
        c.setManual("192.168.1.40")
        c.fromDiscovery("Daylight Camera on studio", "192.168.1.10", 7788)
        assertEquals(listOf("ws://192.168.1.10:7788/ink", loop, "ws://192.168.1.40:7788/ink", "ws://100.64.1.2:7788/ink"), c.all())
        assertEquals("ws://192.168.1.10:7788/ink", c.next())
    }

    @Test
    fun loopbackIsAlwaysThereAndFirstWhenNothingWasFound() {
        val c = Candidates()
        assertEquals(listOf(loop), c.all())
        assertEquals(loop, c.next())
    }

    @Test
    fun duplicatesCollapseOntoTheirFirstPosition() {
        val c = Candidates()
        c.setManual("192.168.1.10")
        c.setIntentHost("192.168.1.10:7788")
        c.fromDiscovery("a", "192.168.1.10", 7788)
        assertEquals(listOf("ws://192.168.1.10:7788/ink", loop), c.all())
        c.setManual("127.0.0.1")
        assertEquals(listOf("ws://192.168.1.10:7788/ink", loop), c.all())
    }

    @Test
    fun newestDiscoveryGoesFirstAndLostServicesLeave() {
        val c = Candidates()
        c.fromDiscovery("a", "10.0.0.1", 7788)
        c.fromDiscovery("b", "10.0.0.2", 7789)
        assertEquals(listOf("ws://10.0.0.2:7789/ink", "ws://10.0.0.1:7788/ink", loop), c.all())
        c.fromDiscovery("a", "10.0.0.3", 7788)        // the same Mac moved address
        assertEquals(listOf("ws://10.0.0.3:7788/ink", "ws://10.0.0.2:7789/ink", loop), c.all())
        c.lost("b")
        assertEquals(listOf("ws://10.0.0.3:7788/ink", loop), c.all())
        c.fromDiscovery("v6", "fe80::1", 7790)                        // a resolved IPv6 host keeps its port
        assertEquals("ws://[fe80::1]:7790/ink", c.all()[0])
    }

    @Test
    fun failuresRotateThroughEveryCandidateThenRestart() {
        val c = Candidates()
        c.setManual("192.168.1.40")
        c.fromDiscovery("a", "10.0.0.1", 7788)
        val first = c.next(); assertEquals("ws://10.0.0.1:7788/ink", first); assertFalse(c.rotationCompleted)
        c.reportFailure(first)
        val second = c.next(); assertEquals(loop, second); assertFalse(c.rotationCompleted)
        c.reportFailure(second)
        val third = c.next(); assertEquals("ws://192.168.1.40:7788/ink", third); assertFalse(c.rotationCompleted)
        c.reportFailure(third)
        val again = c.next(); assertEquals(first, again); assertTrue(c.rotationCompleted)
        c.reportSuccess(again)
        assertFalse(c.rotationCompleted)
        c.reportFailure(again)
        assertEquals(loop, c.next())
    }

    @Test
    fun hostSpecsParseIntoInkUrls() {
        assertEquals("ws://192.168.1.40:7788/ink", Candidates.url("192.168.1.40"))
        assertEquals("ws://192.168.1.40:7799/ink", Candidates.url(" 192.168.1.40:7799 "))
        assertEquals("ws://studio.local:7788/ink", Candidates.url("http://studio.local:7788/"))
        assertEquals("ws://100.64.1.2:7788/ink", Candidates.url("ws://100.64.1.2:7788/ink"))
        assertEquals("ws://[fe80::1]:7788/ink", Candidates.url("fe80::1"))
        assertEquals("ws://[fe80::1]:7790/ink", Candidates.url("[fe80::1]:7790"))
        assertNull(Candidates.url(""))
        assertNull(Candidates.url(null))
        assertNull(Candidates.url("host:notaport"))
        assertNull(Candidates.url("host:70000"))
    }
}
