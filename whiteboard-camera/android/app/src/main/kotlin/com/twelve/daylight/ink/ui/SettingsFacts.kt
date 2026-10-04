package com.twelve.daylight.ink.ui

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import com.twelve.daylight.ink.Facts
import com.twelve.daylight.ink.net.Candidates
import com.twelve.daylight.ink.net.InkConnection
import com.twelve.daylight.ink.net.Phase
import com.twelve.daylight.ink.prefs.Prefs
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.concurrent.TimeUnit

/**
 * Settings > "This tablet" > "Send facts to Mac" (PROTOCOL 15): one `POST /api/facts` to the Mac this tablet is
 * connected to (or last reached), carrying the values `Facts.lines` shows. The JSON, the URL and the result text are
 * pure functions so the JVM tests can pin them; only [send] and [collect] touch Android.
 */
object SettingsFacts {
    const val TAG = "DaylightInk.facts"
    const val SCHEMA = "daylight-tablet-facts/1"
    const val SOURCE = "ink"
    const val PATH = "/api/facts"
    const val MAX_VALUE_CHARS = 1024
    const val MAX_CLIENT_ID_CHARS = 64
    const val CALL_TIMEOUT_S = 5L

    const val BUTTON = "Send facts to Mac"
    const val TEXT_NO_HOST = "Connect to your Mac first."
    const val TEXT_SENDING = "Sending to your Mac."
    const val TEXT_SENT = "Sent to your Mac."
    const val TEXT_UNREACHABLE = "Could not reach your Mac. Check the connection and tap again."
    fun textNotAccepted(code: Int) = "Your Mac did not accept the facts ($code). Update Daylight on your Mac."
    fun textRefused(code: Int) = "Your Mac refused the facts ($code)."

    /** PROTOCOL 15.1, the Daylight Ink `facts` keys, in the order they are sent. */
    val INK_KEYS = listOf(
        "model", "manufacturer", "device", "release", "sdk", "tiramisuExt", "display", "density", "densityDpi",
        "canDrawOverlays", "pressureRange", "sideButton", "frontBuffer", "mirrorEncoders", "mirrorEncoder",
        "mirrorStream", "mirrorThermalMax", "versionName", "versionCode",
    )

    /** Everything the body needs, read once on the main thread; null means "not known yet" and is sent as JSON null. */
    data class Inputs(
        val model: String?,
        val manufacturer: String?,
        val device: String?,
        val release: String?,
        val sdk: Int?,
        val tiramisuExt: Int?,
        val displayWidth: Int?,
        val displayHeight: Int?,
        val density: Float?,
        val densityDpi: Int?,
        val canDrawOverlays: Boolean?,
        val pressureRange: String?,
        val sideButton: String?,
        val frontBuffer: String?,
        val mirrorEncoders: String?,
        val mirrorEncoder: String?,
        val mirrorStream: String?,
        val mirrorThermalMax: String?,
        val versionName: String?,
        val versionCode: Long?,
    )

    // ---- pure ----

    fun facts(i: Inputs): LinkedHashMap<String, Any?> = linkedMapOf(
        "model" to i.model,
        "manufacturer" to i.manufacturer,
        "device" to i.device,
        "release" to i.release,
        "sdk" to i.sdk,
        "tiramisuExt" to i.tiramisuExt,
        "display" to (if (i.displayWidth != null && i.displayHeight != null) "${i.displayWidth}x${i.displayHeight}" else null),
        "density" to i.density,
        "densityDpi" to i.densityDpi,
        "canDrawOverlays" to i.canDrawOverlays,
        "pressureRange" to i.pressureRange,
        "sideButton" to i.sideButton,
        "frontBuffer" to i.frontBuffer,
        "mirrorEncoders" to i.mirrorEncoders,
        "mirrorEncoder" to i.mirrorEncoder,
        "mirrorStream" to i.mirrorStream,
        "mirrorThermalMax" to i.mirrorThermalMax,
        "versionName" to i.versionName,
        "versionCode" to i.versionCode,
    )

