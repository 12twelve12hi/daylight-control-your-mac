package com.twelve.daylight.ink

import android.app.Activity
import android.app.ActivityManager
import android.app.Instrumentation
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import com.twelve.daylight.ink.net.InkConnection
import com.twelve.daylight.ink.prefs.Prefs
import org.junit.Assert.assertTrue
import java.util.regex.Pattern

/**
 * Shared plumbing of the instrumented tests. The CI script runs them with `am instrument` in one process, in any
 * order, with no permission pre-granted, so every test starts from [resetApp]: no activity left over, the app's
 * SharedPreferences cleared, the process-wide connection pointed nowhere, overlay permission back to its default.
 */
object TestEnv {
    const val PKG = "com.twelve.daylight.ink"
    const val SETTINGS_PKG = "com.android.settings"
    const val SYSTEMUI_PKG = "com.android.systemui"
    const val WAIT_MS = 10_000L

    val instrumentation: Instrumentation get() = InstrumentationRegistry.getInstrumentation()

    /** The app's own context (instrumentation runs in the app process). */
    val context: Context get() = instrumentation.targetContext

    val device: UiDevice get() = UiDevice.getInstance(instrumentation)

    private val ALIVE_STAGES = listOf(
        Stage.PRE_ON_CREATE, Stage.CREATED, Stage.STARTED, Stage.RESUMED, Stage.PAUSED, Stage.STOPPED, Stage.RESTARTED,
    )

    /** Runs a shell command as the shell user; the output is read to the end so the command really finishes. */
    fun shell(command: String): String {
        val pfd: ParcelFileDescriptor = instrumentation.uiAutomation.executeShellCommand(command)
        ParcelFileDescriptor.AutoCloseInputStream(pfd).use { stream ->
            return stream.readBytes().toString(Charsets.UTF_8)
        }
    }

    fun resetApp(onboardingDone: Boolean = false, overlayAllowed: Boolean = false) {
        device.wakeUp()
        shell("wm dismiss-keyguard")
        dismissSystemDialogs()
        runCatching { device.setOrientationNatural() }
        runCatching { device.unfreezeRotation() }
        finishAllActivities()
        setOverlayAllowed(overlayAllowed)
        val p = context.getSharedPreferences(Prefs.FILE, Context.MODE_PRIVATE)
        p.edit().clear().commit()
        if (onboardingDone) p.edit().putBoolean(Prefs.KEY_ONBOARDING_DONE, true).commit()
        onMain { InkConnection.get(context).setManualHost(null, remember = true) }
        instrumentation.waitForIdleSync()
    }

    /** SYSTEM_ALERT_WINDOW is an app op: `allow` grants it, `default` falls back to the (ungranted) permission. */
    fun setOverlayAllowed(allowed: Boolean) {
        shell("appops set $PKG SYSTEM_ALERT_WINDOW ${if (allowed) "allow" else "default"}")
    }

    fun <T> onMain(block: () -> T): T {
        var result: Any? = null
        instrumentation.runOnMainSync { result = block() }
        @Suppress("UNCHECKED_CAST")
        return result as T
    }

    fun waitUntil(timeoutMs: Long = WAIT_MS, condition: () -> Boolean): Boolean {
        val end = SystemClock.uptimeMillis() + timeoutMs
        while (SystemClock.uptimeMillis() < end) {
            if (condition()) return true
            SystemClock.sleep(100)
        }
        return condition()
    }

    fun aliveActivities(): List<Activity> = onMain {
        val registry = ActivityLifecycleMonitorRegistry.getInstance()
        val out = ArrayList<Activity>()
        for (stage in ALIVE_STAGES) out.addAll(registry.getActivitiesInStage(stage))
        out
    }

