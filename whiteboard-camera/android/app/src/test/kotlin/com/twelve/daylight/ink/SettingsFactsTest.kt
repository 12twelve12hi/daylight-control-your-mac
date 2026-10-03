package com.twelve.daylight.ink

import com.twelve.daylight.ink.net.Phase
import com.twelve.daylight.ink.ui.SettingsFacts
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** PROTOCOL 15.1 as Daylight Ink sends it: the body, the URL, the target Mac and the feedback line. */
class SettingsFactsTest {
    private val protocolInkKeys = setOf(
        "model", "manufacturer", "device", "release", "sdk", "tiramisuExt", "display", "density", "densityDpi",
        "canDrawOverlays", "pressureRange", "sideButton", "frontBuffer", "mirrorEncoders", "mirrorEncoder",
        "mirrorStream", "mirrorThermalMax", "versionName", "versionCode",
    )

    private val full = SettingsFacts.Inputs(
        model = "DC-1", manufacturer = "Daylight", device = "dc1", release = "13", sdk = 33, tiramisuExt = 7,
        displayWidth = 1600, displayHeight = 1200, density = 2.0f, densityDpi = 320, canDrawOverlays = true,
        pressureRange = "0..4095", sideButton = "BUTTON_STYLUS_PRIMARY", frontBuffer = "true",
        mirrorEncoders = "c2.mtk.avc.encoder", mirrorEncoder = "c2.mtk.avc.encoder 1280x960",
        mirrorStream = "12 fps", mirrorThermalMax = "0", versionName = "0.1.0", versionCode = 26100314L,
    )

    private val fresh = SettingsFacts.Inputs(
        model = "DC-1", manufacturer = "Daylight", device = "dc1", release = "13", sdk = 33, tiramisuExt = 0,
        displayWidth = 1600, displayHeight = 1200, density = 2.0f, densityDpi = 320, canDrawOverlays = false,
        pressureRange = null, sideButton = null, frontBuffer = null, mirrorEncoders = null, mirrorEncoder = null,
        mirrorStream = null, mirrorThermalMax = null, versionName = null, versionCode = null,
    )

    // 2026-10-03T14:05:09.750Z
    private val at = 1_791_036_309_750L

    @Test
    fun keySetIsExactlyTheProtocolInkList() {
        assertEquals(protocolInkKeys, SettingsFacts.INK_KEYS.toSet())
        assertEquals(protocolInkKeys.size, SettingsFacts.INK_KEYS.size)
        assertEquals(SettingsFacts.INK_KEYS, SettingsFacts.facts(full).keys.toList())
        val facts = JSONObject(SettingsFacts.json("abc", at, full)).getJSONObject("facts")
        assertEquals(protocolInkKeys, facts.keys().asSequence().toSet())
        assertTrue(facts.length() <= 64)
    }

    @Test
    fun envelopeFieldsArePresent() {
        val o = JSONObject(SettingsFacts.json("3f0c-uuid", at, full))
        assertEquals(setOf("schema", "source", "clientId", "sentAt", "facts"), o.keys().asSequence().toSet())
        assertEquals("daylight-tablet-facts/1", o.getString("schema"))
        assertEquals("ink", o.getString("source"))
        assertEquals("3f0c-uuid", o.getString("clientId"))
        assertEquals("2026-10-03T14:05:09Z", o.getString("sentAt"))
        assertTrue(Regex("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z").matches(SettingsFacts.isoUtc(0L)))
        assertEquals("1970-01-01T00:00:00Z", SettingsFacts.isoUtc(999L))
    }

    @Test
    fun clientIdIsOptionalAndCappedAt64() {
        assertFalse(JSONObject(SettingsFacts.json(null, at, full)).has("clientId"))
        assertFalse(JSONObject(SettingsFacts.json(" ", at, full)).has("clientId"))
        assertEquals(64, JSONObject(SettingsFacts.json("a".repeat(100), at, full)).getString("clientId").length)
    }