    /** The request body of PROTOCOL 15.1; `clientId` is left out when unknown (it is optional there). */
    fun json(clientId: String?, sentAtMs: Long, inputs: Inputs): String {
        val sb = StringBuilder(1024)
        sb.append("{\"schema\":").append(quote(SCHEMA))
        sb.append(",\"source\":").append(quote(SOURCE))
        clientId?.takeIf { it.isNotBlank() }?.let { sb.append(",\"clientId\":").append(quote(cap(it, MAX_CLIENT_ID_CHARS))) }
        sb.append(",\"sentAt\":").append(quote(isoUtc(sentAtMs)))
        sb.append(",\"facts\":{")
        var first = true
        for ((k, v) in facts(inputs)) {
            if (!first) sb.append(',')
            first = false
            sb.append(quote(k)).append(':').append(value(v))
        }
        return sb.append("}}").toString()
    }

    /** ISO 8601 UTC to the second, `2026-10-03T14:05:09Z`. */
    fun isoUtc(ms: Long): String = Instant.ofEpochMilli(ms).truncatedTo(ChronoUnit.SECONDS).toString()

    fun value(v: Any?): String = when (v) {
        null -> "null"
        is Boolean -> v.toString()
        is Int, is Long -> v.toString()
        is Float -> if (v.isFinite()) v.toString() else "null"
        is Double -> if (v.isFinite()) v.toString() else "null"
        is String -> quote(cap(v, MAX_VALUE_CHARS))
        else -> quote(cap(v.toString(), MAX_VALUE_CHARS))
    }

    /** At most [max] chars, never ending on the first half of a surrogate pair. */
    fun cap(s: String, max: Int): String {
        if (s.length <= max) return s
        val end = if (Character.isHighSurrogate(s[max - 1])) max - 1 else max
        return s.substring(0, end)
    }

    /** A JSON string literal: quote and backslash escaped, every control character as \u00XX, the rest as is. */
    fun quote(s: String): String {
        val sb = StringBuilder(s.length + 2).append('"')
        for (c in s) {
            when {
                c == '"' -> sb.append("\\\"")
                c == '\\' -> sb.append("\\\\")
                c < ' ' || c == '\u007f' -> sb.append("\\u00").append(HEX[c.code shr 4]).append(HEX[c.code and 0xF])
                else -> sb.append(c)
            }
        }
        return sb.append('"').toString()
    }

    private const val HEX = "0123456789abcdef"

    /** `http://host:port/api/facts`; an IPv6 literal (bracketed or not) is bracketed. */
    fun factsUrl(host: String, port: Int): String {
        val h = host.trim().removePrefix("[").removeSuffix("]")
        return "http://${if (h.contains(':')) "[$h]" else h}:$port$PATH"
    }

    /** `ws://host:port/ink` (the form [Candidates.url] and `InkConnection.currentUrl` use) -> host and port. */
    fun hostPort(wsUrl: String?): Pair<String, Int>? {
        val s = wsUrl?.trim()?.substringAfter("://", "")?.substringBefore('/') ?: return null
        if (s.isEmpty()) return null
        val host: String
        val portText: String
        if (s.startsWith("[")) {
            val close = s.indexOf(']')
            if (close < 0) return null
            host = s.substring(1, close)
            portText = s.substring(close + 1).removePrefix(":")
        } else {
            host = s.substringBeforeLast(':', s)
            portText = if (s.contains(':')) s.substringAfterLast(':') else ""
        }
        val port = portText.toIntOrNull() ?: return null
        if (host.isEmpty() || port !in 1..65535) return null
        return host to port
    }

    /**
     * Where the facts go: the Mac of the open socket (PENDING or LIVE: the Mac answered, so its HTTP listener is
     * there), else the last Mac reached in this process, else the remembered manual host. Null: nothing known.
     */
    fun target(phase: Phase, currentUrl: String?, lastReachedUrl: String?, manualHost: String?): Pair<String, Int>? {
        if (phase == Phase.PENDING || phase == Phase.LIVE) hostPort(currentUrl)?.let { return it }
        hostPort(lastReachedUrl)?.let { return it }
        return hostPort(Candidates.url(manualHost))
    }

