package com.twelve.daylight.ink

import android.graphics.Bitmap
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.io.FileOutputStream

/**
 * PNG screenshots for the CI artifact: `<NN>-<name>.png` in the app's external files dir `screenshots`
 * (`/sdcard/Android/data/com.twelve.daylight.ink/files/screenshots`), which the CI script pulls after the run.
 * A failed capture is logged, never a test failure: the assertions are the proof, the pictures are for people.
 */
object Screenshots {
    const val TAG = "DaylightInk.test"

    fun dir(): File? = TestEnv.context.getExternalFilesDir("screenshots")?.also { it.mkdirs() }

    fun take(name: String): File? {
        TestEnv.instrumentation.waitForIdleSync()
        TestEnv.device.waitForIdle()
        SystemClock.sleep(400)          // let the compositor show the last frame
        val target = dir()?.let { File(it, "$name.png") } ?: run {
            Log.w(TAG, "no external files dir; screenshot $name skipped")
            return null
        }
        val bmp: Bitmap = TestEnv.instrumentation.uiAutomation.takeScreenshot() ?: run {
            Log.w(TAG, "takeScreenshot returned null for $name")
            return null
        }
        return try {
            FileOutputStream(target).use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
            Log.i(TAG, "screenshot ${target.absolutePath} ${bmp.width}x${bmp.height}")
            target
        } catch (e: Exception) {
            Log.w(TAG, "screenshot $name failed: $e")
            null
        } finally {
            bmp.recycle()
        }
    }
}
