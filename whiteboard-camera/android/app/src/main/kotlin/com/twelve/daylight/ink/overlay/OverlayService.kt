package com.twelve.daylight.ink.overlay

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.drawable.Icon
import android.hardware.display.DisplayManager
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import android.view.Display
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Toast
import com.twelve.daylight.ink.net.Identity
import com.twelve.daylight.ink.net.InkConnection
import com.twelve.daylight.ink.net.Phase
import com.twelve.daylight.ink.prefs.Prefs
import com.twelve.daylight.ink.protocol.StateReport
import com.twelve.daylight.ink.ui.MainActivity
import com.twelve.daylight.ink.ui.Texts
import com.twelve.daylight.ink.ui.Tokens

/**
 * The floating Pin and Clear pills for mirror mode (SPEC D9, E5; research-android-ink 4 and 10.2): a foreground
 * service of type connectedDevice holding ONE WRAP_CONTENT TYPE_APPLICATION_OVERLAY window with
 * FLAG_NOT_FOCUSABLE or FLAG_KEEP_SCREEN_ON, top centre inside the 96 px strip the Mac crops away (or bottom per
 * `--es pills bottom`). It speaks to the Mac through the shared InkConnection with role `overlay` and the canvas's
 * clientId, so it is auto-allowed once the canvas was allowed.
 *
 * Started by: the Settings screen, the boot receiver (opt-in), or the Mac over USB with
 * `adb shell am start-foreground-service -n com.twelve.daylight.ink/.OverlayService --es pills top`.
 */
class OverlayService : Service(), InkConnection.Listener {
    companion object {
        const val TAG = "DaylightInk.overlay"
        const val CHANNEL = "pills"
        const val NOTIFICATION_ID = 1
        const val EXTRA_PILLS = "pills"
        const val EXTRA_HOST = "host"
        const val ACTION_STOP = "com.twelve.daylight.ink.STOP_PILLS"
        const val HOLDER = "overlay"
    }

    private var windowContext: Context? = null
    private var pills: PillsView? = null
    private var position: PillsLayout.Position = PillsLayout.Position.TOP
    private lateinit var conn: InkConnection

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        conn = InkConnection.get(this)
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Daylight Ink pills", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(this, CHANNEL)
            .setSmallIcon(Icon.createWithBitmap(iconBitmap()))
            .setContentTitle("Daylight Ink pills are on")
            .setContentText("Pin and Clear float over your notes. Hide them from Daylight Ink settings.")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        // The manifest declares foregroundServiceType="connectedDevice"; the type passed must be a subset of it.
        startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (!Settings.canDrawOverlays(this)) {
            // SPEC 13.3 row 29: the pills cannot show; the onboarding screen explains the permission.
            Log.w(TAG, "SYSTEM_ALERT_WINDOW not granted; pills invisible")
            Toast.makeText(this, Texts.PILLS_NEED_PERMISSION, Toast.LENGTH_LONG).show()
            stopSelf()
            return START_NOT_STICKY
        }
        val prefs = Prefs(this)
        intent?.getStringExtra(EXTRA_PILLS)?.let { prefs.pillsPosition = it }
        intent?.getStringExtra(EXTRA_HOST)?.let { conn.setManualHost(it, remember = true) }
        val wanted = PillsLayout.positionFrom(prefs.pillsPosition)
        if (pills == null || wanted != position) {
            removeWindow()
            position = wanted
            addWindow(PillsLayout.placement(wanted))
        }
        conn.acquire(HOLDER, Identity.ROLE_OVERLAY)
        conn.addListener(this)
        return START_STICKY
    }

    private fun addWindow(placement: PillsLayout.Placement) {
        val display = getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
        val wc = createDisplayContext(display).createWindowContext(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, null)
        windowContext = wc
        val view = PillsView(wc, placement, { conn.togglePin(-1) }, { conn.clearCanvas() })
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = (if (placement.position == PillsLayout.Position.BOTTOM) Gravity.BOTTOM else Gravity.TOP) or Gravity.CENTER_HORIZONTAL
            y = placement.y
            // The row must sit inside the 96 px strip the Mac crops away: without this the window manager would push a
            // TOP window below the status bar (API 30 fit-insets default) and the pills would show in the camera picture.
            if (placement.position == PillsLayout.Position.TOP) setFitInsetsTypes(0)
        }
        try {
            wc.getSystemService(WindowManager::class.java).addView(view, lp)
            pills = view
            view.bind(PillsState.view(conn.phase, conn.lastState))
            Log.i(TAG, "pills window added: ${placement.position} y=${placement.y} row=${placement.rowHeight}px")
            view.post {
                // LOOSE_ENDS D5: the screen position the owner compares with the mirror crop.
                val xy = IntArray(2)
                view.getLocationOnScreen(xy)
                Log.i(TAG, "pills frame x=${xy[0]} y=${xy[1]} h=${view.height}")
            }
        } catch (e: RuntimeException) {
            Log.w(TAG, "addView failed: $e")
            stopSelf()
        }
    }

    private fun removeWindow() {
        val v: View? = pills
        pills = null
        if (v != null) runCatching { windowContext?.getSystemService(WindowManager::class.java)?.removeView(v) }
        windowContext = null
    }

    override fun onDestroy() {
        conn.removeListener(this)
        conn.release(HOLDER)
        removeWindow()
        super.onDestroy()
    }

    override fun onPhase(phase: Phase) { pills?.bind(PillsState.view(phase, conn.lastState)) }
    override fun onState(state: StateReport) { pills?.bind(PillsState.view(conn.phase, state)) }

    /** A plain amber disc; no drawable resources so the JVM harness and the APK see the same sources. */
    private fun iconBitmap(): Bitmap {
        val size = 96
        val b = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val c = Canvas(b)
        val p = Paint().apply { isAntiAlias = true; color = Tokens.AMBER }
        c.drawCircle(size / 2f, size / 2f, size / 2f - 6f, p)
        p.color = Tokens.PAPER_BG
        c.drawCircle(size / 2f, size / 2f, size / 6f, p)
        return b
    }
}
