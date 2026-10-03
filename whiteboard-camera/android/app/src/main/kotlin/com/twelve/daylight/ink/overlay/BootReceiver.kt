package com.twelve.daylight.ink.overlay

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.util.Log
import com.twelve.daylight.ink.prefs.Prefs

/** Optional (LOOSE_ENDS A12): start the pills at boot when the owner switched `pillsAtBoot` on. Default off. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val prefs = Prefs(context)
        if (!prefs.pillsAtBoot) return
        if (!Settings.canDrawOverlays(context)) { Log.w(OverlayService.TAG, "boot: pills wanted but overlay permission missing"); return }
        runCatching {
            context.startForegroundService(Intent(context, OverlayService::class.java).putExtra(OverlayService.EXTRA_PILLS, prefs.pillsPosition))
        }.onFailure { Log.w(OverlayService.TAG, "boot start failed: $it") }
    }
}