    @Test
    fun valuesKeepTheirJsonTypes() {
        val f = JSONObject(SettingsFacts.json("abc", at, full)).getJSONObject("facts")
        assertEquals("DC-1", f.getString("model"))
        assertEquals(33, f.get("sdk"))
        assertEquals(7, f.get("tiramisuExt"))
        assertEquals("1600x1200", f.getString("display"))
        assertEquals(2.0, f.getDouble("density"), 0.0)
        assertEquals(320, f.get("densityDpi"))
        assertEquals(true, f.get("canDrawOverlays"))
        assertEquals("0..4095", f.getString("pressureRange"))
        assertEquals(26100314L, f.getLong("versionCode"))
        assertEquals("0.1.0", f.getString("versionName"))
    }

    @Test
    fun unsetFactsAreJsonNullNotPlaceholders() {
        val body = SettingsFacts.json("abc", at, fresh)
        val f = JSONObject(body).getJSONObject("facts")
        for (k in listOf("pressureRange", "sideButton", "frontBuffer", "mirrorEncoders", "mirrorEncoder", "mirrorStream",
            "mirrorThermalMax", "versionName", "versionCode")) {
            assertTrue("$k should be null", f.isNull(k))
            assertEquals(JSONObject.NULL, f.get(k))
        }
        assertFalse(body.contains("not seen yet"))
        assertFalse(body.contains("not tried yet"))
        assertEquals(
            "{\"schema\":\"daylight-tablet-facts/1\",\"source\":\"ink\",\"clientId\":\"abc\",\"sentAt\":\"2026-10-03T14:05:09Z\"," +
                "\"facts\":{\"model\":\"DC-1\",\"manufacturer\":\"Daylight\",\"device\":\"dc1\",\"release\":\"13\",\"sdk\":33," +
                "\"tiramisuExt\":0,\"display\":\"1600x1200\",\"density\":2.0,\"densityDpi\":320,\"canDrawOverlays\":false," +
                "\"pressureRange\":null,\"sideButton\":null,\"frontBuffer\":null,\"mirrorEncoders\":null,\"mirrorEncoder\":null," +
                "\"mirrorStream\":null,\"mirrorThermalMax\":null,\"versionName\":null,\"versionCode\":null}}",
            body,
        )
        val noDisplay = fresh.copy(displayWidth = null, density = Float.NaN)
        val g = JSONObject(SettingsFacts.json("abc", at, noDisplay)).getJSONObject("facts")
        assertTrue(g.isNull("display"))
        assertTrue(g.isNull("density"))
    }

    @Test
    fun stringsAreEscaped() {
        assertEquals("\"a\\\"b\"", SettingsFacts.quote("a\"b"))
        assertEquals("\"a\\\\b\"", SettingsFacts.quote("a\\b"))
        assertEquals("\"a\\u000ab\\u000d\\u0009\\u0000\\u001f\\u007f\"", SettingsFacts.quote("a\nb\r\t\u0000\u001f\u007f"))
        assertEquals("\"café 中 🖊\"", SettingsFacts.quote("café 中 🖊"))
        val nasty = "q\"uote \\ back\nnew\u0001 café 🖊 /slash"
        val f = JSONObject(SettingsFacts.json("abc", at, full.copy(model = nasty, mirrorStream = "\t\r"))).getJSONObject("facts")
        assertEquals(nasty, f.getString("model"))
        assertEquals("\t\r", f.getString("mirrorStream"))
    }

    @Test
    fun stringValuesAreCappedAt1024Chars() {
        val long = "x".repeat(5000)
        val f = JSONObject(SettingsFacts.json("abc", at, full.copy(mirrorEncoders = long))).getJSONObject("facts")
        assertEquals(1024, f.getString("mirrorEncoders").length)
        // A cut through a surrogate pair drops the lone high half.
        val pair = "y".repeat(1023) + "🖊"
        assertEquals(1023, SettingsFacts.cap(pair, 1024).length)
        assertEquals("abc", SettingsFacts.cap("abc", 1024))
    }

    @Test
    fun urlBracketsIpv6Literals() {
        assertEquals("http://192.168.1.40:7788/api/facts", SettingsFacts.factsUrl("192.168.1.40", 7788))
        assertEquals("http://127.0.0.1:7788/api/facts", SettingsFacts.factsUrl("127.0.0.1", 7788))
        assertEquals("http://studio.local:9000/api/facts", SettingsFacts.factsUrl("studio.local", 9000))
        assertEquals("http://[fe80::1]:7788/api/facts", SettingsFacts.factsUrl("fe80::1", 7788))
        assertEquals("http://[fe80::1]:7788/api/facts", SettingsFacts.factsUrl("[fe80::1]", 7788))
    }

