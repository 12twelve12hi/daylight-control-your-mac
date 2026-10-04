package com.twelve.daylight.ink

import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.action.ViewActions.scrollTo
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Until
import com.twelve.daylight.ink.TestEnv.device
import com.twelve.daylight.ink.ink.DryInkView
import com.twelve.daylight.ink.ink.WetInkSurface
import com.twelve.daylight.ink.prefs.Prefs
import com.twelve.daylight.ink.ui.MainActivity
import com.twelve.daylight.ink.ui.OnboardingActivity
import com.twelve.daylight.ink.ui.PillView
import com.twelve.daylight.ink.ui.SettingsActivity
import com.twelve.daylight.ink.ui.Texts
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The whiteboard (MainActivity) offline: local ink is drawn by the dry layer whether or not a Mac is connected
 * (StrokeSession sends nothing before ACK 0 but always draws), so none of these tests needs a Mac.
 */
@RunWith(AndroidJUnit4::class)
class WhiteboardTest {
    /** A pen stroke of about half the page width leaves well over this many dark pixels at 1200x1600 and 200 dpi. */
    private val minStrokePixels = 150

    @Before
    fun setUp() = TestEnv.resetApp(onboardingDone = true)

    @After
    fun tearDown() {
        runCatching { device.setOrientationNatural() }
        runCatching { device.unfreezeRotation() }
        TestEnv.finishAllActivities()
    }

    private fun dry(a: MainActivity): DryInkView {
        val v = TestEnv.findView(a, DryInkView::class.java)
        assertNotNull("dry ink view in ${TestEnv.layoutReport(a)}", v)
        val laidOut = TestEnv.waitUntil { TestEnv.onMain { v!!.width > 0 && v.height > 0 } }
        assertTrue("dry view laid out: ${TestEnv.layoutReport(a)}", laidOut)
        return v!!
    }

    private fun launch(): ActivityScenario<MainActivity> {
        val s = ActivityScenario.launch(MainActivity::class.java)
        TestEnv.waitForResumed(MainActivity::class.java)
        return s
    }

    private fun strokes(a: MainActivity): Int = TestEnv.onMain { a.strokeCount }

    /**
     * The toolbar is a row, the page gets the rest. Before the Toolbar fixes the tool pills were 0 px tall (density read
     * before it was set) and the gaps and spacers stretched the row to the full screen height, so the canvas, and the
     * dry view in it, measured 0 x 0 (android-emulator run 37180986677).
     */
    @Test
    fun toolbarLeavesTheCanvasMostOfTheScreen() {
        launch().use { scenario ->
            val a = scenario.current()
            val report = TestEnv.layoutReport(a)
            val density = TestEnv.context.resources.displayMetrics.density
            val toolbar = TestEnv.findView(a, com.twelve.daylight.ink.ui.Toolbar::class.java)
            assertNotNull("toolbar in $report", toolbar)
            val sizes = TestEnv.onMain {
                val root = a.window.decorView
                intArrayOf(root.width, root.height, toolbar!!.height)
            }
            val toolbarDp = sizes[2] / density
            // 40 dp pills, 12 + 16 dp padding, plus the navigation bar inset: well under 200 dp.
            assertTrue("toolbar ${sizes[2]} px = $toolbarDp dp tall (window ${sizes[0]}x${sizes[1]}): $report", toolbarDp in 60f..200f)
            val dry = dry(a)
            val dryH = TestEnv.onMain { dry.height }
            assertTrue("dry view ${dryH} px tall, window ${sizes[1]} px: $report", dryH >= sizes[1] / 2)
            val pills = TestEnv.onMain {
                val out = ArrayList<Pair<String, Int>>()
                fun walk(v: android.view.View) {
                    if (v is PillView) out.add(v.text to v.height)
                    if (v is android.view.ViewGroup) for (i in 0 until v.childCount) walk(v.getChildAt(i))
                }
                walk(toolbar!!)
                out
            }
            for ((text, h) in pills) assertTrue("pill '$text' is $h px tall: $report", h >= (36 * density).toInt())
            // Pen, Highlight, Erase, Laser (LOOSE_ENDS F3), Undo, Redo, the connection chip, New page, Clear, Settings.
            assertEquals("pills in $report", 10, pills.size)
            assertTrue("a Laser pill in $report", pills.any { it.first == "Laser" })
        }
    }

