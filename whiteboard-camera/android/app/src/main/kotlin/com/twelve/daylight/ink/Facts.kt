package com.twelve.daylight.ink

import android.content.Context
import android.os.Build
import android.provider.Settings
import android.util.Log
import com.twelve.daylight.ink.prefs.Prefs

/**
 * Device facts the owner copies into LOOSE_ENDS section D (D2 model and release, D11 Tethering extension version,
 * D15 overlay permission state). Logged once per process under the tag `DaylightInk.facts`; shown in Settings.
 */
object Facts {
    const val TAG = "DaylightInk.facts"
    private var logged = false

    /** Tethering module extension version (research-android-ink 3.1); 0 when the API refuses the question. */
    fun tiramisuExtension(): Int = runCatching {
        android.os.ext.SdkExtensions.getExtensionVersion(Build.VERSION_CODES.TIRAMISU)
    }.getOrDefault(0)

    fun lines(context: Context): List<String> {
        val prefs = Prefs(context)
        val dm = context.resources.displayMetrics
        return listOf(
            "model=${Build.MODEL} manufacturer=${Build.MANUFACTURER} device=${Build.DEVICE}",
            "release=${Build.VERSION.RELEASE} sdk=${Build.VERSION.SDK_INT} tiramisuExt=${tiramisuExtension()}",
            "display=${dm.widthPixels}x${dm.heightPixels} density=${dm.density} dpi=${dm.densityDpi}",
            "canDrawOverlays=${Settings.canDrawOverlays(context)}",
            "pressureRange=${prefs.factPressureRaw ?: "not seen yet"}",
            "sideButton=${prefs.factActionButton ?: "not seen yet"}",
            "frontBuffer=${prefs.factFrontBufferOk ?: "not tried yet"}",
            "mirrorEncoders=${prefs.factMirrorEncoders ?: "not checked yet"}",
            "mirrorEncoder=${prefs.factMirrorEncoder ?: "not streamed yet"}",
            "mirrorStream=${prefs.factMirrorStream ?: "not streamed yet"}",
            "mirrorThermalMax=${prefs.factMirrorThermalMax ?: "not seen yet"}",
            "clientId=${prefs.clientId}",
        )
    }

    fun logOnce(context: Context) {
        if (logged) return
        logged = true
        for (l in lines(context)) Log.i(TAG, l)
    }
}
