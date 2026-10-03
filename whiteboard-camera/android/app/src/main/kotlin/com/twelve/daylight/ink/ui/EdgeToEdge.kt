package com.twelve.daylight.ink.ui

import android.app.Activity
import android.graphics.Color
import android.view.WindowInsetsController
import android.view.WindowManager

/** Platform-only edge to edge for API 30+ (research-android-ink section 5): no AndroidX needed. */
object EdgeToEdge {
    fun apply(activity: Activity) {
        val window = activity.window
        window.setDecorFitsSystemWindows(false)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        window.isStatusBarContrastEnforced = false
        window.isNavigationBarContrastEnforced = false
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val mask = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
        window.insetsController?.setSystemBarsAppearance(mask, mask)
    }
}
