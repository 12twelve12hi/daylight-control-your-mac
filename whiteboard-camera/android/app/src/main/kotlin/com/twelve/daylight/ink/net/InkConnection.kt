package com.twelve.daylight.ink.net

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.twelve.daylight.ink.ink.Transport
import com.twelve.daylight.ink.prefs.Prefs
import com.twelve.daylight.ink.protocol.Encoder
import com.twelve.daylight.ink.protocol.SolStream
import com.twelve.daylight.ink.protocol.StateReport
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.TimeUnit

/**
 * The one WebSocket to the Mac, shared by the canvas activity (role `ink`) and the overlay service (role `overlay`)
 * with the same clientId (PROTOCOL 7). OkHttp 5.5.0 with [NoDelaySocketFactory], `pingInterval(10 s)`, the
 * `solstream.v1` subprotocol offered, every callback hopped to the main thread. The rules live in [Link].
 */
class InkConnection private constructor(context: Context) : LinkActions, Transport {
    companion object {
        const val TAG = "DaylightInk.net"
        const val APP_PING_MS = 10_000L
        const val CONNECT_TIMEOUT_S = 3L

        @Volatile private var instance: InkConnection? = null

        fun get(context: Context): InkConnection {
            instance?.let { return it }
            synchronized(this) {
                instance?.let { return it }
                return InkConnection(context.applicationContext).also { instance = it }
            }
        }
    }

    interface Listener {
        fun onPhase(phase: Phase)
        fun onState(state: StateReport)
    }

