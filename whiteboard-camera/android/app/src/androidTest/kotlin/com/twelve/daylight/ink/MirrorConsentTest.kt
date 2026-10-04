package com.twelve.daylight.ink

import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.action.ViewActions.scrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import com.twelve.daylight.ink.TestEnv.device
import com.twelve.daylight.ink.mirror.MirrorState
import com.twelve.daylight.ink.mirror.ScreenStreamService
import com.twelve.daylight.ink.net.InkConnection
import com.twelve.daylight.ink.ui.SettingsActivity
import com.twelve.daylight.ink.ui.Texts
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.regex.Pattern

/**
 * Test 7: "Share screen with your Mac" opens the system MediaProjection dialog (com.android.systemui on Android 13)
 * through ConsentActivity, exactly as the app does. Cancel lands in CONSENT_DENIED with the app healthy; Start now
 * runs ScreenStreamService in the foreground (type mediaProjection) until Stop sharing ends it.
 */
@RunWith(AndroidJUnit4::class)
class MirrorConsentTest {
    private val conn get() = InkConnection.get(TestEnv.context)
    private val cancel = Pattern.compile("(?i)cancel")
    private val startNow = Pattern.compile("(?i)start now")

    @Before
    fun setUp() {
        TestEnv.resetApp(onboardingDone = true)
        TestEnv.onMain { conn.mirror.userStop() }      // no projection left from an earlier test
    }

    @After
    fun tearDown() {
        TestEnv.onMain { conn.mirror.userStop() }
        device.findObject(By.text(cancel).pkg(TestEnv.SYSTEMUI_PKG))?.click()
        TestEnv.finishAllActivities()
    }

    private fun openDialog(): UiObject2? {
        ActivityScenario.launch(SettingsActivity::class.java)
        TestEnv.waitForResumed(SettingsActivity::class.java)
        assumeTrue(
            "this emulator has no H.264 encoder: the share button does nothing (state UNSUPPORTED)",
            TestEnv.onMain { conn.mirror.state } != MirrorState.UNSUPPORTED,
        )
        onView(androidx.test.espresso.matcher.ViewMatchers.withContentDescription(Texts.MIRROR_SHARE)).perform(scrollTo(), click())
        return device.wait(Until.findObject(By.text(cancel).pkg(TestEnv.SYSTEMUI_PKG)), TestEnv.WAIT_MS)
    }

    @Test
    fun cancellingTheSystemDialogLeavesTheAppHealthyAndDenied() {
        val cancelButton = openDialog()
        assertNotNull("system screen capture dialog with Cancel", cancelButton)
        assertEquals(MirrorState.CONSENT_NEEDED, TestEnv.onMain { conn.mirror.state })
        Screenshots.take("10-consent-prompt")
        cancelButton!!.click()

        assertTrue("CONSENT_DENIED", TestEnv.waitUntil { TestEnv.onMain { conn.mirror.state } == MirrorState.CONSENT_DENIED })
        val settings = TestEnv.waitForResumed(SettingsActivity::class.java)
        assertFalse(settings.isFinishing)
        assertTrue((device.wait(Until.hasObject(By.text(Texts.mirrorState(MirrorState.CONSENT_DENIED.code))), TestEnv.WAIT_MS) == true))
        assertFalse("no projection held", TestEnv.onMain { conn.mirror.session.projectionHeld })
        assertFalse(TestEnv.serviceRunning(ScreenStreamService::class.java))
    }

    @Test
    fun startNowRunsTheStreamServiceUntilStop() {
        assertNotNull("system screen capture dialog", openDialog())
        val start = device.findObject(By.text(startNow).pkg(TestEnv.SYSTEMUI_PKG))
        assumeTrue("no Start now button on this system image", start != null)
        start!!.click()

        assertTrue("projection held", TestEnv.waitUntil { TestEnv.onMain { conn.mirror.session.projectionHeld } })
        assertTrue("stream service in the foreground", TestEnv.waitUntil { TestEnv.serviceForeground(ScreenStreamService::class.java) })
        // No Mac: the projection waits for a START (PAUSED), it is not streaming.
        assertEquals(MirrorState.PAUSED, TestEnv.onMain { conn.mirror.state })
        TestEnv.waitForResumed(SettingsActivity::class.java)

        onView(androidx.test.espresso.matcher.ViewMatchers.withContentDescription(Texts.MIRROR_STOP)).perform(scrollTo(), click())
        assertTrue("service stopped", TestEnv.waitUntil { !TestEnv.serviceRunning(ScreenStreamService::class.java) })
        assertEquals(MirrorState.PROJECTION_ENDED, TestEnv.onMain { conn.mirror.state })
        assertFalse(TestEnv.onMain { conn.mirror.session.projectionHeld })
    }
}