    /** Test 3: the page renders empty, a stylus stroke draws, a finger stroke draws nothing. */
    @Test
    fun stylusDrawsAndFingerDoesNot() {
        launch().use { scenario ->
            val a = scenario.current()
            val dry = dry(a)
            assertEquals(0, strokes(a))
            assertTrue("an empty page has no ink", TestEnv.darkPixels(dry) < 5)
            Screenshots.take("03-whiteboard-empty")

            Pen.strokeAcross(dry, 0.25f, 0.40f, 0.75f, 0.45f, MotionEvent.TOOL_TYPE_STYLUS)
            assertTrue("stylus stroke committed", TestEnv.waitUntil { strokes(a) == 1 })
            val inked = TestEnv.darkPixels(dry)
            assertTrue("stylus stroke drew $inked dark pixels", inked > minStrokePixels)
            Screenshots.take("04-whiteboard-stroke")

            Pen.strokeAcross(dry, 0.25f, 0.70f, 0.75f, 0.75f, MotionEvent.TOOL_TYPE_FINGER)
            TestEnv.instrumentation.waitForIdleSync()
            assertEquals("a finger never makes a stroke", 1, strokes(a))
            assertEquals("a finger never draws", inked, TestEnv.darkPixels(dry))
        }
    }

    /** Test 4: Pen, Highlight and Erase toggle the selected state (exposed to accessibility by the PillView fix). */
    @Test
    fun toolbarToolsToggleSelection() {
        launch().use { scenario ->
            val a = scenario.current()
            dry(a)
            val tools = listOf(Texts.TOOL_PEN, Texts.TOOL_HIGHLIGHT, Texts.TOOL_ERASE)
            assertTrue((device.wait(Until.hasObject(By.desc(Texts.TOOL_PEN).pkg(TestEnv.PKG)), TestEnv.WAIT_MS) == true))
            assertTrue("Pen is the default", device.findObject(By.desc(Texts.TOOL_PEN))!!.isSelected)
            for (t in listOf(Texts.TOOL_HIGHLIGHT, Texts.TOOL_ERASE, Texts.TOOL_PEN)) {
                device.findObject(By.desc(t))!!.click()
                assertTrue("$t selected", (device.wait(Until.hasObject(By.desc(t).selected(true)), TestEnv.WAIT_MS) == true))
                for (other in tools - t) assertFalse("$other not selected after $t", device.findObject(By.desc(other))!!.isSelected)
            }
            for (t in listOf(Texts.TOOL_UNDO, Texts.TOOL_REDO, Texts.TOOL_NEW_PAGE, Texts.TOOL_CLEAR, Texts.TOOL_SETTINGS)) {
                assertNotNull("toolbar button $t", device.findObject(By.desc(t).clazz("android.widget.Button")))
            }
            // Undo and redo follow the Mac's STATE depths: disabled offline.
            assertFalse(device.findObject(By.desc(Texts.TOOL_UNDO))!!.isEnabled)
            assertFalse(device.findObject(By.desc(Texts.TOOL_REDO))!!.isEnabled)
            // The chip is a button too, its description is its text.
            assertTrue(device.hasObject(By.desc(Texts.LOOKING)))
            Screenshots.take("05-toolbar")
        }
    }