    /** The feedback line under the button: an HTTP status, or null when the call failed (IOException, timeout). */
    fun resultText(code: Int?): String = if (code == null) TEXT_UNREACHABLE else when (code) {
        200 -> TEXT_SENT
        404, 405 -> textNotAccepted(code)
        else -> textRefused(code)
    }

    /**
     * One POST at a time: while "Sending to your Mac." is shown, another tap is ignored, so a double tap cannot send
     * twice or let an older answer overwrite a newer one. Main thread only (the tap and the posted answer both run there).
     */
    class SendGate {
        var busy: Boolean = false
            private set

        /** True when a send may start (and marks it started); false while one is in flight. */
        fun tryBegin(): Boolean {
            if (busy) return false
            busy = true
            return true
        }

        fun end() { busy = false }
    }

    // ---- Android ----

    private val gate = SendGate()

    /** The last socket URL that was PENDING or LIVE when the button was tapped ("last connected to"). */
    @Volatile private var lastReachedUrl: String? = null
    private val main by lazy { Handler(Looper.getMainLooper()) }
    private val jsonType by lazy { "application/json; charset=utf-8".toMediaType() }
    private val http: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .callTimeout(CALL_TIMEOUT_S, TimeUnit.SECONDS)
            .retryOnConnectionFailure(false)
            .build()
    }

    /** Main thread. Reads the facts, posts them on OkHttp's thread and hands the feedback line to [show] on the main thread. */
    fun send(context: Context, conn: InkConnection, show: (String) -> Unit) {
        if (gate.busy) return                     // "Sending to your Mac." is on screen: this tap is ignored
        val prefs = Prefs(context)
        val phase = conn.phase
        if (phase == Phase.PENDING || phase == Phase.LIVE) conn.currentUrl?.let { lastReachedUrl = it }
        val to = target(phase, conn.currentUrl, lastReachedUrl, prefs.manualHost)
        if (to == null) { show(TEXT_NO_HOST); return }
        val url = factsUrl(to.first, to.second)
        val body = json(prefs.clientId, System.currentTimeMillis(), collect(context, prefs))
        val request = try {
            Request.Builder().url(url).post(body.toByteArray(Charsets.UTF_8).toRequestBody(jsonType)).build()
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "facts url refused: ${e.message}")
            show(TEXT_UNREACHABLE)
            return
        }
        if (!gate.tryBegin()) return
        show(TEXT_SENDING)
        http.newCall(request).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                Log.i(TAG, "facts post failed: ${e.javaClass.simpleName}")
                main.post { gate.end(); show(resultText(null)) }
            }

            override fun onResponse(call: Call, response: Response) {
                val code = response.code
                response.close()
                Log.i(TAG, "facts post answered $code")
                main.post { gate.end(); show(resultText(code)) }
            }
        })
    }

    /** The same sources `Facts.lines` reads; a Prefs fact that was never recorded stays null. */
    fun collect(context: Context, prefs: Prefs): Inputs {
        val dm = context.resources.displayMetrics
        val pkg = runCatching {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(context.packageName, 0)
        }.getOrNull()
        fun fact(v: String?) = v?.takeIf { it.isNotBlank() }
        return Inputs(
            model = Build.MODEL,
            manufacturer = Build.MANUFACTURER,
            device = Build.DEVICE,
            release = Build.VERSION.RELEASE,
            sdk = Build.VERSION.SDK_INT,
            tiramisuExt = Facts.tiramisuExtension(),
            displayWidth = dm.widthPixels,
            displayHeight = dm.heightPixels,
            density = dm.density,
            densityDpi = dm.densityDpi,
            canDrawOverlays = runCatching { Settings.canDrawOverlays(context) }.getOrNull(),
            pressureRange = fact(prefs.factPressureRaw),
            sideButton = fact(prefs.factActionButton),
            frontBuffer = fact(prefs.factFrontBufferOk),
            mirrorEncoders = fact(prefs.factMirrorEncoders),
            mirrorEncoder = fact(prefs.factMirrorEncoder),
            mirrorStream = fact(prefs.factMirrorStream),
            mirrorThermalMax = fact(prefs.factMirrorThermalMax),
            versionName = pkg?.versionName,
            versionCode = pkg?.longVersionCode,
        )
    }
}
