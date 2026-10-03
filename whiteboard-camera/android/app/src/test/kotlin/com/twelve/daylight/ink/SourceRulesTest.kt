package com.twelve.daylight.ink

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * SPEC 16 E5 and E6 facts that live in Android code the JVM cannot run: asserted on the source text, the way the web
 * suite greps for `touch-action: none`. Plus the repository writing rules for every file under android/.
 */
class SourceRulesTest {
    private val src = ManifestTest.locate("src/main/kotlin/com/twelve/daylight/ink")
    private fun read(path: String): String = File(src, path).readText()

    @Test
    fun overlayWindowIsWrapContentApplicationOverlayNotFocusableKeepScreenOn() {
        val s = read("overlay/OverlayService.kt")
        assertTrue(s.contains("WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY"))
        assertTrue(s.contains("WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON"))
        assertTrue(s.contains("WindowManager.LayoutParams.WRAP_CONTENT,\n            WindowManager.LayoutParams.WRAP_CONTENT"))
        assertTrue(s.contains("createDisplayContext(display).createWindowContext(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, null)"))
        assertTrue(s.contains("ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE"))
        assertTrue(s.contains("Gravity.TOP") && s.contains("Gravity.CENTER_HORIZONTAL"))
        assertTrue(s.contains("PillsLayout.placement("))
        assertFalse("a full-screen overlay would block touches to the app below (Android 12 rule)", s.contains("MATCH_PARENT"))
        assertFalse(s.contains("FLAG_NOT_TOUCHABLE"))
    }

    @Test
    fun overlayReusesTheCanvasClientIdWithRoleOverlay() {
        assertTrue(read("overlay/OverlayService.kt").contains("conn.acquire(HOLDER, Identity.ROLE_OVERLAY)"))
        val conn = read("net/InkConnection.kt")
        assertTrue(conn.contains("link.configure(role, prefs.clientId, prefs.deviceName)"))
        assertTrue(conn.contains("}) Identity.ROLE_INK else Identity.ROLE_OVERLAY"))
        assertTrue(read("ui/MainActivity.kt").contains("conn.acquire(HOLDER, Identity.ROLE_INK)"))
    }

    @Test
    fun onlyStylusAndEraserToolTypesDrawAndCancelsCancel() {
        val s = read("ink/PenInput.kt")
        assertTrue(s.contains("t == MotionEvent.TOOL_TYPE_STYLUS || t == MotionEvent.TOOL_TYPE_ERASER"))
        assertFalse(s.contains("TOOL_TYPE_FINGER"))
        assertTrue(s.contains("MotionEvent.ACTION_CANCEL ->"))
        assertTrue(s.contains("(e.flags and MotionEvent.FLAG_CANCELED) != 0"))
        assertTrue(s.contains("ACTION_BUTTON_PRESS"))                     // barrel button is observed, never drawn
        assertFalse(s.contains("ACTION_HOVER"))                           // hover never reaches the session
    }

    @Test
    fun unbufferedDispatchIsRequestedInOnAttachedToWindow() {
        val s = read("ink/WetInkSurface.kt")
        val attached = s.substringAfter("override fun onAttachedToWindow()").substringBefore("override fun")
        assertTrue(attached.contains("requestUnbufferedDispatch(InputDevice.SOURCE_CLASS_POINTER)"))
        assertTrue(s.contains("runCatching { CanvasFrontBufferedRenderer(this, callback) }"))
        assertTrue(s.contains("setZOrderOnTop(true)"))
        assertTrue(s.contains("holder.setFormat(PixelFormat.TRANSLUCENT)"))
        assertTrue(s.contains("release(cancelPending = true)"))
        assertFalse("never ask for a frame rate on the DC-1 (45 to 90 Hz VRR is automatic)", s.contains("setFrameRate"))
    }

    @Test
    fun okHttpClientHasNoDelayPingAndTheSubprotocol() {
        val s = read("net/InkConnection.kt")
        assertTrue(s.contains(".socketFactory(NoDelaySocketFactory)"))
        assertTrue(s.contains(".pingInterval(APP_PING_MS, TimeUnit.MILLISECONDS)"))
        assertTrue(s.contains(".header(\"Sec-WebSocket-Protocol\", SolStream.SUBPROTOCOL)"))
        assertTrue(s.contains("response.header(\"Sec-WebSocket-Protocol\")"))
        assertTrue(read("net/NoDelaySocketFactory.kt").contains("tcpNoDelay = true"))
    }

    @Test
    fun noForbiddenWordsAnywhereUnderAndroid() {
        val root = ManifestTest.locate("build.gradle.kts").absoluteFile.parentFile.parentFile   // android/
        val files = root.walkTopDown().filter { it.isFile && (it.extension in setOf("kt", "kts", "xml", "md", "properties")) && !it.path.contains("/build/") && !it.path.contains("/.gradle/") && it.name != "SourceRulesTest.kt" }.toList()
        assertTrue(files.size > 20)
        val forbidden = listOf(String(Character.toChars(0x2014)) to "em-dash", "MIP" to "the display is a transflective LCD", "PWM" to "the backlight is DC dimming", "120 Hz" to "VRR is 45 to 90 Hz", "120Hz" to "VRR is 45 to 90 Hz")
        for (f in files) {
            val text = f.readText()
            for ((needle, why) in forbidden) assertFalse("${f.path} contains '$needle' ($why)", text.contains(needle))
        }
    }
}
