package com.twelve.daylight.ink.ui

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.Choreographer
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.Toast
import com.twelve.daylight.ink.Facts
import com.twelve.daylight.ink.ink.DryInkView
import com.twelve.daylight.ink.ink.FrameScheduler
import com.twelve.daylight.ink.ink.InkCanvasLayout
import com.twelve.daylight.ink.ink.LaserPointer
import com.twelve.daylight.ink.ink.PenInput
import com.twelve.daylight.ink.ink.StrokeSession
import com.twelve.daylight.ink.ink.Tools
import com.twelve.daylight.ink.ink.WetInkSurface
import com.twelve.daylight.ink.net.Identity
import com.twelve.daylight.ink.net.InkConnection
import com.twelve.daylight.ink.net.Phase
import com.twelve.daylight.ink.prefs.Prefs
import com.twelve.daylight.ink.protocol.Encoder
import com.twelve.daylight.ink.protocol.StateReport

/**
 * Daylight Ink: the pen canvas, the toolbar with the SPEC 10 chip, the connection to the Mac.
 * Launched by the owner or by the Mac over USB with `am start -n com.twelve.daylight.ink/.MainActivity --es host <ip>`.
 */
class MainActivity : Activity(), InkConnection.Listener, Toolbar.Actions {
    companion object {
        const val TAG = "DaylightInk.ui"
        const val EXTRA_HOST = "host"
        const val HOLDER = "main"
        const val KEY_ONBOARDING_SHOWN = "onboardingShown"

        /**
         * The strokes of an instance being recreated (`recreate()` after the front-buffer setting changed, or a
         * configuration change the manifest does not list), handed to the next instance's onCreate. Only set while
         * [isChangingConfigurations]; a launch without saved state never picks it up. After real process death the
         * Mac holds the page and the tablet starts blank (the CI script checks that the app comes back healthy).
         */
        private var retained: StrokeSession.Snapshot? = null
    }

    private lateinit var prefs: Prefs
    private lateinit var conn: InkConnection
    private lateinit var session: StrokeSession
    private lateinit var canvas: InkCanvasLayout
    private lateinit var dry: DryInkView
    private var wet: WetInkSurface? = null
    private lateinit var toolbar: Toolbar
    private lateinit var chip: Chip
    private lateinit var input: PenInput
    private var onboardingShown = false
    /** True between an onStart that acquired the connection and the matching onStop (onStart may recreate instead). */
    private var holding = false

    /** Committed strokes on the page (the instrumented tests read it; the UI never does). */
    val strokeCount: Int get() = if (::session.isInitialized) session.visibleCount else 0

