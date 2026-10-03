package com.twelve.daylight.ink.prefs

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import com.twelve.daylight.ink.net.Identity
import java.util.UUID

/** SharedPreferences keys of SPEC 11 (tablet side). The client id is generated once and shared by `ink` and `overlay`. */
class Prefs(context: Context) {
    companion object {
        const val FILE = "daylight-ink"
        const val KEY_CLIENT_ID = "clientId"
        const val KEY_DEVICE_NAME = "deviceName"
        const val KEY_MANUAL_HOST = "manualHost"
        const val KEY_FRONT_BUFFER = "frontBuffer"
        const val KEY_UNBUFFERED_INPUT = "unbufferedInput"
        const val KEY_SEND_PER_EVENT = "sendPerEvent"
        const val KEY_PILLS_AT_BOOT = "pillsAtBoot"
        const val KEY_PILLS_POSITION = "pillsPosition"
        const val KEY_FLAG_HINT_DISMISSED = "flagHintDismissed"
        const val KEY_ONBOARDING_DONE = "onboardingDone"
        const val KEY_FACT_PRESSURE_RAW = "fact.pressureRaw"
        const val KEY_FACT_ACTION_BUTTON = "fact.actionButton"
        const val KEY_FACT_FRONT_BUFFER_OK = "fact.frontBufferOk"
    }

    private val p: SharedPreferences = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    val clientId: String
        get() {
            p.getString(KEY_CLIENT_ID, null)?.let { return it }
            val id = UUID.randomUUID().toString()
            p.edit().putString(KEY_CLIENT_ID, id).apply()
            return id
        }

    var deviceName: String
        get() = p.getString(KEY_DEVICE_NAME, null)?.takeIf { it.isNotBlank() } ?: Identity.defaultLabel(Build.MODEL)
        set(v) = p.edit().putString(KEY_DEVICE_NAME, v).apply()

    var manualHost: String?
        get() = p.getString(KEY_MANUAL_HOST, null)?.takeIf { it.isNotBlank() }
        set(v) = p.edit().putString(KEY_MANUAL_HOST, v?.trim()?.takeIf { it.isNotEmpty() }).apply()

    var frontBuffer: Boolean
        get() = p.getBoolean(KEY_FRONT_BUFFER, true)
        set(v) = p.edit().putBoolean(KEY_FRONT_BUFFER, v).apply()

    var unbufferedInput: Boolean
        get() = p.getBoolean(KEY_UNBUFFERED_INPUT, true)
        set(v) = p.edit().putBoolean(KEY_UNBUFFERED_INPUT, v).apply()

    var sendPerEvent: Boolean
        get() = p.getBoolean(KEY_SEND_PER_EVENT, false)
        set(v) = p.edit().putBoolean(KEY_SEND_PER_EVENT, v).apply()

    var pillsAtBoot: Boolean
        get() = p.getBoolean(KEY_PILLS_AT_BOOT, false)
        set(v) = p.edit().putBoolean(KEY_PILLS_AT_BOOT, v).apply()

    /** "top" or "bottom" (SPEC 11 `mirrorPillsPosition`, sent by the Mac as `--es pills`). */
    var pillsPosition: String
        get() = p.getString(KEY_PILLS_POSITION, "top") ?: "top"
        set(v) = p.edit().putString(KEY_PILLS_POSITION, if (v == "bottom") "bottom" else "top").apply()

    var flagHintDismissed: Boolean
        get() = p.getBoolean(KEY_FLAG_HINT_DISMISSED, false)
        set(v) = p.edit().putBoolean(KEY_FLAG_HINT_DISMISSED, v).apply()

    var onboardingDone: Boolean
        get() = p.getBoolean(KEY_ONBOARDING_DONE, false)
        set(v) = p.edit().putBoolean(KEY_ONBOARDING_DONE, v).apply()

    /** Device facts remembered for the Settings screen (LOOSE_ENDS D3, D4, D14). */
    var factPressureRaw: String?
        get() = p.getString(KEY_FACT_PRESSURE_RAW, null)
        set(v) = p.edit().putString(KEY_FACT_PRESSURE_RAW, v).apply()
    var factActionButton: String?
        get() = p.getString(KEY_FACT_ACTION_BUTTON, null)
        set(v) = p.edit().putString(KEY_FACT_ACTION_BUTTON, v).apply()
    var factFrontBufferOk: String?
        get() = p.getString(KEY_FACT_FRONT_BUFFER_OK, null)
        set(v) = p.edit().putString(KEY_FACT_FRONT_BUFFER_OK, v).apply()

    fun forgetMac() {
        p.edit().remove(KEY_MANUAL_HOST).apply()
    }
}
