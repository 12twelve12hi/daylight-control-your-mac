package com.twelve.daylight.ink.mirror

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.display.DisplayManager
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import com.twelve.daylight.ink.prefs.Prefs
import com.twelve.daylight.ink.protocol.MirrorControl
import com.twelve.daylight.ink.protocol.MirrorFraming
import com.twelve.daylight.ink.ui.Texts
import java.nio.ByteBuffer

/** What the mirror stream needs from the shared WebSocket (InkConnection implements it). */
interface MirrorUplink {
    /** Any thread; false when there is no allowed socket or the frame was refused. */
    fun sendMirror(frame: ByteArray): Boolean
    /** Any thread; OkHttp `queueSize()` of the allowed socket. */
    fun mirrorQueueBytes(): Long
    /** Main thread; keeps the socket open while the screen service runs. */
    fun acquireForMirror(tag: String)
    fun releaseForMirror(tag: String)
}

/**
 * The Android side of the Wi-Fi mirror transport (PROTOCOL 14, LOOSE_ENDS A9), one per process, main thread. It
 * performs the [MirrorEffect]s of the pure [MirrorSession]: the consent activity or notification, the foreground
 * service and its MediaProjection, the [ScreenEncoder] on its drain thread, MIRROR_STATUS, and the thermal and battery
 * saver inputs.
 *
 * Order (developer.android.com media projection guide and MediaProjectionManager reference): consent first
 * (`createScreenCaptureIntent` in [ConsentActivity]), then the service calls `startForeground` with
 * FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION, then [projectionGranted] calls `getMediaProjection`, registers the
 * MediaProjection.Callback, and only then can [ScreenEncoder] call `createVirtualDisplay` (once per projection).
 */
class MirrorController(context: Context, private val uplink: MirrorUplink) {
    companion object {
        const val TAG = "DaylightInk.mirror"
        const val HOLDER = "screen"
        const val CHANNEL_STREAM = "mirror"
        const val CHANNEL_REQUEST = "mirror-request"
        const val NOTIFICATION_REQUEST = 3
        const val TICK_MS = 250L
    }

    interface Listener {
        fun onMirrorState(state: MirrorState)
    }

    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val prefs = Prefs(app)
    private val encoders = ScreenEncoder.avcEncoders()
    val session = MirrorSession(capable = encoders.isNotEmpty()) { SystemClock.uptimeMillis() }
    private val framing = MirrorFraming { System.currentTimeMillis() * 1000L }
    private val stats = MirrorStats()
    private val backpressure = MirrorBackpressure()
    private var encoder: ScreenEncoder? = null
    private var projection: MediaProjection? = null
    private var startedDisplay: ScreenEncoder.Display? = null
    private var pendingResultCode = 0
    private var pendingResultData: Intent? = null
    private var serviceRunning = false
    private val listeners = LinkedHashSet<Listener>()
    private var statusCount = 0L
    private var maxThermal = -1

    val state: MirrorState get() = session.state

    fun addListener(l: Listener) { listeners.add(l); l.onMirrorState(session.state) }
    fun removeListener(l: Listener) { listeners.remove(l) }

    // ---- inputs from the connection (main thread) ----

    fun connectionAllowed() = apply(session.connectionAllowed())

    fun connectionLost() = apply(session.connectionLost())

    fun control(c: MirrorControl) {
        Log.i(TAG, "control ${c.command} max=${c.maxSize} bps=${c.bitrateBps} fps=${c.maxFps} key=${c.keyIntervalMs}")
        apply(session.control(c))
    }

    private var tickerOn = false
    private val ticker = object : Runnable {
        override fun run() {
            tickerOn = false
            apply(session.tick())          // reschedules itself through updateTicker while the 1 Hz report is due
        }
    }

    /** The 1 Hz report needs a clock only while STREAMING or PAUSED on an allowed connection: no idle wakeups. */
    private fun updateTicker() {
        val wanted = session.connected && (session.state == MirrorState.STREAMING || session.state == MirrorState.PAUSED)
        if (wanted && !tickerOn) {
            tickerOn = true
            main.postDelayed(ticker, TICK_MS)
        } else if (!wanted && tickerOn) {
            tickerOn = false
            main.removeCallbacks(ticker)
        }
    }

