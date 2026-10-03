package com.twelve.daylight.ink.net

/** A found-but-unresolved service, as NsdServiceInfo gives it (name plus the opaque platform object). */
class ServiceRef(val name: String, val platform: Any? = null)

sealed class ResolveResult {
    class Resolved(val host: String, val port: Int) : ResolveResult()
    class Failed(val errorCode: Int) : ResolveResult()
}

/** The platform resolver (NsdManager.resolveService on the device, a fake in tests). One call in flight at a time. */
interface Resolver {
    fun resolve(service: ServiceRef, callback: (ResolveResult) -> Unit)
}

/**
 * NsdManager can resolve one service at a time: FAILURE_ALREADY_ACTIVE (3) means "try again later"
 * (research-android-ink 3.1). This queue serialises resolves and re-queues that one failure code.
 */
class DiscoveryQueue(
    private val resolver: Resolver,
    private val onResolved: (ServiceRef, String, Int) -> Unit,
    private val onFailed: (ServiceRef, Int) -> Unit = { _, _ -> },
) {
    companion object {
        /** NsdManager.FAILURE_ALREADY_ACTIVE */
        const val FAILURE_ALREADY_ACTIVE = 3
        const val MAX_RETRIES_PER_SERVICE = 5
    }

    private val pending = ArrayDeque<ServiceRef>()
    private val retries = HashMap<String, Int>()
    var resolving: ServiceRef? = null
        private set

    val queued: Int get() = pending.size

    fun found(service: ServiceRef) {
        if (resolving?.name == service.name) return
        if (pending.any { it.name == service.name }) return
        pending.addLast(service)
        resolveNext()
    }

    fun lost(service: ServiceRef) {
        pending.removeAll { it.name == service.name }
        retries.remove(service.name)
    }

    fun clear() {
        pending.clear()
        retries.clear()
    }

    private fun resolveNext() {
        if (resolving != null) return
        val s = pending.removeFirstOrNull() ?: return
        resolving = s
        resolver.resolve(s) { result -> finished(s, result) }
    }

    private fun finished(s: ServiceRef, result: ResolveResult) {
        if (resolving !== s) return
        resolving = null
        when (result) {
            is ResolveResult.Resolved -> {
                retries.remove(s.name)
                onResolved(s, result.host, result.port)
            }
            is ResolveResult.Failed -> {
                val n = (retries[s.name] ?: 0) + 1
                retries[s.name] = n
                if (result.errorCode == FAILURE_ALREADY_ACTIVE && n <= MAX_RETRIES_PER_SERVICE) {
                    pending.addFirst(s)
                } else {
                    retries.remove(s.name)
                    onFailed(s, result.errorCode)
                }
            }
        }
        resolveNext()
    }
}