    private val app = context.applicationContext
    private val prefs = Prefs(app)
    private val main = Handler(Looper.getMainLooper())
    private val client: OkHttpClient = OkHttpClient.Builder()
        .socketFactory(NoDelaySocketFactory)
        .pingInterval(APP_PING_MS, TimeUnit.MILLISECONDS)
        .connectTimeout(CONNECT_TIMEOUT_S, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .retryOnConnectionFailure(false)
        .build()
    private val encoder = Encoder { System.currentTimeMillis() * 1000L }
    val candidates = Candidates()
    private val link = Link(this, encoder, candidates)
    private val discovery = Discovery(app)
    private val listeners = LinkedHashSet<Listener>()
    private val holders = LinkedHashMap<String, String>()     // tag -> role
    private var ws: WebSocket? = null
    private var dialRunnable: Runnable? = null
    private val pingRunnable = object : Runnable {
        override fun run() {
            link.ping()
            main.postDelayed(this, APP_PING_MS)
        }
    }

    val phase: Phase get() = link.phase
    val lastState: StateReport? get() = link.lastState
    val lastStateAtMs: Long get() = link.lastStateAtMs
    val lastRttMs: Long get() = link.lastRttMs
    val currentUrl: String? get() = link.currentUrl
    override val inkAllowed: Boolean get() = link.inkAllowed

    init {
        candidates.setManual(prefs.manualHost)
    }

    // ---- lifecycle ----

    /** A screen or service needs the Mac. The role is `ink` while any holder is the canvas, else `overlay`. */
    fun acquire(tag: String, role: String) {
        holders[tag] = role
        applyIdentity()
        if (holders.size == 1 || link.phase == Phase.SEARCHING && ws == null) {
            discovery.start({ name, host, port ->
                candidates.fromDiscovery(name, host, port)
                link.candidatesChanged()
            }, { name -> candidates.lost(name) })
            link.start()
            main.removeCallbacks(pingRunnable)
            main.postDelayed(pingRunnable, APP_PING_MS)
        }
    }

    fun release(tag: String) {
        holders.remove(tag)
        if (holders.isEmpty()) {
            main.removeCallbacks(pingRunnable)
            dialRunnable?.let { main.removeCallbacks(it) }
            dialRunnable = null
            link.stop()
            discovery.stop()
            ws = null
        } else {
            applyIdentity()
        }
    }

    private fun applyIdentity() {
        val role = if (holders.values.any { it == Identity.ROLE_INK }) Identity.ROLE_INK else Identity.ROLE_OVERLAY
        link.configure(role, prefs.clientId, prefs.deviceName)
    }

    fun addListener(l: Listener) {
        listeners.add(l)
        l.onPhase(link.phase)
        link.lastState?.let { l.onState(it) }
    }

    fun removeListener(l: Listener) { listeners.remove(l) }

    /** A host typed in Settings or onboarding, or handed over by `am start --es host`. */
    fun setManualHost(hostSpec: String?, remember: Boolean) {
        if (remember) prefs.manualHost = hostSpec
        candidates.setManual(prefs.manualHost)
        if (!remember) candidates.setIntentHost(hostSpec)
        link.candidatesChanged()
    }

    fun setIntentHost(hostSpec: String?) {
        candidates.setIntentHost(hostSpec)
        link.candidatesChanged()
    }

    /** The owner tapped the chip while denied or incompatible. */
    fun userRetry() = link.userRetry()

    // ---- control messages (chip, pills, toolbar) ----

    fun togglePin(value: Int = -1) { send(encoder.togglePin(value)) }
    fun clearCanvas() { send(encoder.clear(null)) }
    fun returnNow() { send(encoder.returnNow()) }

    // ---- Transport (StrokeSession) ----

    override fun send(frame: ByteArray): Boolean {
        val socket = ws ?: return false
        val ok = socket.send(frame.toByteString(0, frame.size))
        if (!ok) {
            Log.w(TAG, "send returned false (queue ${socket.queueSize()} bytes); reconnecting")
            link.sendFailed()
        }
        return ok
    }

    override fun queueBytes(): Long = ws?.queueSize() ?: 0L

    // ---- LinkActions ----

    override fun dial(url: String, afterMs: Long) {
        dialRunnable?.let { main.removeCallbacks(it) }
        val r = Runnable { dialRunnable = null; open(url) }
        dialRunnable = r
        main.postDelayed(r, afterMs)
    }

    override fun close(code: Int, reason: String) {
        val socket = ws ?: return
        ws = null
        runCatching { socket.close(code, reason) }
    }

    override fun phaseChanged(phase: Phase) {
        Log.i(TAG, "phase $phase url=${link.currentUrl}")
        for (l in listeners.toList()) l.onPhase(phase)
    }

    override fun stateChanged(state: StateReport) {
        for (l in listeners.toList()) l.onState(state)
    }

    override fun pong(sequence: Long, rttMs: Long) {
        Log.d(TAG, "pong $sequence rtt=${rttMs}ms")
    }

    private fun open(url: String) {
        if (holders.isEmpty()) return
        close(1000, "redial")
        link.dialing(url)
        Log.i(TAG, "dial $url")
        val request = Request.Builder()
            .url(url)
            .header("Sec-WebSocket-Protocol", SolStream.SUBPROTOCOL)
            .build()
        var created: WebSocket? = null
        val listener = object : WebSocketListener() {
            private fun mine(socket: WebSocket) = socket === ws
            override fun onOpen(webSocket: WebSocket, response: Response) {
                val echoed = response.header("Sec-WebSocket-Protocol")
                main.post { if (mine(webSocket)) link.opened(echoed) }
            }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                val copy = bytes.toByteArray()
                main.post { if (mine(webSocket)) link.received(copy) }
            }
            override fun onMessage(webSocket: WebSocket, text: String) {
                Log.d(TAG, "text frame ignored (${text.length} chars)")
            }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                runCatching { webSocket.close(1000, null) }
            }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                main.post {
                    if (mine(webSocket)) { ws = null; Log.i(TAG, "closed $code $reason"); link.closed(failure = false) }
                }
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                main.post {
                    if (mine(webSocket) || (ws == null && webSocket === created)) {
                        ws = null
                        Log.i(TAG, "failure ${t.javaClass.simpleName}: ${t.message} (http ${response?.code})")
                        link.closed(failure = true)
                    }
                }
            }
        }
        created = client.newWebSocket(request, listener)
        ws = created
    }
}
