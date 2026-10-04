package com.twelve.daylight.ink

import android.content.Intent
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Until
import com.twelve.daylight.ink.TestEnv.device
import com.twelve.daylight.ink.mirror.ScreenStreamService
import com.twelve.daylight.ink.overlay.OverlayService
import com.twelve.daylight.ink.ui.SettingsActivity
import com.twelve.daylight.ink.ui.Texts
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Test 8: the foreground services start and stop the way the app starts them, with POST_NOTIFICATIONS not granted
 * (Android 13 then hides the notification; the service must still run). A missing startForeground within 5 s, or a
 * stop before it after startForegroundService, would crash this process and fail the run.
 */
@RunWith(AndroidJUnit4::class)
class ServicesTest {
    @Before
    fun setUp() = TestEnv.resetApp(onboardingDone = true)

    @After
    fun tearDown() {
        // stopService, not the ACTION_STOP start: a start from the background could not go foreground.
        TestEnv.onMain { TestEnv.context.stopService(Intent(TestEnv.context, OverlayService::class.java)) }
        TestEnv.onMain { TestEnv.context.stopService(Intent(TestEnv.context, ScreenStreamService::class.java)) }
        TestEnv.waitUntil { !TestEnv.serviceRunning(OverlayService::class.java) }
        TestEnv.setOverlayAllowed(false)
        TestEnv.finishAllActivities()
    }

    private fun openSettings() {
        ActivityScenario.launch(SettingsActivity::class.java)
        TestEnv.waitForResumed(SettingsActivity::class.java)
    }

    /** Without the overlay permission the pills service goes foreground, explains row 29 and stops itself. */
    @Test
    fun overlayServiceWithoutPermissionStopsItselfCleanly() {
        openSettings()
        TestEnv.onMain {
            TestEnv.context.startForegroundService(Intent(TestEnv.context, OverlayService::class.java).putExtra(OverlayService.EXTRA_PILLS, "top"))
        }
        SystemClock.sleep(1000)
        assertTrue("stopped", TestEnv.waitUntil { !TestEnv.serviceRunning(OverlayService::class.java) })
        SystemClock.sleep(5500)             // past the 5 s startForeground deadline: no crash
        TestEnv.waitForResumed(SettingsActivity::class.java)
        assertFalse(TestEnv.serviceRunning(OverlayService::class.java))
    }

    /** With the permission (granted the way the Mac does over USB) the pills show, and Hide the pills removes them. */
    @Test
    fun overlayServiceShowsThePillsAndStops() {
        TestEnv.setOverlayAllowed(true)
        openSettings()
        TestEnv.onMain {
            TestEnv.context.startForegroundService(Intent(TestEnv.context, OverlayService::class.java).putExtra(OverlayService.EXTRA_PILLS, "top"))
        }
        assertTrue("running in the foreground", TestEnv.waitUntil { TestEnv.serviceForeground(OverlayService::class.java) })
        val pin = device.wait(Until.findObject(By.desc(Texts.PILL_PIN).pkg(TestEnv.PKG)), TestEnv.WAIT_MS)
        assertNotNull("Pin pill on screen", pin)
        assertNotNull("Clear pill on screen", device.findObject(By.desc(Texts.PILL_CLEAR).pkg(TestEnv.PKG)))
        // Pills sit inside the 96 px strip the Mac crops away.
        val bounds = pin!!.visibleBounds
        assertTrue("pin bounds $bounds", bounds.bottom <= 96)
        Screenshots.take("09-overlay-pills")
        SystemClock.sleep(5500)
        assertTrue("still running after 5 s", TestEnv.serviceRunning(OverlayService::class.java))

        // What "Hide the pills" sends.
        TestEnv.onMain {
            TestEnv.context.startService(Intent(TestEnv.context, OverlayService::class.java).setAction(OverlayService.ACTION_STOP))
        }
        assertTrue("stopped", TestEnv.waitUntil { !TestEnv.serviceRunning(OverlayService::class.java) })
        assertTrue("pills gone", (device.wait(Until.gone(By.desc(Texts.PILL_PIN).pkg(TestEnv.PKG)), TestEnv.WAIT_MS) == true))
        TestEnv.waitForResumed(SettingsActivity::class.java)
    }

    /**
     * ScreenStreamService started without a consent result (a stray start) must not crash the app: before the fix it
     * stopped itself without startForeground, which Android 9 and later punish after startForegroundService.
     */
    @Test
    fun screenStreamServiceWithoutConsentStopsWithoutCrash() {
        openSettings()
        TestEnv.onMain { TestEnv.context.startForegroundService(Intent(TestEnv.context, ScreenStreamService::class.java)) }
        assertTrue("stopped", TestEnv.waitUntil { !TestEnv.serviceRunning(ScreenStreamService::class.java) })
        SystemClock.sleep(5500)
        TestEnv.waitForResumed(SettingsActivity::class.java)
        assertFalse(TestEnv.serviceRunning(ScreenStreamService::class.java))
    }
}
