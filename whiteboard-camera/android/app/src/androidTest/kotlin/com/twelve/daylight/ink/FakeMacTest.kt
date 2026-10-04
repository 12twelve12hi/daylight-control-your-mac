package com.twelve.daylight.ink

import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.action.ViewActions.replaceText
import androidx.test.espresso.action.ViewActions.scrollTo
import androidx.test.espresso.matcher.ViewMatchers.withContentDescription
import androidx.test.espresso.matcher.ViewMatchers.withHint
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Until
import com.twelve.daylight.ink.TestEnv.device
import com.twelve.daylight.ink.ink.DryInkView
import com.twelve.daylight.ink.net.InkConnection
import com.twelve.daylight.ink.net.Phase
import com.twelve.daylight.ink.prefs.Prefs
import com.twelve.daylight.ink.ui.MainActivity
import com.twelve.daylight.ink.ui.OnboardingActivity
import com.twelve.daylight.ink.ui.SettingsActivity
import com.twelve.daylight.ink.ui.SettingsFacts
import com.twelve.daylight.ink.ui.Texts
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.regex.Pattern

/**
 * Test 11: a fake Mac on 127.0.0.1 inside this process. The app dials it from the manual address (after the
 * 127.0.0.1:7788 loopback candidate, which is refused), offers `solstream.v1`, sends HANDSHAKE, receives the golden
 * HANDSHAKE_ACK (status 0) and the golden STATE `state_live_pinned` (allowed, active source, pinned), and is LIVE.
 * Bonjour discovery keeps running on the emulator and finds nothing; it never replaces a LIVE socket.
 */
@RunWith(AndroidJUnit4::class)
class FakeMacTest {
    private lateinit var mac: FakeMac
    private val conn get() = InkConnection.get(TestEnv.context)
    private val connectMs = 30_000L

    @Before
    fun setUp() {
        TestEnv.resetApp()
        mac = FakeMac(Golden.bytes("handshake_ack_ok"), Golden.bytes("state_live_pinned"))
    }

    @After
    fun tearDown() {
        TestEnv.finishAllActivities()
        TestEnv.onMain { conn.setManualHost(null, remember = true) }
        mac.close()
    }

    /** The RFC 6455 accept value of the fake equals the golden manifest's `websocket` vector. */
    @Test
    fun fakeMacAcceptKeyMatchesTheGoldenVector() {
        val ws = Golden.manifest.getJSONObject("websocket")
        assertEquals(FakeMac.GUID, ws.getString("guid"))
        assertEquals(ws.getString("accept"), FakeMac.acceptKey(ws.getString("key")))
    }

    @Test
    fun onboardingConnectsToTheTypedAddress() {
        ActivityScenario.launch(OnboardingActivity::class.java).use {
            TestEnv.waitForResumed(OnboardingActivity::class.java)
            onView(withHint(Texts.ONBOARDING_HOST_HINT)).perform(replaceText(mac.host))
            assertTrue(
                "onboarding says connected",
                (device.wait(Until.hasObject(By.text(Pattern.compile("Connected to ws://127\\.0\\.0\\.1:${mac.port}/ink"))), connectMs) == true),
            )
            assertEquals(Phase.LIVE, TestEnv.onMain { conn.phase })
            assertEquals(listOf("solstream.v1"), mac.offeredProtocols.distinct())
            val name = mac.handshakeNames.last()
            val parts = name.split(";")
            assertEquals("ink", parts[0])
            assertEquals(Prefs(TestEnv.context).clientId, parts[1])
            assertTrue("label ${parts[2]}", parts[2].startsWith("Daylight Ink"))
            // HANDSHAKE frame layout (PROTOCOL 6.1): canvas 1200 x 1600 at 200 dpi.
            val hs = mac.received.first { FakeMac.opcode(it) == 0x0001 }
            val b = ByteBuffer.wrap(hs).order(ByteOrder.LITTLE_ENDIAN)
            assertEquals(1200f, b.getFloat(16), 0f)
            assertEquals(1600f, b.getFloat(20), 0f)
            assertEquals(200f, b.getFloat(24), 0f)
        }
    }