    /** An accessibility click (what TalkBack sends) selects a tool exactly like a tap. */
    @Test
    fun accessibilityClickSelectsATool() {
        launch().use { scenario ->
            val a = scenario.current()
            dry(a)
            val clicked = TestEnv.onMain {
                val pill = findPill(a.window.decorView, Texts.TOOL_HIGHLIGHT)!!
                pill.performAccessibilityAction(AccessibilityNodeInfo.ACTION_CLICK, null)
            }
            assertTrue(clicked)
            assertTrue(TestEnv.onMain { findPill(a.window.decorView, Texts.TOOL_HIGHLIGHT)!!.isSelected })
            assertFalse(TestEnv.onMain { findPill(a.window.decorView, Texts.TOOL_PEN)!!.isSelected })
        }
    }

    private fun findPill(root: android.view.View, text: String): PillView? {
        if (root is PillView && root.text == text) return root
        if (root is android.view.ViewGroup) {
            for (i in 0 until root.childCount) findPill(root.getChildAt(i), text)?.let { return it }
        }
        return null
    }

    /** The eraser tool removes the stroke it crosses, locally, without a Mac. */
    @Test
    fun eraserRemovesAStroke() {
        launch().use { scenario ->
            val a = scenario.current()
            val dry = dry(a)
            Pen.strokeAcross(dry, 0.30f, 0.50f, 0.70f, 0.50f)
            assertTrue(TestEnv.waitUntil { strokes(a) == 1 })
            device.findObject(By.desc(Texts.TOOL_ERASE))!!.click()
            assertTrue((device.wait(Until.hasObject(By.desc(Texts.TOOL_ERASE).selected(true)), TestEnv.WAIT_MS) == true))
            Pen.strokeAcross(dry, 0.50f, 0.40f, 0.50f, 0.60f)
            assertTrue("erased", TestEnv.waitUntil { strokes(a) == 0 })
            assertTrue(TestEnv.waitUntil { TestEnv.darkPixels(dry) < 5 })
        }
    }

    /**
     * Test 9: MainActivity handles orientation itself (configChanges), so rotating keeps the same instance, and the
     * stroke survives the page resize. Before the DryInkView fix the bitmap was rebuilt from a replay list that never
     * held pen strokes, so the ink vanished on rotation while the stroke count stayed.
     */
    @Test
    fun rotationKeepsTheInstanceAndTheInk() {
        launch().use { scenario ->
            val a = scenario.current()
            val dry = dry(a)
            Pen.strokeAcross(dry, 0.25f, 0.40f, 0.75f, 0.45f)
            assertTrue(TestEnv.waitUntil { strokes(a) == 1 })
            assertEquals(1, TestEnv.onMain { dry.replayCount })
            val portraitHeight = TestEnv.onMain { dry.height }

            device.setOrientationLeft()
            assertTrue("page resized in landscape", TestEnv.waitUntil { TestEnv.onMain { dry.height != portraitHeight && dry.height > 0 } })
            TestEnv.instrumentation.waitForIdleSync()
            assertSame("not recreated on rotation", a, scenario.current())
            assertEquals(1, strokes(a))
            val landscapeInk = TestEnv.darkPixels(dry)
            assertTrue("ink after rotation: $landscapeInk", landscapeInk > minStrokePixels / 2)

            device.setOrientationNatural()
            assertTrue(TestEnv.waitUntil { TestEnv.onMain { dry.height == portraitHeight } })
            TestEnv.instrumentation.waitForIdleSync()
            device.unfreezeRotation()
            assertSame(a, scenario.current())
            assertEquals(1, strokes(a))
            assertTrue("ink after rotating back", TestEnv.darkPixels(dry) > minStrokePixels)
        }
    }

