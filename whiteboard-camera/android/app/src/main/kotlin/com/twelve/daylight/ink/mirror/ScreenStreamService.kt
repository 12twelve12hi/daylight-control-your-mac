package com.twelve.daylight.ink.mirror

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.util.Log
import com.twelve.daylight.ink.net.InkConnection
import com.twelve.daylight.ink.ui.MainActivity
import com.twelve.daylight.ink.ui.Texts

/**
 * The foreground service that holds the MediaProjection while the screen is shared with the Mac (PROTOCOL 14). The
 * manifest declares `foregroundServiceType="mediaProjection"`; `startForeground` passes
 * FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION BEFORE [MirrorController.projectionGranted] calls `getMediaProjection`
 * (MediaProjectionManager reference: SecurityException otherwise on Android 14). Started only by [ConsentActivity]
 * after the owner allowed the capture; never from the background or at boot. Its persistent notification reads
 * "Sharing screen with your Mac" with a Stop action.
 */
class ScreenStreamService : Service() {
    companion object {
        const val TAG = "DaylightInk.mirror"
        const val NOTIFICATION_ID = 2
        const val ACTION_GRANTED = "com.twelve.daylight.ink.MIRROR_GRANTED"
        const val ACTION_STOP = "com.twelve.daylight.ink.MIRROR_STOP"
    }

    private var foreground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val mirror = InkConnection.get(this).mirror
        when (intent?.action) {
            ACTION_STOP -> {
                Log.i(TAG, "Stop from the notification")
                mirror.userStop()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_GRANTED -> {
                // 1. foreground with the mediaProjection type, 2. getMediaProjection, 3. callback, 4. virtual display.
                if (!foreground) {
                    startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
                    foreground = true
                }
                if (!mirror.projectionGranted()) stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                // A start without a consent result has nothing to capture with. When it came through
                // startForegroundService, stopping before startForeground crashes the app on Android 9 and later
                // ("did not then call Service.startForeground"), so go foreground first; from the background that
                // call is refused (Android 12 rule) and the plain stop is the right answer anyway.
                if (!foreground) {
                    runCatching { startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION) }
                        .onFailure { Log.i(TAG, "start without consent, not foreground: $it") }
                    stopSelf()
                }
                return START_NOT_STICKY
            }
        }
    }

    override fun onDestroy() {
        InkConnection.get(this).mirror.serviceGone()
        super.onDestroy()
    }

    private fun notification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(MirrorController.CHANNEL_STREAM, Texts.MIRROR_STREAM_CHANNEL, NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(
            this, 1, Intent(this, ScreenStreamService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val icon = MirrorIcons.icon()
        return Notification.Builder(this, MirrorController.CHANNEL_STREAM)
            .setSmallIcon(icon)
            .setContentTitle(Texts.MIRROR_NOTIFICATION_TITLE)
            .setContentText(Texts.MIRROR_NOTIFICATION_BODY)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(icon, Texts.MIRROR_NOTIFICATION_STOP, stop).build())
            .build()
    }
}