    private val frames = object : FrameScheduler {
        override fun requestFrame(callback: () -> Unit) {
            Choreographer.getInstance().postFrameCallback { callback() }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A recreated instance must not open onboarding a second time on top of the first one.
        onboardingShown = savedInstanceState?.getBoolean(KEY_ONBOARDING_SHOWN, false) ?: false
        EdgeToEdge.apply(this)
        Facts.logOnce(this)
        prefs = Prefs(this)
        conn = InkConnection.get(this)
        handleIntent(intent)

        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Tokens.SURFACE_CREAM) }
        canvas = InkCanvasLayout(this)
        dry = DryInkView(this)
        canvas.addLayer(dry)
        if (prefs.frontBuffer) {
            val w = WetInkSurface(this)
            w.onRendererResult = { ok, why ->
                prefs.factFrontBufferOk = if (ok) "available ($why)" else "fallback to the dry view ($why)"
                Log.i(TAG, "front buffer: ${prefs.factFrontBufferOk}")
            }
            canvas.addLayer(w)
            wet = w
        }
        root.addView(canvas, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        toolbar = Toolbar(this)
        toolbar.actions = this
        // A dense screen (UNVERIFIED `wm density`, LOOSE_ENDS D2) must not clip the row: it scrolls sideways instead.
        val toolbarScroll = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            isFillViewport = true
            setBackgroundColor(Tokens.SURFACE_CREAM)
            addView(toolbar, ViewGroup.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        root.addView(toolbarScroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        setContentView(root)

        root.setOnApplyWindowInsetsListener { _, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars())
            canvas.setPadding(bars.left, bars.top, bars.right, 0)       // the page never hides under the status bar
            val d = resources.displayMetrics.density
            toolbar.setPadding((12 * d).toInt() + bars.left, (12 * d).toInt(), (12 * d).toInt() + bars.right, (16 * d).toInt() + bars.bottom)
            insets
        }

        session = StrokeSession(conn, Encoder { System.currentTimeMillis() * 1000L }, dry, frames)
        session.sendPerEvent = prefs.sendPerEvent
        canvas.onPageSize = { w, h -> session.setViewSize(w, h) }
        input = PenInput(session, prefs, wet)
        input.unbufferedPerStroke = prefs.unbufferedInput
        // The Laser tool maps positions with the strokes' own page and has its own encoder (no shared buffer).
        input.laser = LaserPointer(conn, Encoder { System.currentTimeMillis() * 1000L }, frames) { session.page }
        dry.input = input
        wet?.input = input

        chip = Chip(toolbar.chip, ::chipAction) { conn.returnNow() }

        val kept = retained
        retained = null
        if (savedInstanceState != null && kept != null) {
            session.restore(kept)
            toolbar.setTool(kept.tool)
        }

        if (!prefs.onboardingDone && !onboardingShown) {
            onboardingShown = true
            startActivity(Intent(this, OnboardingActivity::class.java))
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(KEY_ONBOARDING_SHOWN, onboardingShown)
    }

    override fun onDestroy() {
        if (isChangingConfigurations) retained = session.snapshot()
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(i: Intent?) {
        val host = i?.getStringExtra(EXTRA_HOST)?.trim()?.takeIf { it.isNotEmpty() } ?: return
        Log.i(TAG, "host from intent: $host")
        // SPEC 9.3: remembered as the manual host for later wireless use, and tried as its own candidate now.
        conn.setManualHost(host, remember = true)
        conn.setIntentHost(host)
    }

    override fun onStart() {
        super.onStart()
        // Settings is a separate screen: every toggle is read again on the way back. The front-buffer layer exists only
        // when it was created in onCreate, so flipping that one rebuilds the canvas (handoff E step 14).
        session.sendPerEvent = prefs.sendPerEvent
        input.unbufferedPerStroke = prefs.unbufferedInput
        if (prefs.frontBuffer != (wet != null)) {
            recreate()
            return
        }
        holding = true
        conn.acquire(HOLDER, Identity.ROLE_INK)
        conn.addListener(this)
        conn.mirror.uiStarted()
    }

    override fun onStop() {
        // After an onStart that chose recreate() nothing was acquired: releasing would steal another screen's count.
        if (holding) {
            holding = false
            conn.mirror.uiStopped()
            conn.removeListener(this)
            conn.release(HOLDER)
        }
        super.onStop()
    }

    // ---- connection ----

    override fun onPhase(phase: Phase) {
        chip.bind(phase, conn.lastState, conn.lastStateAtMs)
        if (phase != Phase.LIVE) toolbar.setDepths(0, 0)
    }

    override fun onState(state: StateReport) {
        chip.bind(conn.phase, state, conn.lastStateAtMs)
        toolbar.setDepths(state.undoDepth, state.redoDepth)
        session.applyState(state.undoDepth, state.redoDepth, state.pageIndex, state.strokeCount)
    }

    private fun chipAction(tap: ChipTap) {
        when (tap) {
            ChipTap.PIN -> conn.togglePin(-1)
            ChipTap.RETRY -> conn.userRetry()
            ChipTap.EXPLAIN -> Toast.makeText(this, Texts.SWITCH_SOURCE_HOW, Toast.LENGTH_LONG).show()
            ChipTap.NONE -> {}
        }
    }

    // ---- toolbar ----

    override fun selectTool(tool: Int) {
        // The laser is not a stroke tool: the session keeps the last drawing tool and never sees Tools.LASER.
        input.laserMode = tool == Tools.LASER
        if (tool != Tools.LASER) session.tool = tool
        toolbar.setTool(tool)
    }

    override fun undo() = session.undo()
    override fun redo() = session.redo()
    override fun newPage() = session.newPage()
    override fun clear() = session.clear()
    override fun openSettings() { startActivity(Intent(this, SettingsActivity::class.java)) }
}