    @Test
    fun hostPortReadsTheSocketUrl() {
        assertEquals("192.168.1.40" to 7788, SettingsFacts.hostPort("ws://192.168.1.40:7788/ink"))
        assertEquals("fe80::1" to 7788, SettingsFacts.hostPort("ws://[fe80::1]:7788/ink"))
        assertEquals("studio.local" to 9000, SettingsFacts.hostPort("ws://studio.local:9000/ink"))
        assertNull(SettingsFacts.hostPort(null))
        assertNull(SettingsFacts.hostPort(""))
        assertNull(SettingsFacts.hostPort("ws://host/ink"))
        assertNull(SettingsFacts.hostPort("ws://host:0/ink"))
    }

    @Test
    fun targetPrefersTheAnsweringMacThenTheLastOneThenTheManualHost() {
        val live = "ws://192.168.1.10:7788/ink"
        val usb = "ws://127.0.0.1:7788/ink"
        assertEquals("192.168.1.10" to 7788, SettingsFacts.target(Phase.LIVE, live, null, null))
        assertEquals("127.0.0.1" to 7788, SettingsFacts.target(Phase.PENDING, usb, null, "192.168.1.40"))
        // A socket that is only being dialed proves nothing: fall back to the last Mac reached, then the manual host.
        assertEquals("192.168.1.10" to 7788, SettingsFacts.target(Phase.CONNECTING, usb, live, "192.168.1.40"))
        assertEquals("192.168.1.40" to 7788, SettingsFacts.target(Phase.SEARCHING, null, null, "192.168.1.40"))
        assertEquals("192.168.1.40" to 9000, SettingsFacts.target(Phase.DENIED, null, null, "192.168.1.40:9000"))
        assertEquals("fe80::2" to 7788, SettingsFacts.target(Phase.SEARCHING, null, null, "fe80::2"))
        assertNull(SettingsFacts.target(Phase.SEARCHING, usb, null, null))
        assertNull(SettingsFacts.target(Phase.SEARCHING, null, null, "  "))
    }

    @Test
    fun resultTextMapping() {
        assertEquals("Sent to your Mac.", SettingsFacts.resultText(200))
        assertEquals("Your Mac did not accept the facts (404). Update Daylight on your Mac.", SettingsFacts.resultText(404))
        assertEquals("Your Mac did not accept the facts (405). Update Daylight on your Mac.", SettingsFacts.resultText(405))
        assertEquals("Could not reach your Mac. Check the connection and tap again.", SettingsFacts.resultText(null))
        assertEquals("Your Mac refused the facts (400).", SettingsFacts.resultText(400))
        assertEquals("Your Mac refused the facts (403).", SettingsFacts.resultText(403))
        assertEquals("Your Mac refused the facts (500).", SettingsFacts.resultText(500))
        assertEquals("Connect to your Mac first.", SettingsFacts.TEXT_NO_HOST)
        assertEquals("Send facts to Mac", SettingsFacts.BUTTON)
    }

    @Test
    fun settingsHasTheButtonUnderThisTablet() {
        val s = java.io.File(ManifestTest.locate("src/main/kotlin/com/twelve/daylight/ink"), "ui/SettingsActivity.kt").readText()
        val section = s.substringAfter("label(Texts.SETTING_FACTS)")
        assertTrue(section.contains("button(SettingsFacts.BUTTON) { SettingsFacts.send(this, conn)"))
        val f = java.io.File(ManifestTest.locate("src/main/kotlin/com/twelve/daylight/ink"), "ui/SettingsFacts.kt").readText()
        assertTrue(f.contains(".callTimeout(CALL_TIMEOUT_S, TimeUnit.SECONDS)") && f.contains("const val CALL_TIMEOUT_S = 5L"))
        assertTrue(f.contains(".enqueue(") && f.contains("main.post {"))
    }
}
