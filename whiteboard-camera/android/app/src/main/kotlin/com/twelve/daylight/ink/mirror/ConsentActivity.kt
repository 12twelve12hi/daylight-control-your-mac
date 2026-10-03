package com.twelve.daylight.ink.mirror

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import com.twelve.daylight.ink.net.InkConnection

/**
 * Translucent, no UI of its own: it shows the system screen capture dialog (`createScreenCaptureIntent`) and hands
 * the result to [MirrorController], which starts [ScreenStreamService]. Opened by "Share screen with your Mac", by a
 * Mac START while the app is on screen, or by tapping the "Your Mac wants to mirror this screen" notification (a
 * notification PendingIntent is the documented way around the background activity start restriction).
 */
class ConsentActivity : Activity() {
    companion object {
        const val TAG = "DaylightInk.mirror"
        const val REQUEST_CAPTURE = 71
    }

    private var asked = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        asked = savedInstanceState?.getBoolean("asked") ?: false
        if (asked) return
        if (InkConnection.get(this).mirror.session.projectionHeld) {
            // An old "wants to mirror" notification tapped while sharing already: one projection at a time.
            finish()
            return
        }
        val mpm = getSystemService(MediaProjectionManager::class.java)
        val intent = if (Build.VERSION.SDK_INT >= 34) {
            // Android 14 offers "a single app" by default; the Mac needs the whole display.
            runCatching { mpm.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay()) }
                .getOrElse { mpm.createScreenCaptureIntent() }
        } else {
            mpm.createScreenCaptureIntent()
        }
        val started = runCatching { startActivityForResult(intent, REQUEST_CAPTURE) }
        started.onFailure {
            Log.w(TAG, "screen capture dialog unavailable: $it")
            InkConnection.get(this).mirror.consentResult(this, RESULT_CANCELED, null)
            finish()
            return
        }
        asked = true
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean("asked", asked)
    }

    @Deprecated("Platform Activity result callback; this app has no AndroidX")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CAPTURE) {
            InkConnection.get(this).mirror.consentResult(this, resultCode, data)
            finish()
        }
    }
}
