package com.twelve.daylight.ink

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The two Toolbar layout defects the android-emulator job found (run 37180986677: the whiteboard canvas measured
 * 0 x 0). Views cannot be measured on the JVM here, so the rules are checked on the source; the instrumented
 * WhiteboardTest.toolbarLeavesTheCanvasMostOfTheScreen is the measured proof.
 */
class ToolbarSourceTest {
    private val src = File(ManifestTest.locate("src/main/kotlin/com/twelve/daylight/ink"), "ui/Toolbar.kt").readText()

    @Test
    fun densityIsInitialisedBeforeThePillsThatReadIt() {
        val density = src.indexOf("private val d = resources.displayMetrics.density")
        val firstPill = src.indexOf("= pill(")
        assertTrue("density declaration missing", density >= 0)
        assertTrue("first pill(...) initializer missing", firstPill >= 0)
        assertTrue("d must be declared before the first pill(...) initializer, or every pill is 0 px tall", density < firstPill)
    }

    @Test
    fun gapsAndSpacersKeepTheirOwnOnePixelLayoutParams() {
        // add() gives WRAP_CONTENT height; a bare View with it fills the parent's height (View.getDefaultSize).
        assertFalse("a gap or spacer must not go through add()", src.contains("add(gap())") || src.contains("add(spacer())"))
        assertTrue(src.contains("addView(View(context), LayoutParams((10 * d).toInt(), 1))"))
        assertTrue(src.contains("addView(View(context), LayoutParams(0, 1, 1f))"))
    }
}
