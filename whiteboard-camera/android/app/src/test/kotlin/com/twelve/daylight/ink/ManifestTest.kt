package com.twelve.daylight.ink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/** SPEC 16 E5, the manifest half: parsed as XML, no aapt needed. */
class ManifestTest {
    companion object {
        const val ANDROID_NS = "http://schemas.android.com/apk/res/android"

        /** Gradle runs unit tests with the module directory as the working directory; the harness may differ. */
        fun locate(relative: String): File {
            val roots = listOf(".", "app", "android/app", "whiteboard-camera/android/app", "../app")
            for (r in roots) {
                val f = File(r, relative)
                if (f.exists()) return f
            }
            throw AssertionError("cannot find $relative from ${File(".").absolutePath}")
        }
    }

    private val doc = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        .newDocumentBuilder().parse(locate("src/main/AndroidManifest.xml"))

    private fun elements(tag: String): List<Element> {
        val nodes = doc.getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }
    }

    private fun Element.attr(name: String): String? = if (hasAttributeNS(ANDROID_NS, name)) getAttributeNS(ANDROID_NS, name) else null

    @Test
    fun everyComponentWithAnIntentFilterDeclaresExported() {
        val components = listOf("activity", "service", "receiver", "provider").flatMap { elements(it) }
        assertTrue(components.size >= 7)
        for (c in components) {
            val hasFilter = (0 until c.childNodes.length).any { c.childNodes.item(it).nodeName == "intent-filter" }
            if (hasFilter) assertNotNull("${c.attr("name")} has an intent filter but no android:exported", c.attr("exported"))
        }
    }

    @Test
    fun overlayServiceIsAPrivateConnectedDeviceForegroundService() {
        val svc = elements("service").single { it.attr("name") == ".overlay.OverlayService" }
        assertEquals("false", svc.attr("exported"))
        assertEquals("connectedDevice", svc.attr("foregroundServiceType"))
    }

    @Test
    fun screenStreamServiceIsAPrivateMediaProjectionForegroundService() {
        // PROTOCOL 14 and developer.android.com foreground service types: type mediaProjection, not exported.
        val svc = elements("service").single { it.attr("name") == ".mirror.ScreenStreamService" }
        assertEquals("false", svc.attr("exported"))
        assertEquals("mediaProjection", svc.attr("foregroundServiceType"))
        assertEquals(2, elements("service").size)
    }

    @Test
    fun consentActivityIsPrivateTranslucentAndOutOfRecents() {
        val a = elements("activity").single { it.attr("name") == ".mirror.ConsentActivity" }
        assertEquals("false", a.attr("exported"))
        assertEquals("true", a.attr("excludeFromRecents"))
        assertEquals("@style/Theme.DaylightInk.Consent", a.attr("theme"))
        val hasFilter = (0 until a.childNodes.length).any { a.childNodes.item(it).nodeName == "intent-filter" }
        assertTrue("only this app opens the consent screen", !hasFilter)
        val themes = locate("src/main/res/values/themes.xml").readText()
        assertTrue(themes.contains("<style name=\"Theme.DaylightInk.Consent\" parent=\"android:Theme.Translucent.NoTitleBar\">"))
    }

    @Test
    fun theLauncherActivityAndBootReceiverAreExportedTheRestIsNot() {
        val main = elements("activity").single { it.attr("name") == ".ui.MainActivity" }
        assertEquals("true", main.attr("exported"))
        assertEquals("singleTop", main.attr("launchMode"))
        val actions = elements("action").map { it.attr("name") }
        assertTrue(actions.contains("android.intent.action.MAIN"))
        assertTrue(elements("category").map { it.attr("name") }.contains("android.intent.category.LAUNCHER"))
        val boot = elements("receiver").single { it.attr("name") == ".overlay.BootReceiver" }
        assertEquals("true", boot.attr("exported"))
        assertTrue(actions.contains("android.intent.action.BOOT_COMPLETED"))
        for (name in listOf(".ui.OnboardingActivity", ".ui.SettingsActivity", ".mirror.ConsentActivity")) {
            assertEquals("false", elements("activity").single { it.attr("name") == name }.attr("exported"))
        }
    }

    @Test
    fun requiredPermissionsArePresent() {
        val perms = elements("uses-permission").map { it.attr("name") }.toSet()
        val required = listOf(
            "android.permission.INTERNET",
            "android.permission.CHANGE_WIFI_MULTICAST_STATE",
            "android.permission.SYSTEM_ALERT_WINDOW",
            "android.permission.FOREGROUND_SERVICE",
            "android.permission.POST_NOTIFICATIONS",
            "android.permission.ACCESS_NETWORK_STATE",
            "android.permission.ACCESS_WIFI_STATE",
            "android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE",
            "android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION",
            "android.permission.RECEIVE_BOOT_COMPLETED",
        )
        for (p in required) assertTrue("missing $p", perms.contains(p))
        // NsdManager needs no location permission; FLAG_KEEP_SCREEN_ON needs no WAKE_LOCK (research-android-ink 9).
        assertTrue(perms.none { it?.contains("LOCATION") == true })
        assertTrue(perms.none { it == "android.permission.WAKE_LOCK" })
        // MediaProjection needs no capture permission of its own: the consent dialog is the grant.
        assertTrue(perms.none { it == "android.permission.CAPTURE_VIDEO_OUTPUT" || it == "android.permission.RECORD_AUDIO" })
        assertEquals(10, perms.size)
    }

    @Test
    fun plainWebSocketsToTheMacAreAllowed() {
        val app = elements("application").single()
        assertEquals("true", app.attr("usesCleartextTraffic"))
        assertEquals("@string/app_name", app.attr("label"))
    }
}
