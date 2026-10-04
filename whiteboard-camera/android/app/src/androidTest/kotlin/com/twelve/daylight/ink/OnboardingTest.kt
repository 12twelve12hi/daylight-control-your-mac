package com.twelve.daylight.ink

import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.action.ViewActions.closeSoftKeyboard
import androidx.test.espresso.action.ViewActions.typeText
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
import androidx.test.espresso.matcher.ViewMatchers.withContentDescription
import androidx.test.espresso.matcher.ViewMatchers.withHint
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Until
import com.twelve.daylight.ink.TestEnv.device
import com.twelve.daylight.ink.net.InkConnection
import com.twelve.daylight.ink.prefs.Prefs
import com.twelve.daylight.ink.ui.MainActivity
import com.twelve.daylight.ink.ui.OnboardingActivity
import com.twelve.daylight.ink.ui.Texts
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** First run (SPEC 9.3 step 2, 13.3 rows 29 and 30): the screen, the manual address, the overlay permission screen. */
@RunWith(AndroidJUnit4::class)
class OnboardingTest {
    private val buttons = listOf(
        Texts.ONBOARDING_OVERLAY_BUTTON, Texts.ONBOARDING_NOTIFICATIONS_BUTTON, Texts.ONBOARDING_SKIP, Texts.ONBOARDING_DONE,
    )

    @Before
    fun setUp() = TestEnv.resetApp()

    @After
    fun tearDown() {
        // Leave the system Settings screen if a failed assertion stopped the test there.
        if (device.currentPackageName == TestEnv.SETTINGS_PKG) device.pressBack()
        TestEnv.finishAllActivities()
        TestEnv.setOverlayAllowed(false)
    }

    /** Test 1: a cold launch with no saved state routes MainActivity to onboarding, with the exact Texts strings. */
    @Test
    fun coldLaunchWithoutSetupShowsOnboarding() {
        ActivityScenario.launch(MainActivity::class.java).use {
            TestEnv.waitForResumed(OnboardingActivity::class.java)
            for (t in listOf(Texts.ONBOARDING_TITLE, Texts.ONBOARDING_OVERLAY_BODY, Texts.ONBOARDING_NOTIFICATIONS_BODY)) {
                assertTrue("missing text: $t", (device.wait(Until.hasObject(By.text(t).pkg(TestEnv.PKG)), TestEnv.WAIT_MS) == true))
            }
            assertTrue(device.hasObject(By.text("1. Your Mac")))
            assertTrue(device.hasObject(By.text("2. ${Texts.ONBOARDING_OVERLAY_TITLE}")))
            // Without overlay permission the status line is failure row 29.
            assertTrue(device.hasObject(By.text(Texts.PILLS_NEED_PERMISSION)))
            for (b in buttons) assertTrue("missing button: $b", device.hasObject(By.desc(b)))
            Screenshots.take("01-onboarding")

            // Skip finishes onboarding and lands on the whiteboard; the flag is persisted.
            device.findObject(By.desc(Texts.ONBOARDING_SKIP))!!.click()
            TestEnv.waitForResumed(MainActivity::class.java)
            assertTrue(Prefs(TestEnv.context).onboardingDone)
        }
    }

    /** The PillView accessibility fix: every onboarding button is a clickable Button node with its text and description. */
    @Test
    fun onboardingButtonsAreAccessibleButtons() {
        ActivityScenario.launch(OnboardingActivity::class.java).use {
            TestEnv.waitForResumed(OnboardingActivity::class.java)
            for (b in buttons) {
                val byDesc = device.wait(Until.findObject(By.desc(b)), TestEnv.WAIT_MS)
                assertNotNull("By.desc($b)", byDesc)
                val byText = device.findObject(By.text(b).clazz("android.widget.Button"))
                assertNotNull("By.text($b) as android.widget.Button", byText)
                assertTrue("$b clickable", byText!!.isClickable)
            }
            onView(withContentDescription(Texts.ONBOARDING_DONE)).check(matches(isDisplayed()))
            // Espresso's click (a finger tap) reaches onTap through performClick.
            onView(withContentDescription(Texts.ONBOARDING_DONE)).perform(click())
            assertTrue(TestEnv.waitUntil { Prefs(TestEnv.context).onboardingDone })
        }
    }