    // ---- inputs from the owner (main thread) ----

    /** "Share screen with your Mac" in the app. */
    fun shareRequested() = apply(session.shareRequested())

    /** "Stop sharing" in the app or the notification's Stop. */
    fun userStop() = apply(session.userStopped())

    private var visibleScreens = 0

    /** An activity of this app started (consent can open directly while any is on screen; else a notification asks). */
    fun uiStarted() {
        visibleScreens++
        session.setUiVisible(true)
    }

    fun uiStopped() {
        visibleScreens = (visibleScreens - 1).coerceAtLeast(0)
        session.setUiVisible(visibleScreens > 0)
    }

    /** [ConsentActivity] result. Granted: the foreground service starts and calls [projectionGranted]. */
    fun consentResult(activity: Context, resultCode: Int, data: Intent?) {
        if (resultCode == android.app.Activity.RESULT_OK && data != null) {
            if (!session.grantUsable(projection != null)) {
                // A second dialog's grant (double tap): one projection at a time, the held one stays.
                Log.i(TAG, "consent granted again while a projection is held; ignored")
                return
            }
            pendingResultCode = resultCode
            pendingResultData = data
            // From the visible consent activity: a foreground service start is allowed here (and on Android 14 the
            // mediaProjection type needs this consent first).
            val r = runCatching { activity.startForegroundService(Intent(activity, ScreenStreamService::class.java).setAction(ScreenStreamService.ACTION_GRANTED)) }
            r.onFailure {
                Log.w(TAG, "screen service did not start: $it")
                pendingResultData = null
                apply(session.consentDenied())
            }
        } else {
            Log.i(TAG, "consent denied (result $resultCode)")
            apply(session.consentDenied())
        }
    }

    /**
     * Called by [ScreenStreamService] right after its `startForeground(..., FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)`.
     * Returns false when no projection could be obtained (the service then stops).
     */
    fun projectionGranted(): Boolean {
        val data = pendingResultData ?: return projection != null
        pendingResultData = null
        if (!session.grantUsable(projection != null)) {
            // A new projection would make the system stop the held one (AOSP startProjectionLocked): keep the held one.
            Log.i(TAG, "a projection is held already; the newer consent is not used")
            return projection != null
        }
        serviceRunning = true
        uplink.acquireForMirror(HOLDER)
        val mpm = app.getSystemService(MediaProjectionManager::class.java)
        // Android 14: the consent Intent may be used for getMediaProjection only once; it is dropped above.
        val p = runCatching { mpm.getMediaProjection(pendingResultCode, data) }
            .onFailure { Log.w(TAG, "getMediaProjection failed: $it") }.getOrNull()
        if (p == null) {
            apply(session.consentDenied())
            return false
        }
        // Registered BEFORE createVirtualDisplay (MediaProjection reference: required for apps targeting 34).
        p.registerCallback(projectionCallback, main)
        projection = p
        registerDisplayListener()
        apply(session.consentGranted())
        return true
    }