    fun resumedActivity(): Activity? = onMain {
        ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).firstOrNull()
    }

    fun <A : Activity> waitForResumed(cls: Class<A>, timeoutMs: Long = WAIT_MS): A {
        var found: Activity? = null
        val ok = waitUntil(timeoutMs) {
            found = resumedActivity()
            cls.isInstance(found)
        }
        assertTrue("${cls.simpleName} never resumed (resumed: ${found?.javaClass?.simpleName})", ok)
        val a = cls.cast(found)!!
        ensureFocus(a)
        return a
    }

    private val NOT_RESPONDING = Pattern.compile("(?i).*isn't responding.*")
    private val WAIT_BUTTON = Pattern.compile("(?i)wait")

    /**
     * A foreign system window (on the slow emulator mostly a "System UI isn't responding" dialog, run 37182692894) takes
     * the focus: injected input and the accessibility tree then go to it. Closes system dialogs and answers up to three
     * "isn't responding" dialogs with Wait, logging whose they were (a real app ANR still shows in the CI ANR check).
     */
    fun dismissSystemDialogs() {
        shell("am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS")
        repeat(3) {
            val dialog = device.findObject(By.text(NOT_RESPONDING)) ?: return
            Log.w(Screenshots.TAG, "foreign dialog '${dialog.text}' from ${dialog.applicationPackage}: answering Wait")
            val wait = device.findObject(By.text(WAIT_BUTTON))
            if (wait == null) {
                Log.w(Screenshots.TAG, "no Wait button on '${dialog.text}'")
                return
            }
            wait.click()
            SystemClock.sleep(500)
        }
    }

    /** The focused window and app as the window manager sees them (`dumpsys window`, filtered here: no shell pipes). */
    fun focusReport(): String = shell("dumpsys window").lines()
        .filter { it.contains("mCurrentFocus") || it.contains("mFocusedApp") }
        .joinToString(" | ") { it.trim() }

    /**
     * [activity] must hold the window focus before a test talks to it through Espresso or UI Automator. Waits up to
     * 10 s, clearing foreign system dialogs on the way; otherwise fails naming the window that has the focus.
     */
    fun ensureFocus(activity: Activity) {
        val focused = waitUntil(WAIT_MS) {
            if (onMain { activity.hasWindowFocus() }) {
                true
            } else {
                dismissSystemDialogs()
                false
            }
        }
        assertTrue("${activity.javaClass.simpleName} has no window focus after ${WAIT_MS} ms: ${focusReport()}", focused)
    }

    fun finishAllActivities() {
        repeat(20) {
            val alive = aliveActivities()
            if (alive.isEmpty()) return
            onMain { for (a in alive) if (!a.isFinishing) a.finish() }
            instrumentation.waitForIdleSync()
            SystemClock.sleep(150)
        }
    }

    fun <T : View> findView(root: View, cls: Class<T>): T? {
        if (cls.isInstance(root)) return cls.cast(root)
        if (root is ViewGroup) {
            for (i in 0 until root.childCount) {
                val v = findView(root.getChildAt(i), cls)
                if (v != null) return v
            }
        }
        return null
    }

    fun <T : View> findView(activity: Activity, cls: Class<T>): T? = onMain { findView(activity.window.decorView, cls) }

    /**
     * One line per interesting view of [activity] (class, size, padding, attached, visibility; PillView text), plus
     * the activity's lifecycle stage and window focus: failure messages carry it so a CI log explains a layout failure
     * without screenshots.
     */
    fun layoutReport(activity: Activity): String = onMain {
        val stage = ActivityLifecycleMonitorRegistry.getInstance().getLifecycleStageOf(activity)
        val sb = StringBuilder("${activity.javaClass.simpleName} stage=$stage focus=${activity.hasWindowFocus()}")
        fun walk(v: View, depth: Int) {
            val name = v.javaClass.simpleName
            val interesting = depth <= 3 || name in setOf("InkCanvasLayout", "DryInkView", "WetInkSurface", "Toolbar", "PillView", "HorizontalScrollView")
            if (interesting) {
                sb.append("\n  ").append("  ".repeat(depth.coerceAtMost(8))).append(name)
                    .append(' ').append(v.width).append('x').append(v.height)
                    .append(" pad=").append(v.paddingLeft).append(',').append(v.paddingTop).append(',').append(v.paddingRight).append(',').append(v.paddingBottom)
                    .append(" attached=").append(v.isAttachedToWindow).append(" vis=").append(v.visibility)
                if (v is com.twelve.daylight.ink.ui.PillView) sb.append(" text='").append(v.text).append("' sel=").append(v.isSelected)
            }
            if (v is ViewGroup) for (i in 0 until v.childCount) walk(v.getChildAt(i), depth + 1)
        }
        walk(activity.window.decorView, 0)
        sb.toString()
    }

    /**
     * Dark pixels (luminance below 100 of 255) in what [view] draws, rendered into a bitmap on the main thread; a
     * 4 px rim is skipped. Independent of the screen rotation and of the wet layer above the dry view.
     */
    fun darkPixels(view: View): Int = onMain {
        val w = view.width
        val h = view.height
        if (w <= 8 || h <= 8) return@onMain 0
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bmp))
        val px = IntArray(w * h)
        bmp.getPixels(px, 0, w, 0, 0, w, h)
        bmp.recycle()
        var n = 0
        for (y in 4 until h - 4) {
            for (x in 4 until w - 4) {
                val c = px[y * w + x]
                val lum = (((c shr 16) and 0xFF) * 3 + ((c shr 8) and 0xFF) * 6 + (c and 0xFF)) / 10
                if (lum < 100) n++
            }
        }
        n
    }

    @Suppress("DEPRECATION")
    fun serviceRunning(cls: Class<*>): Boolean {
        val am = context.getSystemService(ActivityManager::class.java)
        return am.getRunningServices(200).any { it.service.packageName == PKG && it.service.className == cls.name }
    }

    @Suppress("DEPRECATION")
    fun serviceForeground(cls: Class<*>): Boolean {
        val am = context.getSystemService(ActivityManager::class.java)
        return am.getRunningServices(200).any { it.service.packageName == PKG && it.service.className == cls.name && it.foreground }
    }
}

