package com.twelve.daylight.ink

import android.os.Build
import android.widget.TextView
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.action.ViewActions.replaceText
import androidx.test.espresso.action.ViewActions.scrollTo
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.matcher.ViewMatchers.isChecked
import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
import androidx.test.espresso.matcher.ViewMatchers.isNotChecked
import androidx.test.espresso.matcher.ViewMatchers.withContentDescription
import androidx.test.espresso.matcher.ViewMatchers.withHint
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.twelve.daylight.ink.prefs.Prefs
import com.twelve.daylight.ink.ui.SettingsActivity
import com.twelve.daylight.ink.ui.SettingsFacts
import com.twelve.daylight.ink.ui.Texts
import org.hamcrest.CoreMatchers.containsString
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Test 5: Settings opens, "This tablet" lists the device facts, "Send facts to Mac" is there and answers. */
@RunWith(AndroidJUnit4::class)
class SettingsTest {
    @Before
    fun setUp() = TestEnv.resetApp(onboardingDone = true)

    @After
    fun tearDown() = TestEnv.finishAllActivities()

    @Test
    fun settingsShowsThisTabletFactsAndTheSendButton() {
        ActivityScenario.launch(SettingsActivity::class.java).use { scenario ->
            TestEnv.waitForResumed(SettingsActivity::class.java)
            onView(withText(Texts.SETTINGS_TITLE)).check(matches(isDisplayed()))
            onView(withText(Texts.SETTING_FRONT_BUFFER)).check(matches(isChecked()))
            onView(withContentDescription(Texts.MIRROR_SHARE)).perform(scrollTo()).check(matches(isDisplayed()))
            onView(withText(Texts.SETTINGS_TITLE)).perform(scrollTo())
            Screenshots.take("06-settings")

            onView(withText(Texts.SETTING_FACTS)).perform(scrollTo()).check(matches(isDisplayed()))
            val clientId = Prefs(TestEnv.context).clientId
            val facts = withText(containsString("canDrawOverlays="))
            onView(facts).perform(scrollTo()).check(matches(isDisplayed()))
            onView(facts).check(matches(withText(containsString("sdk=${Build.VERSION.SDK_INT}"))))
            onView(facts).check(matches(withText(containsString("model=${Build.MODEL}"))))
            onView(facts).check(matches(withText(containsString("canDrawOverlays=false"))))
            onView(facts).check(matches(withText(containsString("clientId=$clientId"))))
            onView(withContentDescription(SettingsFacts.BUTTON)).perform(scrollTo()).check(matches(isDisplayed()))
            Screenshots.take("07-settings-this-tablet")

            // No Mac in this test: the result line ends as "connect first" or "could not reach", never stuck sending.
            onView(withContentDescription(SettingsFacts.BUTTON)).perform(click())
            val activity = scenario.current()
            val endings = setOf(SettingsFacts.TEXT_NO_HOST, SettingsFacts.TEXT_UNREACHABLE)
            assertTrue(
                "facts result line",
                TestEnv.waitUntil(15_000) {
                    TestEnv.onMain {
                        val all = ArrayList<TextView>()
                        collect(activity.window.decorView, all)
                        all.any { it.text.toString() in endings }
                    }
                },
            )
        }
    }

    private fun collect(v: android.view.View, out: MutableList<TextView>) {
        if (v is TextView) out.add(v)
        if (v is android.view.ViewGroup) for (i in 0 until v.childCount) collect(v.getChildAt(i), out)
    }

    /** Test 9 for Settings: recreate keeps what the owner set (every setting is written to prefs at once). */
    @Test
    fun recreateKeepsTheSettings() {
        ActivityScenario.launch(SettingsActivity::class.java).use { scenario ->
            TestEnv.waitForResumed(SettingsActivity::class.java)
            onView(withHint(Texts.ONBOARDING_HOST_HINT)).perform(scrollTo(), replaceText("10.0.0.5"))
            onView(withText(Texts.SETTING_UNBUFFERED)).perform(scrollTo(), click())
            assertTrue(TestEnv.waitUntil { Prefs(TestEnv.context).manualHost == "10.0.0.5" })
            assertTrue(TestEnv.waitUntil { !Prefs(TestEnv.context).unbufferedInput })
            val before = scenario.current()

            scenario.recreate()
            assertNotSame(before, scenario.current())
            onView(withHint(Texts.ONBOARDING_HOST_HINT)).perform(scrollTo()).check(matches(withText("10.0.0.5")))
            onView(withText(Texts.SETTING_UNBUFFERED)).perform(scrollTo()).check(matches(isNotChecked()))
            onView(withText(Texts.SETTING_FRONT_BUFFER)).perform(scrollTo()).check(matches(isChecked()))
            assertEquals("10.0.0.5", Prefs(TestEnv.context).manualHost)
        }
    }
}
