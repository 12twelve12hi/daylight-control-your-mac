package com.twelve.daylight.ink.ui

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.twelve.daylight.ink.net.Identity
import com.twelve.daylight.ink.net.InkConnection
import com.twelve.daylight.ink.net.Phase
import com.twelve.daylight.ink.prefs.Prefs
import com.twelve.daylight.ink.protocol.StateReport

/**
 * First run (SPEC 9.3 step 2, 13.3 rows 29 and 30): find the Mac (with a manual address field), allow display over
 * other apps with the Android 13 wording, allow notifications. Skippable; everything can be redone from Settings.
 */
class OnboardingActivity : Activity(), InkConnection.Listener {
    companion object { const val HOLDER = "onboarding"; const val REQ_NOTIFICATIONS = 1 }

    private lateinit var prefs: Prefs
    private lateinit var conn: InkConnection
    private lateinit var status: TextView
    private lateinit var overlayStatus: TextView
    private lateinit var overlayButton: PillView
    private lateinit var notifStatus: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        EdgeToEdge.apply(this)
        prefs = Prefs(this)
        conn = InkConnection.get(this)
        val d = resources.displayMetrics.density
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Tokens.PAPER_BG)
            setPadding((28 * d).toInt(), (64 * d).toInt(), (28 * d).toInt(), (48 * d).toInt())
        }
        col.addView(title(Texts.ONBOARDING_TITLE, 28f))

        col.addView(title("1. Your Mac", 20f))
        status = body(Texts.ONBOARDING_FIND)
        col.addView(status)
        val host = EditText(this).apply {
            hint = Texts.ONBOARDING_HOST_HINT
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            setText(prefs.manualHost ?: "")
            setTextColor(Tokens.INK_BLACK); setHintTextColor(Tokens.TEXT_MUTED)
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
                override fun afterTextChanged(s: Editable?) { conn.setManualHost(s?.toString(), remember = true) }
            })
        }
        col.addView(host)

        col.addView(title("2. ${Texts.ONBOARDING_OVERLAY_TITLE}", 20f))
        col.addView(body(Texts.ONBOARDING_OVERLAY_BODY))
        overlayStatus = body("")
        col.addView(overlayStatus)
        overlayButton = button(Texts.ONBOARDING_OVERLAY_BUTTON) { openOverlaySettings() }
        col.addView(overlayButton)

        col.addView(title("3. ${Texts.ONBOARDING_NOTIFICATIONS_TITLE}", 20f))
        col.addView(body(Texts.ONBOARDING_NOTIFICATIONS_BODY))
        notifStatus = body("")
        col.addView(notifStatus)
        col.addView(button(Texts.ONBOARDING_NOTIFICATIONS_BUTTON) { requestNotifications() })

        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.END; setPadding(0, (32 * d).toInt(), 0, 0) }
        row.addView(button(Texts.ONBOARDING_SKIP) { finishOnboarding() })
        row.addView(button(Texts.ONBOARDING_DONE) { finishOnboarding() }.apply { fill = Tokens.INK_BLACK; textColor = Tokens.PAPER_BG })
        col.addView(row)

        setContentView(ScrollView(this).apply { addView(col) })
    }

    override fun onStart() {
        super.onStart()
        conn.acquire(HOLDER, Identity.ROLE_INK)
        conn.addListener(this)
        refresh()
    }

    override fun onResume() { super.onResume(); refresh() }

    override fun onStop() {
        conn.removeListener(this)
        conn.release(HOLDER)
        super.onStop()
    }

    override fun onPhase(phase: Phase) {
        status.text = when (phase) {
            Phase.LIVE -> "Connected to ${conn.currentUrl ?: "your Mac"}"
            Phase.PENDING -> Texts.LOOK_AT_MAC
            Phase.DENIED -> Texts.NOT_ALLOWED
            Phase.INCOMPATIBLE -> Texts.UPDATE_MAC
            else -> Texts.ONBOARDING_FIND
        }
    }

    override fun onState(state: StateReport) {}

    private fun refresh() {
        val overlay = Settings.canDrawOverlays(this)
        overlayStatus.text = if (overlay) Texts.ONBOARDING_OVERLAY_DONE else Texts.PILLS_NEED_PERMISSION
        overlayButton.isEnabled = !overlay
        overlayButton.invalidate()
        val notif = Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        notifStatus.text = if (notif) "Allowed" else "Not allowed yet"
    }

    private fun openOverlaySettings() {
        try {
            // The package URI is ignored from Android 11 on: the owner picks Daylight Ink from the list (research 4.1).
            startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION))
        } catch (e: ActivityNotFoundException) {
            overlayStatus.text = Texts.ONBOARDING_OVERLAY_UNAVAILABLE
        }
    }

    private fun requestNotifications() {
        if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFICATIONS)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        refresh()
    }

    private fun finishOnboarding() {
        prefs.onboardingDone = true
        finish()
    }

    private fun title(text: String, sp: Float): TextView = TextView(this).apply {
        this.text = text; textSize = sp; setTextColor(Tokens.INK_BLACK)
        val d = resources.displayMetrics.density
        setPadding(0, (20 * d).toInt(), 0, (8 * d).toInt())
    }

    private fun body(text: String): TextView = TextView(this).apply {
        this.text = text; textSize = 16f; setTextColor(Tokens.INK_SUBTLE)
        val d = resources.displayMetrics.density
        setPadding(0, (4 * d).toInt(), 0, (8 * d).toInt())
    }

    private fun button(text: String, onTap: () -> Unit): PillView = PillView(this).apply {
        this.text = text
        this.onTap = onTap
        val d = resources.displayMetrics.density
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = (8 * d).toInt(); marginEnd = (12 * d).toInt()
        }
    }
}