    /** The service is being destroyed (stopped by us, or by the system): nothing may keep capturing. */
    fun serviceGone() {
        serviceRunning = false
        if (session.projectionHeld) apply(session.userStopped())
        uplink.releaseForMirror(HOLDER)
    }

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            Log.i(TAG, "projection stopped by the system")
            apply(session.projectionStopped())
        }

        // API 34 (never called on Android 13): the captured content changed size (rotation).
        override fun onCapturedContentResize(width: Int, height: Int) {
            Log.i(TAG, "captured content resized to ${width}x$height")
            checkDisplaySize()
        }
    }

    // ---- effects ----

    private fun apply(effects: List<MirrorEffect>) {
        val before = lastNotifiedState
        for (e in effects) perform(e)
        if (session.state != before) {
            lastNotifiedState = session.state
            Log.i(TAG, "state ${session.state} flags=${session.flags}")
            for (l in listeners.toList()) l.onMirrorState(session.state)
        }
        updateTicker()
    }

    private var lastNotifiedState: MirrorState = session.state

    private fun perform(e: MirrorEffect) {
        when (e) {
            MirrorEffect.RequestConsent -> {
                val ok = runCatching {
                    app.startActivity(Intent(app, ConsentActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }.isSuccess
                if (!ok) showConsentNotification()
            }
            MirrorEffect.ShowConsentNotification -> {
                showConsentNotification()
                // developer.android.com background activity starts: an app the owner granted SYSTEM_ALERT_WINDOW (the
                // pills) may start an activity from the background, so the system dialog can appear at once.
                if (Settings.canDrawOverlays(app)) {
                    runCatching {
                        app.startActivity(Intent(app, ConsentActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }.onFailure { Log.i(TAG, "direct consent launch refused, the notification stays: $it") }
                }
            }
            MirrorEffect.CancelConsentNotification -> runCatching { notifications().cancel(NOTIFICATION_REQUEST) }
            is MirrorEffect.StartEncoder -> startEncoder(e.params)
            MirrorEffect.StopEncoder -> {
                encoder?.stop()
                startedDisplay = null
            }
            MirrorEffect.ReleaseProjection -> releaseProjection()
            MirrorEffect.RequestSyncFrame -> encoder?.requestSyncFrame()
            MirrorEffect.SendStatus -> sendStatus()
        }
    }

    private fun startEncoder(params: EncoderParams) {
        val p = projection
        if (p == null) {
            Log.w(TAG, "start without a projection")
            apply(session.encoderFailed())
            return
        }
        val display = readDisplay()
        startedDisplay = display
        stats.reset()
        backpressure.reset()
        val enc = encoder ?: ScreenEncoder(sink).also { encoder = it }
        enc.start(p, params, display)
    }

    private fun releaseProjection() {
        encoder?.releaseDisplay()
        startedDisplay = null
        unregisterDisplayListener()
        val p = projection
        projection = null
        if (p != null) {
            runCatching { p.unregisterCallback(projectionCallback) }
            runCatching { p.stop() }
        }
        if (serviceRunning) {
            runCatching { app.stopService(Intent(app, ScreenStreamService::class.java)) }
        }
    }

    private fun sendStatus() {
        val now = SystemClock.uptimeMillis()
        val fields = session.report(stats.fpsX10(now), stats.sentBps(now), backpressure.takeReportFlag())
        uplink.sendMirror(framing.status(fields))
        statusCount++
        // One line every 10 s while streaming: the measured fps and bit rate the owner copies (handoff facts).
        if (session.state != MirrorState.STREAMING || statusCount % 10 == 0L) {
            Log.i(TAG, "status state=${fields.state} flags=${fields.flags} fps=${fields.fpsX10 / 10.0} ${fields.width}x${fields.height} sent=${fields.sentBps} bps dropped=${backpressure.dropped}")
        }
        if (session.state == MirrorState.STREAMING && fields.fpsX10 > 0 && statusCount % 10 == 0L) {
            prefs.factMirrorStream = "${fields.width}x${fields.height} fps=${fields.fpsX10 / 10.0} sent=${fields.sentBps / 1000} kbps"
        }
    }

    // ---- the drain thread ----

    private val sink = object : ScreenEncoder.Sink {
        override fun streamStarted(encoderName: String, width: Int, height: Int) {
            for (f in listOf(framing.hello(Build.MODEL ?: "Daylight"), framing.session(width, height))) {
                if (uplink.sendMirror(f)) stats.record(SystemClock.uptimeMillis(), f.size.toLong(), accessUnit = false)
            }
            prefs.factMirrorEncoder = "$encoderName ${width}x$height"
            main.post { apply(session.encoderStarted(width, height)) }
        }

        override fun output(config: Boolean, keyFrame: Boolean, ptsUs: Long, data: ByteBuffer) {
            val n = data.remaining()
            if (n > MirrorFraming.MAX_ANNEX_B_BYTES) {
                Log.w(TAG, "access unit of $n bytes exceeds the 1 MiB payload cap; dropped, sync frame requested")
                backpressure.markGap()          // the deltas that follow reference it: dropped until a key frame
                encoder?.requestSyncFrameNow()
                return
            }
            val queued = uplink.mirrorQueueBytes()
            if (backpressure.syncFrameWanted(queued)) encoder?.requestSyncFrameNow()
            if (!backpressure.admit(queued, keyFrame || config)) return
            val frame = framing.packet(config, keyFrame, ptsUs, data)
            if (uplink.sendMirror(frame)) stats.record(SystemClock.uptimeMillis(), frame.size.toLong(), accessUnit = !config)
        }

        override fun failed(reason: String) {
            Log.w(TAG, "encoder failed: $reason")
            main.post { apply(session.encoderFailed()) }
        }
    }

    // ---- display size (rotation) ----

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {}
        override fun onDisplayChanged(displayId: Int) {
            if (displayId == Display.DEFAULT_DISPLAY) checkDisplaySize()
        }
    }
    private var displayListenerOn = false

    private fun registerDisplayListener() {
        if (displayListenerOn) return
        runCatching { app.getSystemService(DisplayManager::class.java).registerDisplayListener(displayListener, main) }
            .onSuccess { displayListenerOn = true }
    }

    private fun unregisterDisplayListener() {
        if (!displayListenerOn) return
        displayListenerOn = false
        runCatching { app.getSystemService(DisplayManager::class.java).unregisterDisplayListener(displayListener) }
    }

    private fun checkDisplaySize() {
        val started = startedDisplay ?: return
        val now = readDisplay()
        if (now.width != started.width || now.height != started.height) {
            Log.i(TAG, "display ${started.width}x${started.height} -> ${now.width}x${now.height}: encoder restarts")
            apply(session.displaySizeChanged())
        }
    }

    /** Real size of the default display in its current rotation. */
    @Suppress("DEPRECATION")
    private fun readDisplay(): ScreenEncoder.Display {
        val dm = DisplayMetrics()
        val ok = runCatching {
            app.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY).getRealMetrics(dm)
        }.isSuccess
        val m = if (ok && dm.widthPixels > 0 && dm.heightPixels > 0) dm else app.resources.displayMetrics
        return ScreenEncoder.Display(m.widthPixels, m.heightPixels, m.densityDpi.coerceAtLeast(1))
    }

    // ---- thermal and battery saver ----

    private fun watchThermalAndPower() {
        val pm = app.getSystemService(PowerManager::class.java) ?: return
        runCatching {
            pm.addThermalStatusListener(app.mainExecutor) { status -> thermal(status) }
            thermal(pm.currentThermalStatus)
        }.onFailure { Log.w(TAG, "thermal status unavailable: $it") }
        runCatching {
            app.registerReceiver(object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    val on = pm.isPowerSaveMode
                    Log.i(TAG, "battery saver ${if (on) "on" else "off"}")
                    apply(session.powerSaveChanged(on))
                }
            }, IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED))
            if (pm.isPowerSaveMode) {
                Log.i(TAG, "battery saver on")
                apply(session.powerSaveChanged(true))
            }
        }.onFailure { Log.w(TAG, "battery saver state unavailable: $it") }
    }

    private fun thermal(status: Int) {
        Log.i(TAG, "thermal status $status")
        if (status > maxThermal) {
            maxThermal = status
            prefs.factMirrorThermalMax = status.toString()
        }
        apply(session.thermalStatusChanged(status))
    }

    // ---- notifications ----

    private fun notifications(): NotificationManager = app.getSystemService(NotificationManager::class.java)

    private fun showConsentNotification() {
        runCatching {
            val nm = notifications()
            nm.createNotificationChannel(NotificationChannel(CHANNEL_REQUEST, Texts.MIRROR_REQUEST_CHANNEL, NotificationManager.IMPORTANCE_HIGH))
            val open = PendingIntent.getActivity(
                app, 0, Intent(app, ConsentActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val n = Notification.Builder(app, CHANNEL_REQUEST)
                .setSmallIcon(MirrorIcons.icon())
                .setContentTitle(Texts.MIRROR_REQUEST_TITLE)
                .setContentText(Texts.MIRROR_REQUEST_BODY)
                .setContentIntent(open)
                .setAutoCancel(true)
                .build()
            nm.notify(NOTIFICATION_REQUEST, n)
        }.onFailure { Log.w(TAG, "consent notification failed: $it") }
    }

    // Last on purpose: every property above is initialised before the first apply() runs.
    init {
        Log.i(TAG, "H.264 encoders: ${if (encoders.isEmpty()) "none (mirror UNSUPPORTED)" else encoders.joinToString()}")
        prefs.factMirrorEncoders = if (encoders.isEmpty()) "none" else encoders.joinToString()
        watchThermalAndPower()
    }
}