    /** Test 2: an address typed into the host field is remembered and becomes a dial candidate at once. */
    @Test
    fun manualAddressIsPersistedAndHandedToTheConnection() {
        ActivityScenario.launch(OnboardingActivity::class.java).use {
            TestEnv.waitForResumed(OnboardingActivity::class.java)
            onView(withHint(Texts.ONBOARDING_HOST_HINT)).perform(click(), typeText("192.168.1.40:7799"), closeSoftKeyboard())
            assertTrue(TestEnv.waitUntil { Prefs(TestEnv.context).manualHost == "192.168.1.40:7799" })
            val candidates = TestEnv.onMain { InkConnection.get(TestEnv.context).candidates.all() }
            assertTrue("candidates $candidates", candidates.contains("ws://192.168.1.40:7799/ink"))
            Screenshots.take("02-onboarding-manual-address")
        }
        // Reopened: the field shows the remembered address.
        ActivityScenario.launch(OnboardingActivity::class.java).use {
            TestEnv.waitForResumed(OnboardingActivity::class.java)
            assertTrue((device.wait(Until.hasObject(By.text("192.168.1.40:7799").pkg(TestEnv.PKG)), TestEnv.WAIT_MS) == true))
        }
    }

    /**
     * Test 6: the button fires Settings.ACTION_MANAGE_OVERLAY_PERMISSION, the system Settings app comes to the front,
     * Back returns to a healthy onboarding screen that still reports the permission missing.
     */
    @Test
    fun overlayPermissionScreenOpensAndBackReturnsToTheApp() {
        ActivityScenario.launch(OnboardingActivity::class.java).use {
            TestEnv.waitForResumed(OnboardingActivity::class.java)
            val button = device.wait(Until.findObject(By.desc(Texts.ONBOARDING_OVERLAY_BUTTON)), TestEnv.WAIT_MS)
            assertNotNull(button)
            assertTrue("button enabled while the permission is missing", button!!.isEnabled)
            button.click()
            assertTrue(
                "system Settings in front",
                (device.wait(Until.hasObject(By.pkg(TestEnv.SETTINGS_PKG).depth(0)), TestEnv.WAIT_MS) == true),
            )
            assertEquals(TestEnv.SETTINGS_PKG, device.currentPackageName)
            Screenshots.take("08-overlay-permission-system-screen")
            device.pressBack()
            assertTrue("app in front again", (device.wait(Until.hasObject(By.pkg(TestEnv.PKG).depth(0)), TestEnv.WAIT_MS) == true))
            val a = TestEnv.waitForResumed(OnboardingActivity::class.java)
            assertFalse(a.isFinishing)
            assertTrue((device.wait(Until.hasObject(By.text(Texts.PILLS_NEED_PERMISSION)), TestEnv.WAIT_MS) == true))
        }
    }

    /** With the app op granted (as the Mac does over USB) the status reads Allowed and the button is disabled. */
    @Test
    fun grantedOverlayPermissionShowsAllowed() {
        TestEnv.setOverlayAllowed(true)
        ActivityScenario.launch(OnboardingActivity::class.java).use {
            TestEnv.waitForResumed(OnboardingActivity::class.java)
            assertTrue((device.wait(Until.hasObject(By.text(Texts.ONBOARDING_OVERLAY_DONE)), TestEnv.WAIT_MS) == true))
            val button = device.findObject(By.desc(Texts.ONBOARDING_OVERLAY_BUTTON))
            assertNotNull(button)
            assertFalse(button!!.isEnabled)
        }
    }
}