    /** The whiteboard chip reaches the pinned LIVE text, a stylus stroke goes out as START, CHUNK, COMMIT. */
    @Test
    fun whiteboardIsLiveAndSendsTheStroke() {
        TestEnv.context.getSharedPreferences(Prefs.FILE, 0).edit()
            .putBoolean(Prefs.KEY_ONBOARDING_DONE, true)
            .putString(Prefs.KEY_MANUAL_HOST, mac.host)
            .commit()
        TestEnv.onMain { conn.setManualHost(mac.host, remember = true) }
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            TestEnv.waitForResumed(MainActivity::class.java)
            assertTrue("chip shows ${Texts.KEEP}", (device.wait(Until.hasObject(By.desc(Texts.KEEP).pkg(TestEnv.PKG)), connectMs) == true))
            assertEquals(Phase.LIVE, TestEnv.onMain { conn.phase })
            // The golden STATE carries undo depth 3 and redo depth 0: Undo is enabled from it.
            assertTrue((device.wait(Until.hasObject(By.desc(Texts.TOOL_UNDO).enabled(true)), TestEnv.WAIT_MS) == true))
            assertTrue(device.hasObject(By.desc(Texts.TOOL_REDO).enabled(false)))
            Screenshots.take("11-connected")

            val a = scenario.current()
            val dry = TestEnv.findView(a, DryInkView::class.java)!!
            val before = mac.received.size
            Pen.strokeAcross(dry, 0.25f, 0.40f, 0.75f, 0.45f)
            assertTrue("STROKE_COMMIT received", TestEnv.waitUntil { mac.received.drop(before).any { FakeMac.opcode(it) == 0x0012 } })
            val ink = mac.received.drop(before).filter { FakeMac.opcode(it) in 0x0010..0x0013 }
            assertEquals(0x0010, FakeMac.opcode(ink.first()))
            assertEquals(0x0012, FakeMac.opcode(ink.last()))
            assertTrue(ink.drop(1).dropLast(1).all { FakeMac.opcode(it) == 0x0011 })
            // One stroke id throughout; the COMMIT's point count is the sum of the CHUNK counts.
            val id = ink.first().copyOfRange(16, 32)
            for (f in ink) assertArrayEquals(id, f.copyOfRange(16, 32))
            val points = ink.filter { FakeMac.opcode(it) == 0x0011 }.sumOf {
                ByteBuffer.wrap(it).order(ByteOrder.LITTLE_ENDIAN).getShort(32).toInt() and 0xFFFF
            }
            val committed = ByteBuffer.wrap(ink.last()).order(ByteOrder.LITTLE_ENDIAN).getInt(32)
            assertEquals(points, committed)
            assertTrue("at least DOWN plus a dozen MOVE samples: $points", points >= 13)
            // Byte parity with the golden `stroke_start`: same length, same pen tool, colour, width, pointer and phase.
            val golden = Golden.bytes("stroke_start")
            assertEquals(golden.size, ink.first().size)
            assertArrayEquals(golden.copyOfRange(32, 43), ink.first().copyOfRange(32, 43))
        }
    }

    /** Settings > Send facts to Mac posts PROTOCOL 15 JSON to the connected Mac and shows "Sent to your Mac." */
    @Test
    fun factsReachTheFakeMac() {
        TestEnv.onMain { conn.setManualHost(mac.host, remember = true) }
        ActivityScenario.launch(SettingsActivity::class.java).use {
            TestEnv.waitForResumed(SettingsActivity::class.java)
            assertTrue("LIVE", TestEnv.waitUntil(connectMs) { TestEnv.onMain { conn.phase } == Phase.LIVE })
            onView(withContentDescription(SettingsFacts.BUTTON)).perform(scrollTo(), click())
            assertTrue("facts posted", TestEnv.waitUntil { mac.factsBodies.isNotEmpty() })
            val body = mac.factsBodies.first()
            assertTrue(body, body.startsWith("{\"schema\":\"${SettingsFacts.SCHEMA}\",\"source\":\"ink\""))
            assertTrue(body, body.contains("\"clientId\":\"${Prefs(TestEnv.context).clientId}\""))
            assertNotNull(device.wait(Until.findObject(By.text(SettingsFacts.TEXT_SENT)), TestEnv.WAIT_MS))
        }
    }
}
