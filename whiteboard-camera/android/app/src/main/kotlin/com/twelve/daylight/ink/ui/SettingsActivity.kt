package com.twelve.daylight.ink.ui

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import com.twelve.daylight.ink.Facts
import com.twelve.daylight.ink.net.Identity
import com.twelve.daylight.ink.net.InkConnection
import com.twelve.daylight.ink.overlay.OverlayService
import com.twelve.daylight.ink.prefs.Prefs

/** SPEC 11 tablet-side settings plus the device facts of LOOSE_ENDS section D. */
class SettingsActivity : Activity() {
    companion object {
        const val HOLDER = "settings"
    }

    private lateinit var prefs: Prefs
    private lateinit var conn: InkConnection

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        EdgeToEdge.apply(this)
        prefs = Prefs(this)
        conn = InkConnection.get(this)
        val d = resources.displayMetrics.density
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Tokens.PAPER_BG)
            setPadding((28 * d).toInt(), (56 * d).toInt(), (28 * d).toInt(), (48 * d).toInt())
        }
        col.addView(TextView(this).apply { text = Texts.SETTINGS_TITLE; textSize = 26f; setTextColor(Tokens.INK_BLACK); setPadding(0, 0, 0, (16 * d).toInt()) })

        col.addView(toggle(Texts.SETTING_FRONT_BUFFER, prefs.frontBuffer) { prefs.frontBuffer = it })
        col.addView(toggle(Texts.SETTING_UNBUFFERED, prefs.unbufferedInput) { prefs.unbufferedInput = it })
        col.addView(toggle(Texts.SETTING_SEND_PER_EVENT, prefs.sendPerEvent) { prefs.sendPerEvent = it })
        col.addView(toggle(Texts.SETTING_PILLS_AT_BOOT, prefs.pillsAtBoot) { prefs.pillsAtBoot = it })
        col.addView(toggle(Texts.SETTING_PILLS_POSITION, prefs.pillsPosition == "bottom") { prefs.pillsPosition = if (it) "bottom" else "top" })

        col.addView(label(Texts.SETTING_MANUAL_HOST))
        col.addView(EditText(this).apply {
            hint = Texts.ONBOARDING_HOST_HINT
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            setText(prefs.manualHost ?: "")
            setTextColor(Tokens.INK_BLACK); setHintTextColor(Tokens.TEXT_MUTED)
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
                override fun afterTextChanged(s: Editable?) { InkConnection.get(this@SettingsActivity).setManualHost(s?.toString(), remember = true) }
            })
        })

        col.addView(button(Texts.SETTING_FORGET) {
            prefs.forgetMac()
            InkConnection.get(this).setManualHost(null, remember = true)
            Toast.makeText(this, "Forgotten. Bonjour or USB will find the Mac again.", Toast.LENGTH_SHORT).show()
        })
        col.addView(button(Texts.SETTING_PILLS_NOW) {
            if (!Settings.canDrawOverlays(this)) {
                Toast.makeText(this, Texts.PILLS_NEED_PERMISSION, Toast.LENGTH_LONG).show()
                startActivity(Intent(this, OnboardingActivity::class.java))
            } else {
                startForegroundService(Intent(this, OverlayService::class.java).putExtra(OverlayService.EXTRA_PILLS, prefs.pillsPosition))
            }
        })
        col.addView(button(Texts.SETTING_PILLS_STOP) {
            startService(Intent(this, OverlayService::class.java).setAction(OverlayService.ACTION_STOP))
        })
        col.addView(button(Texts.SETTING_SETUP_AGAIN) {
            prefs.onboardingDone = false
            startActivity(Intent(this, OnboardingActivity::class.java))
        })

        col.addView(label(Texts.SETTING_FACTS))
        col.addView(TextView(this).apply {
            text = Facts.lines(this@SettingsActivity).joinToString("\n")
            textSize = 13f; setTextColor(Tokens.TEXT_MUTED); typeface = android.graphics.Typeface.MONOSPACE
            setTextIsSelectable(true)
        })
        setContentView(ScrollView(this).apply { addView(col) })
    }

    // The canvas releases its hold when Settings covers it; without a holder here the connection would stop, the
    // discovery would end and every address typed below would dial nothing (OnboardingActivity does the same).
    override fun onStart() {
        super.onStart()
        conn.acquire(HOLDER, Identity.ROLE_INK)
    }

    override fun onStop() {
        conn.release(HOLDER)
        super.onStop()
    }

    private fun toggle(text: String, checked: Boolean, onChange: (Boolean) -> Unit): Switch = Switch(this).apply {
        this.text = text
        textSize = 16f
        setTextColor(Tokens.INK_BLACK)
        isChecked = checked
        val d = resources.displayMetrics.density
        setPadding(0, (12 * d).toInt(), 0, (12 * d).toInt())
        setOnCheckedChangeListener { _, v -> onChange(v) }
    }

    private fun label(text: String): TextView = TextView(this).apply {
        this.text = text; textSize = 16f; setTextColor(Tokens.INK_BLACK)
        val d = resources.displayMetrics.density
        setPadding(0, (20 * d).toInt(), 0, (6 * d).toInt())
    }

    private fun button(text: String, onTap: () -> Unit): PillView = PillView(this).apply {
        this.text = text
        this.onTap = onTap
        val d = resources.displayMetrics.density
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = (10 * d).toInt() }
    }
}
