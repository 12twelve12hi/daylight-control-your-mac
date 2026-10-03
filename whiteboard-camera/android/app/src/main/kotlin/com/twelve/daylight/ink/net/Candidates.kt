package com.twelve.daylight.ink.net

import com.twelve.daylight.ink.protocol.SolStream

/**
 * Where to dial, in SPEC 9.3 order: Bonjour results, 127.0.0.1:7788 (alive only while `adb reverse` is active),
 * the remembered manual host, then the host handed over by `am start --es host`. Duplicates collapse onto their
 * first position; a failed candidate is skipped until every candidate has failed once, then the rotation restarts.
 */
class Candidates(private val loopbackPort: Int = SolStream.DEFAULT_PORT) {
    companion object {
        const val LOOPBACK_HOST = "127.0.0.1"

        /** `host`, `host:port`, `[v6]:port` or a full `ws://` / `http://` URL -> `ws://host:port/ink`. Null for junk. */
        fun url(hostSpec: String?, defaultPort: Int = SolStream.DEFAULT_PORT): String? {
            var s = hostSpec?.trim() ?: return null
            if (s.isEmpty()) return null
            s = s.removePrefix("ws://").removePrefix("http://").removePrefix("https://")
            s = s.substringBefore('/')
            if (s.isEmpty()) return null
            val host: String
            val port: Int
            if (s.startsWith("[")) {                       // [v6]:port
                val close = s.indexOf(']')
                if (close < 0) return null
                host = s.substring(0, close + 1)
                val rest = s.substring(close + 1)
                port = if (rest.startsWith(":")) rest.substring(1).toIntOrNull() ?: return null else defaultPort
            } else if (s.count { it == ':' } == 1) {       // v4 or name with port
                host = s.substringBefore(':')
                port = s.substringAfter(':').toIntOrNull() ?: return null
            } else if (s.contains(':')) {                  // bare v6
                host = "[$s]"
                port = defaultPort
            } else {
                host = s
                port = defaultPort
            }
            if (host.isEmpty() || port !in 1..65535) return null
            // Whitespace or a percent sign (a zone id such as fe80::1%wlan0, or an escape) never parse as a URL host.
            if (host.any { it.isWhitespace() || it == '%' }) return null
            return "ws://$host:$port/ink"
        }
    }

    private val discovered = ArrayList<Pair<String, String>>()   // (service name, url), newest first
    private var manual: String? = null
    private var intent: String? = null
    private val failed = LinkedHashSet<String>()

    /** Set when `next()` had to restart the rotation: every candidate failed once; the caller should back off. */
    var rotationCompleted: Boolean = false
        private set

    fun fromDiscovery(serviceName: String, host: String, port: Int) {
        val h = host.trim().removePrefix("[").removeSuffix("]")
        val u = url(if (h.contains(':')) "[$h]:$port" else "$h:$port") ?: return
        discovered.removeAll { it.first == serviceName }
        discovered.add(0, serviceName to u)
    }

    fun lost(serviceName: String) {
        discovered.removeAll { it.first == serviceName }
    }

    fun setManual(hostSpec: String?) { manual = url(hostSpec) }
    fun setIntentHost(hostSpec: String?) { intent = url(hostSpec) }

    /** The ordered, de-duplicated list. */
    fun all(): List<String> {
        val out = LinkedHashSet<String>()
        for ((_, u) in discovered) out.add(u)
        out.add("ws://$LOOPBACK_HOST:$loopbackPort/ink")
        manual?.let { out.add(it) }
        intent?.let { out.add(it) }
        return out.toList()
    }

    fun next(): String {
        val list = all()
        rotationCompleted = false
        val fresh = list.firstOrNull { it !in failed }
        if (fresh != null) return fresh
        failed.clear()
        rotationCompleted = true
        return list.first()
    }

    fun reportFailure(url: String) { failed.add(url) }

    fun reportSuccess(url: String) { failed.clear(); rotationCompleted = false }

    /** The owner asked for a fresh try: forget which candidates failed. */
    fun resetFailures() { failed.clear(); rotationCompleted = false }
}
