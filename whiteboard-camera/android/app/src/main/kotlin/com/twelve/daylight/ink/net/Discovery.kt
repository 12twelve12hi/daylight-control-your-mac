package com.twelve.daylight.ink.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.twelve.daylight.ink.Facts
import com.twelve.daylight.ink.protocol.SolStream

/**
 * Bonjour discovery of `_daylight-camera._tcp` through the legacy NsdManager path (research-android-ink 3.1 and 10.3):
 * one resolve at a time, a MulticastLock when the Tethering extension is below 7, try/catch around stop.
 * Callbacks arrive on NsdManager's own thread and are posted to the main thread.
 */
class Discovery(context: Context) {
    companion object {
        const val TAG = "DaylightInk.net"
        const val SERVICE_TYPE = SolStream.SERVICE_TYPE
        /** Android 13 devices below Tethering extension 7 need the multicast lock (reference: NsdManager). */
        const val MULTICAST_LOCK_BELOW_EXTENSION = 7
    }

    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val nsd: NsdManager? = app.getSystemService(NsdManager::class.java)
    private var lock: WifiManager.MulticastLock? = null
    private var listener: NsdManager.DiscoveryListener? = null
    private var queue: DiscoveryQueue? = null
    private var onHost: ((String, String, Int) -> Unit)? = null
    private var onLost: ((String) -> Unit)? = null

    val running: Boolean get() = listener != null

    private val resolver = object : Resolver {
        override fun resolve(service: ServiceRef, callback: (ResolveResult) -> Unit) {
            val info = service.platform as? NsdServiceInfo
            val manager = nsd
            if (info == null || manager == null) { callback(ResolveResult.Failed(0)); return }
            val rl = object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    main.post { callback(ResolveResult.Failed(errorCode)) }
                }
                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    @Suppress("DEPRECATION")
                    val host = serviceInfo.host?.hostAddress?.substringBefore('%')
                    val port = serviceInfo.port
                    main.post {
                        if (host.isNullOrEmpty() || port <= 0) callback(ResolveResult.Failed(0))
                        else callback(ResolveResult.Resolved(host, port))
                    }
                }
            }
            try {
                @Suppress("DEPRECATION")
                manager.resolveService(info, rl)
            } catch (e: RuntimeException) {
                Log.w(TAG, "resolveService threw: $e")
                main.post { callback(ResolveResult.Failed(0)) }
            }
        }
    }

    fun start(onHost: (name: String, host: String, port: Int) -> Unit, onLost: (name: String) -> Unit) {
        if (listener != null) return
        val manager = nsd ?: run { Log.w(TAG, "no NsdManager on this device"); return }
        this.onHost = onHost
        this.onLost = onLost
        val q = DiscoveryQueue(resolver, { s, host, port ->
            Log.i(TAG, "resolved ${s.name} -> $host:$port")
            this.onHost?.invoke(s.name, host, port)
        }, { s, code -> Log.w(TAG, "resolve failed for ${s.name}: $code") })
        queue = q
        val ext = Facts.tiramisuExtension()
        if (ext < MULTICAST_LOCK_BELOW_EXTENSION) {
            runCatching {
                val wifi = app.getSystemService(WifiManager::class.java)
                lock = wifi?.createMulticastLock("daylight-ink")?.apply { setReferenceCounted(false); acquire() }
                Log.i(TAG, "multicast lock acquired (tiramisuExt=$ext)")
            }.onFailure { Log.w(TAG, "multicast lock failed: $it") }
        }
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) { Log.i(TAG, "discoverServices started: $regType") }
            override fun onDiscoveryStopped(serviceType: String) { Log.i(TAG, "discovery stopped") }
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "discoverServices failed: $errorCode")
                main.post { stop() }
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) { Log.w(TAG, "stop failed: $errorCode") }
            override fun onServiceFound(info: NsdServiceInfo) {
                // The type string may carry a leading or trailing dot depending on the OS build: compare loosely.
                if (info.serviceType?.contains(SERVICE_TYPE) != true) return
                val name = info.serviceName ?: return
                main.post { queue?.found(ServiceRef(name, info)) }
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                val name = info.serviceName ?: return
                main.post { queue?.lost(ServiceRef(name, info)); this@Discovery.onLost?.invoke(name) }
            }
        }
        listener = l
        try {
            manager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
        } catch (e: RuntimeException) {
            Log.w(TAG, "discoverServices threw: $e")
            listener = null
            releaseLock()
        }
    }

    fun stop() {
        val l = listener
        listener = null
        queue?.clear()
        queue = null
        if (l != null) {
            try { nsd?.stopServiceDiscovery(l) } catch (e: IllegalArgumentException) { /* not registered any more: fine */ }
        }
        releaseLock()
    }

    private fun releaseLock() {
        runCatching { lock?.takeIf { it.isHeld }?.release() }
        lock = null
    }
}
