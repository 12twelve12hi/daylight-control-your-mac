package com.twelve.daylight.ink.ui

import android.app.Activity
import android.os.Bundle
import com.twelve.daylight.ink.ink.PlaceholderCanvasView

/** Daylight Ink skeleton: an edge-to-edge activity with a pen-only placeholder canvas. Networking lands in M4. */
class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        EdgeToEdge.apply(this)
        setContentView(PlaceholderCanvasView(this))
    }
}
