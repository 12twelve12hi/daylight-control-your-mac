package com.twelve.daylight.ink.ui

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.Choreographer
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.LinearLayout
import android.widget.Toast
import com.twelve.daylight.ink.Facts
import com.twelve.daylight.ink.ink.DryInkView
import com.twelve.daylight.ink.ink.FrameScheduler
import com.twelve.daylight.ink.ink.InkCanvasLayout
import com.twelve.daylight.ink.ink.PenInput
import com.twelve.daylight.ink.ink.StrokeSession
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
    }

    private lateinit var prefs: Prefs
    private lateinit var conn: InkConnection
    private lateinit var session: StrokeSession
    private lateinit var canvas: InkCanvasLayout
    private lateinit var dry: DryInkView
    private var wet: WetInkSurface? = null
    private lateinit var toolbar: Toolbar
    private lateinit var chip: Chip
    private var onboardingShown = false

    private val frames = object : FrameScheduler {
        override fun requestFrame(callback: () -> Unit) {
            Choreographer.getInstance().postFrameCallback { callback() }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
        root.addView(toolbar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
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
        val input = PenInput(session, prefs, wet)
        input.unbufferedPerStroke = prefs.unbufferedInput
        dry.input = input
        wet?.input = input

        chip = Chip(toolbar.chip, ::chipAction) { conn.returnNow() }

        if (!prefs.onboardingDone && !onboardingShown) {
            onboardingShown = true
            startActivity(Intent(this, OnboardingActivity::class.java))
        }
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
        session.sendPerEvent = prefs.sendPerEvent
        conn.acquire(HOLDER, Identity.ROLE_INK)
        conn.addListener(this)
    }

    override fun onStop() {
        conn.removeListener(this)
        conn.release(HOLDER)
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
        session.applyState(state.undoDepth, state.redoDepth, state.pageIndex)
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
        session.tool = tool
        toolbar.setTool(tool)
    }

    override fun undo() = session.undo()
    override fun redo() = session.redo()
    override fun newPage() = session.newPage()
    override fun clear() = session.clear()
    override fun openSettings() { startActivity(Intent(this, SettingsActivity::class.java)) }
}