    /**
     * Tests 9 and 10: ActivityScenario.recreate() is the in-process stand-in for the save and restore path (true process
     * death would kill this instrumentation; the CI script checks `am kill` separately). The new instance takes over
     * the strokes and the tool.
     */
    @Test
    fun recreateKeepsStrokesAndTool() {
        launch().use { scenario ->
            val a = scenario.current()
            val dry = dry(a)
            Pen.strokeAcross(dry, 0.25f, 0.40f, 0.75f, 0.45f)
            assertTrue(TestEnv.waitUntil { strokes(a) == 1 })
            device.findObject(By.desc(Texts.TOOL_HIGHLIGHT))!!.click()
            assertTrue((device.wait(Until.hasObject(By.desc(Texts.TOOL_HIGHLIGHT).selected(true)), TestEnv.WAIT_MS) == true))

            scenario.recreate()
            val b = scenario.current()
            assertNotSame("a new instance", a, b)
            assertEquals(1, strokes(b))
            val dry2 = dry(b)
            assertTrue("restored ink is drawn", TestEnv.waitUntil { TestEnv.darkPixels(dry2) > minStrokePixels })
            assertTrue("tool kept", (device.wait(Until.hasObject(By.desc(Texts.TOOL_HIGHLIGHT).selected(true)), TestEnv.WAIT_MS) == true))
        }
    }

    /** A recreated MainActivity must not stack a second onboarding screen on the first (onboardingShown is saved). */
    @Test
    fun recreateDoesNotOpenOnboardingTwice() {
        TestEnv.context.getSharedPreferences(Prefs.FILE, 0).edit().putBoolean(Prefs.KEY_ONBOARDING_DONE, false).commit()
        ActivityScenario.launch(MainActivity::class.java).use {
            TestEnv.waitForResumed(OnboardingActivity::class.java)
            val main = TestEnv.aliveActivities().filterIsInstance<MainActivity>().single()
            TestEnv.onMain { main.recreate() }
            assertTrue(
                "a new MainActivity",
                TestEnv.waitUntil { TestEnv.aliveActivities().filterIsInstance<MainActivity>().any { it !== main } },
            )
            TestEnv.instrumentation.waitForIdleSync()
            Thread.sleep(500)
            TestEnv.instrumentation.waitForIdleSync()
            val onboardings = TestEnv.aliveActivities().filterIsInstance<OnboardingActivity>().filter { !it.isFinishing }
            assertEquals("one onboarding screen", 1, onboardings.size)
        }
    }

    /**
     * Switching the front buffer off in Settings rebuilds the canvas on the way back (MainActivity.onStart calls
     * recreate()): no crash, no wet layer any more, the stroke is still there.
     */
    @Test
    fun frontBufferToggleRebuildsTheCanvasAndKeepsTheStroke() {
        launch().use { scenario ->
            val a = scenario.current()
            assertNotNull("front buffer on by default", TestEnv.findView(a, WetInkSurface::class.java))
            val dry = dry(a)
            Pen.strokeAcross(dry, 0.25f, 0.40f, 0.75f, 0.45f)
            assertTrue(TestEnv.waitUntil { strokes(a) == 1 })

            device.findObject(By.desc(Texts.TOOL_SETTINGS))!!.click()
            TestEnv.waitForResumed(SettingsActivity::class.java)
            onView(withText(Texts.SETTING_FRONT_BUFFER)).perform(scrollTo(), click())
            assertTrue(TestEnv.waitUntil { !Prefs(TestEnv.context).frontBuffer })
            device.pressBack()

            assertTrue(
                "a rebuilt MainActivity",
                TestEnv.waitUntil { (TestEnv.resumedActivity() as? MainActivity)?.let { it !== a } == true },
            )
            val b = TestEnv.resumedActivity() as MainActivity
            assertNull("no wet layer", TestEnv.findView(b, WetInkSurface::class.java))
            assertEquals(1, strokes(b))
            val dry2 = dry(b)
            assertTrue(TestEnv.waitUntil { TestEnv.darkPixels(dry2) > minStrokePixels })
            // The rebuilt canvas still draws.
            Pen.strokeAcross(dry2, 0.25f, 0.60f, 0.75f, 0.65f)
            assertTrue(TestEnv.waitUntil { strokes(b) == 2 })
        }
    }
}
