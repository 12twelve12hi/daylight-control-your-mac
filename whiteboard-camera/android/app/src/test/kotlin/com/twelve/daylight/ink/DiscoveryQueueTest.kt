package com.twelve.daylight.ink

import com.twelve.daylight.ink.net.DiscoveryQueue
import com.twelve.daylight.ink.net.ResolveResult
import com.twelve.daylight.ink.net.Resolver
import com.twelve.daylight.ink.net.ServiceRef
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** ARCHITECTURE 11.5: one resolve at a time; FAILURE_ALREADY_ACTIVE re-queues. */
class DiscoveryQueueTest {
    private class FakeResolver : Resolver {
        val inFlight = ArrayList<Pair<ServiceRef, (ResolveResult) -> Unit>>()
        override fun resolve(service: ServiceRef, callback: (ResolveResult) -> Unit) { inFlight.add(service to callback) }
        fun finish(result: ResolveResult) { val (_, cb) = inFlight.removeAt(0); cb(result) }
    }

    @Test
    fun resolvesOneServiceAtATimeInFoundOrder() {
        val r = FakeResolver()
        val resolved = ArrayList<String>()
        val q = DiscoveryQueue(r, { s, host, port -> resolved.add("${s.name}@$host:$port") })
        q.found(ServiceRef("a")); q.found(ServiceRef("b")); q.found(ServiceRef("a"))
        assertEquals(1, r.inFlight.size)
        assertEquals("a", q.resolving!!.name)
        assertEquals(1, q.queued)
        r.finish(ResolveResult.Resolved("10.0.0.1", 7788))
        assertEquals(listOf("a@10.0.0.1:7788"), resolved)
        assertEquals("b", q.resolving!!.name)
        r.finish(ResolveResult.Resolved("10.0.0.2", 7788))
        assertEquals(listOf("a@10.0.0.1:7788", "b@10.0.0.2:7788"), resolved)
        assertNull(q.resolving)
    }

    @Test
    fun alreadyActiveRequeuesAtTheFrontOtherFailuresDrop() {
        val r = FakeResolver()
        val failed = ArrayList<Int>()
        val q = DiscoveryQueue(r, { _, _, _ -> }, { _, code -> failed.add(code) })
        q.found(ServiceRef("a")); q.found(ServiceRef("b"))
        r.finish(ResolveResult.Failed(DiscoveryQueue.FAILURE_ALREADY_ACTIVE))
        assertEquals("a", q.resolving!!.name)         // retried before b
        r.finish(ResolveResult.Failed(0))             // FAILURE_INTERNAL_ERROR: give up on a
        assertEquals(listOf(0), failed)
        assertEquals("b", q.resolving!!.name)
    }

    @Test
    fun alreadyActiveGivesUpAfterTheRetryBudget() {
        val r = FakeResolver()
        val failed = ArrayList<Int>()
        val q = DiscoveryQueue(r, { _, _, _ -> }, { _, code -> failed.add(code) })
        q.found(ServiceRef("a"))
        repeat(DiscoveryQueue.MAX_RETRIES_PER_SERVICE + 1) { r.finish(ResolveResult.Failed(DiscoveryQueue.FAILURE_ALREADY_ACTIVE)) }
        assertEquals(listOf(DiscoveryQueue.FAILURE_ALREADY_ACTIVE), failed)
        assertNull(q.resolving)
    }

    @Test
    fun lostRemovesAQueuedService() {
        val r = FakeResolver()
        val q = DiscoveryQueue(r, { _, _, _ -> })
        q.found(ServiceRef("a")); q.found(ServiceRef("b"))
        q.lost(ServiceRef("b"))
        assertEquals(0, q.queued)
        r.finish(ResolveResult.Resolved("h", 1))
        assertNull(q.resolving)
    }
}
