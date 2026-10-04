package com.twelve.daylight.ink

import org.junit.Assert.assertEquals
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
    fun edgeToEdgeInstallsTheDecorBeforeAskingForTheInsetsController() {
        // Run 37180339019: window.insetsController before setContentView threw a NullPointerException on API 33.
        val s = read("ui/EdgeToEdge.kt")
        val decor = s.indexOf("\n        window.decorView\n")
        val controller = s.indexOf("window.insetsController?.setSystemBarsAppearance")
        assertTrue("window.decorView must be read first", decor in 0 until controller)
    }

    @Test
    fun overlayReusesTheCanvasClientIdWithRoleOverlay() {
        assertTrue(read("overlay/OverlayService.kt").contains("conn.acquire(HOLDER, Identity.ROLE_OVERLAY)"))
        val conn = read("net/InkConnection.kt")
        assertTrue(conn.contains("link.configure(role, prefs.clientId, prefs.deviceName)"))
        assertTrue(conn.contains("val role = HolderRoles.role(holders, link.role, link.phase == Phase.LIVE)"))
        assertTrue(conn.contains("if (phase == Phase.SEARCHING && holders.isNotEmpty()) applyIdentity()"))
        assertTrue(read("net/HolderRoles.kt").contains("}) Identity.ROLE_INK else Identity.ROLE_OVERLAY"))
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
        // Hover never reaches the session: the one ACTION_HOVER branch is onHover, and it feeds only PenRouter.hover,
        // which moves only the laser pointer (PenRouterTest runs it).
        val hover = s.substringAfter("fun onHover(").substringBefore("\n    }\n")
        assertTrue(hover.contains("MotionEvent.ACTION_HOVER_MOVE") && hover.contains("router.hover("))
        assertTrue(hover.contains("e.getToolType(0) == MotionEvent.TOOL_TYPE_STYLUS"))
        assertFalse(hover.contains("session."))
        assertFalse(s.substringBefore("fun onHover(").contains("ACTION_HOVER"))
        assertFalse(s.substringAfter("fun onHover(").substringAfter("\n    }\n").contains("ACTION_HOVER"))
        val routerHover = read("ink/PenRouter.kt").substringAfter("fun hover(").substringBefore("\n    }\n")
        assertTrue(routerHover.contains("laser?.hover("))
        assertFalse(routerHover.contains("session."))
    }

    @Test
    fun theLaserToolNeverReachesTheStrokeSession() {
        // LOOSE_ENDS F3: with Laser selected the pen moves the laser only (no stroke, no wet or dry ink, no undo).
        // The behaviour is PenRouterTest's (a JVM test of the routing itself). Here: PenInput hands every contact to
        // the router and never calls the session's contact methods itself, so what PenRouterTest runs is what ships.
        val s = read("ink/PenInput.kt")
        assertTrue(s.contains("private val router = PenRouter(session)"))
        for (call in listOf("router.down(", "router.laserTakesContact", "router.laserMove(", "router.sample(", "router.up(", "router.cancel()")) {
            assertTrue("PenInput calls $call", s.contains(call))
        }
        for (call in listOf("session.down(", "session.point(", "session.up(", "session.cancel(")) {
            assertFalse("PenInput must leave $call to PenRouter", s.contains(call))
        }
        val move = s.substringAfter("MotionEvent.ACTION_MOVE ->").substringBefore("MotionEvent.ACTION_UP")
        assertTrue("the laser branch returns before any sample reaches the session", move.indexOf("return true\n                }") in 0 until move.indexOf("router.sample("))
        val router = read("ink/PenRouter.kt")
        assertFalse("PenRouter is pure", router.contains("import android"))
        assertFalse(read("ink/LaserPointer.kt").contains("StrokeSession"))
        assertFalse(read("ink/LaserPointer.kt").contains("InkSink"))
        val select = read("ui/MainActivity.kt").substringAfter("override fun selectTool(").substringBefore("\n    }\n")
        assertTrue(select.contains("input.laserMode = tool == Tools.LASER"))
        assertTrue(select.contains("if (tool != Tools.LASER) session.tool = tool"))
        for (view in listOf("ink/DryInkView.kt", "ink/WetInkSurface.kt")) {
            assertTrue("$view routes hover", read(view).contains("override fun onHoverEvent(event: MotionEvent): Boolean = input?.onHover(event) == true || super.onHoverEvent(event)"))
        }
        val toolbar = read("ui/Toolbar.kt")
        assertTrue(toolbar.contains("private val laser = pill(Texts.TOOL_LASER)"))
        assertTrue(toolbar.contains("laser.onTap = { actions?.selectTool(Tools.LASER) }"))
        assertTrue(read("ui/Texts.kt").contains("const val TOOL_LASER = \"Laser\""))
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

    private fun assertInOrder(text: String, vararg needles: String) {
        var at = -1
        for (n in needles) {
            val i = text.indexOf(n, at + 1)
            assertTrue("'$n' missing or out of order", i > at)
            at = i
        }
    }

    @Test
    fun mediaProjectionOrderFollowsTheOfficialDocs() {
        // 1 consent, 2 startForeground with the mediaProjection type, 3 getMediaProjection, 4 callback, 5 virtual display.
        assertTrue(read("mirror/ConsentActivity.kt").contains("mpm.createScreenCaptureIntent()"))
        assertTrue(read("mirror/ConsentActivity.kt").contains("MediaProjectionConfig.createConfigForDefaultDisplay()"))
        assertInOrder(read("mirror/MirrorController.kt"), "activity.startForegroundService(", "fun projectionGranted()")
        assertInOrder(read("mirror/ScreenStreamService.kt"),
            "startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)",
            "mirror.projectionGranted()")
        val c = read("mirror/MirrorController.kt").substringAfter("fun projectionGranted()")
        assertInOrder(c, "mpm.getMediaProjection(pendingResultCode, data)", "p.registerCallback(projectionCallback, main)", "apply(session.consentGranted())")
        val e = read("mirror/ScreenEncoder.kt")
        assertEquals("one createVirtualDisplay per projection (Android 14)", 1, Regex("projection\\.createVirtualDisplay\\(").findAll(e).count())
        assertTrue(e.contains("vd.resize(s.width, s.height, dpi)") && e.contains("vd.setSurface(surface)"))
        assertTrue(e.contains("DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR"))
    }

    @Test
    fun aSecondConsentGrantNeverReplacesTheHeldProjection() {
        // AOSP startProjectionLocked stops the held projection when another one is created: gate both entry points.
        val m = read("mirror/MirrorController.kt")
        val result = m.substringAfter("fun consentResult(").substringBefore("fun projectionGranted()")
        assertInOrder(result, "if (!session.grantUsable(projection != null)) {", "return", "pendingResultData = data", "activity.startForegroundService(")
        val granted = m.substringAfter("fun projectionGranted()").substringBefore("fun serviceGone()")
        assertInOrder(granted, "pendingResultData = null", "if (!session.grantUsable(projection != null)) {", "return projection != null", "mpm.getMediaProjection(")
    }

    @Test
    fun noMirrorHelloForAStartThatIsNoLongerWanted() {
        // A STOP or a newer start inside the configure window must not be followed by a MIRROR_HELLO.
        val m = read("mirror/MirrorController.kt")
        assertInOrder(m.substringAfter("private fun apply(effects: List<MirrorEffect>) {"), "synchronized(genLock) { wantedGen = session.encoderGen }", "for (e in effects) perform(e)")
        val started = m.substringAfter("override fun streamStarted(gen: Int,").substringBefore("override fun output(")
        assertInOrder(started, "synchronized(genLock) {", "if (gen != wantedGen) return false", "framing.hello(", "session.encoderStarted(gen, width, height)")
        assertTrue(m.contains("session.encoderFailed(gen)"))
        val e = read("mirror/ScreenEncoder.kt").substringAfter("private fun startNow(start: Start) {").substringBefore("private fun configure(")
        assertInOrder(e, "if (!sink.streamStarted(start.gen, name, s.width, s.height)) {", "stopCodec()", "return")
    }

    @Test
    fun aFailedCodecStartReleasesItsInputSurface() {
        // developer.android.com MediaCodec.createInputSurface: "The application is responsible for calling release()
        // on the Surface when done." start() can throw after the Surface exists.
        val configure = read("mirror/ScreenEncoder.kt").substringAfter("private fun configure(").substringBefore("private fun attach(")
        assertInOrder(configure, "var surface: Surface? = null", "surface = c.createInputSurface()", "c.start()", "} catch (e: Exception) {",
            "runCatching { surface?.release() }", "runCatching { c?.release() }")
    }

    @Test
    fun encoderFormatIsTheProtocolOne() {
        val e = read("mirror/ScreenEncoder.kt")
        for (needle in listOf(
            "MediaFormat.MIMETYPE_VIDEO_AVC",
            "setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)",
            "setInteger(MediaFormat.KEY_BIT_RATE, params.bitrateBps)",
            "setInteger(MediaFormat.KEY_FRAME_RATE, NOMINAL_FRAME_RATE)",
            "const val NOMINAL_FRAME_RATE = 30",
            "setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, params.keyIntervalSeconds)",
            "setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, REPEAT_PREVIOUS_FRAME_AFTER_US)",
            "const val REPEAT_PREVIOUS_FRAME_AFTER_US = 250_000L",
            "setFloat(MediaFormat.KEY_MAX_FPS_TO_ENCODER, params.maxFps.toFloat())",
            "MediaCodec.CONFIGURE_FLAG_ENCODE",
            "c.createInputSurface()",
            "(info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0",
            "(info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0",
            "info.presentationTimeUs",
            "MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME",
            "HandlerThread(",
            "c.setCallback(callback, handler)",
            "EncoderSizing.candidates(",
        )) assertTrue("ScreenEncoder lacks $needle", e.contains(needle))
    }

    @Test
    fun theStreamSharesTheOneSocketWithBackpressureAndOnlyAfterTheAck() {
        val conn = read("net/InkConnection.kt")
        assertTrue(conn.contains("override fun allowed() {\n        liveSocket = ws"))
        assertTrue(conn.contains("override fun mirrorQueueBytes(): Long = liveSocket?.queueSize() ?: 0L"))
        assertTrue(conn.contains("val socket = liveSocket ?: return false"))
        assertTrue(conn.contains("socket.send(frame.toByteString(0, frame.size))"))
        assertTrue(read("net/Link.kt").contains("is ServerMessage.Mirror -> if (phase == Phase.LIVE) actions.mirrorControl(msg.control)"))
        val m = read("mirror/MirrorController.kt")
        assertTrue(m.contains("backpressure.admit(queued, keyFrame || config)"))
        // PROTOCOL 14.2: an oversize access unit is a gap too, so the deltas after it wait for a key frame.
        val oversize = m.substringAfter("if (n > MirrorFraming.MAX_ANNEX_B_BYTES) {").substringBefore("return")
        assertTrue(oversize.contains("backpressure.markGap()"))
        assertTrue(m.contains("uplink.acquireForMirror(HOLDER)"))
        assertTrue(conn.contains("override fun acquireForMirror(tag: String) = acquire(tag, Identity.ROLE_OVERLAY)"))
    }

    @Test
    fun thermalAndBatterySaverAreWatched() {
        val m = read("mirror/MirrorController.kt")
        assertTrue(m.contains("pm.addThermalStatusListener(app.mainExecutor)"))
        assertTrue(m.contains("PowerManager.ACTION_POWER_SAVE_MODE_CHANGED"))
        assertTrue(m.contains("pm.isPowerSaveMode"))
    }

    @Test
    fun mirrorTextsLiveInTextsAndNoCoroutinesAnywhere() {
        val t = read("ui/Texts.kt")
        assertTrue(t.contains("\"Sharing screen with your Mac\""))
        assertTrue(t.contains("\"Your Mac wants to mirror this screen. Tap to allow.\""))
        assertTrue(t.contains("\"Share screen with your Mac\""))
        assertTrue(read("mirror/ScreenStreamService.kt").contains(".setContentTitle(Texts.MIRROR_NOTIFICATION_TITLE)"))
        assertTrue(read("mirror/MirrorController.kt").contains(".setContentTitle(Texts.MIRROR_REQUEST_TITLE)"))
        assertTrue(read("ui/SettingsActivity.kt").contains("button(Texts.MIRROR_SHARE) { conn.mirror.shareRequested() }"))
        for (f in src.walkTopDown().filter { it.isFile && it.extension == "kt" }) {
            assertFalse("${f.name} uses coroutines", f.readText().contains("kotlinx.coroutines"))
        }
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