/** The scenario's activity instance right now (a recreate replaces it). */
fun <A : Activity> ActivityScenario<A>.current(): A {
    var a: A? = null
    onActivity { a = it }
    return a!!
}

/** Synthetic pen and finger input, injected through UiAutomation like real touch screen events. */
object Pen {
    fun event(downTime: Long, eventTime: Long, action: Int, px: Float, py: Float, pressure: Float, toolType: Int): MotionEvent {
        val props = MotionEvent.PointerProperties()
        props.id = 0
        props.toolType = toolType
        val coords = MotionEvent.PointerCoords()
        coords.x = px
        coords.y = py
        coords.pressure = pressure
        coords.size = 0.01f
        val source = if (toolType == MotionEvent.TOOL_TYPE_FINGER) {
            InputDevice.SOURCE_TOUCHSCREEN
        } else {
            InputDevice.SOURCE_TOUCHSCREEN or InputDevice.SOURCE_STYLUS
        }
        return MotionEvent.obtain(downTime, eventTime, action, 1, arrayOf(props), arrayOf(coords), 0, 0, 1f, 1f, 0, 0, source, 0)
    }

    private fun inject(e: MotionEvent) {
        val ok = TestEnv.instrumentation.uiAutomation.injectInputEvent(e, true)
        e.recycle()
        assertTrue("input injection refused", ok)
    }

    /** DOWN, [moves] MOVEs and UP from (x0, y0) to (x1, y1) in screen pixels, pressure rising from 0.2 to 0.8. */
    fun stroke(x0: Float, y0: Float, x1: Float, y1: Float, toolType: Int = MotionEvent.TOOL_TYPE_STYLUS, moves: Int = 12) {
        val down = SystemClock.uptimeMillis()
        inject(event(down, down, MotionEvent.ACTION_DOWN, x0, y0, 0.2f, toolType))
        for (i in 1..moves) {
            val t = i.toFloat() / moves
            val pressure = 0.2f + 0.6f * t
            inject(event(down, down + i * 8L, MotionEvent.ACTION_MOVE, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, pressure, toolType))
        }
        inject(event(down, down + (moves + 1) * 8L, MotionEvent.ACTION_UP, x1, y1, 0.8f, toolType))
        TestEnv.instrumentation.waitForIdleSync()
    }

    /** A stroke across the middle of [view] (fractions of its width and height), in screen coordinates. */
    fun strokeAcross(view: View, fx0: Float, fy0: Float, fx1: Float, fy1: Float, toolType: Int = MotionEvent.TOOL_TYPE_STYLUS) {
        val box = TestEnv.onMain {
            val loc = IntArray(2)
            view.getLocationOnScreen(loc)
            floatArrayOf(loc[0].toFloat(), loc[1].toFloat(), view.width.toFloat(), view.height.toFloat())
        }
        stroke(box[0] + box[2] * fx0, box[1] + box[3] * fy0, box[0] + box[2] * fx1, box[1] + box[3] * fy1, toolType)
    }
}
