package com.twelve.daylight.ink.ui

/**
 * Every owner-facing sentence of the tablet app in one place (SPEC 10 chip texts, SPEC 13.3 rows 29 and 30, the
 * onboarding wording of research-android-ink 4.1). Writing rules: no em-dashes; LivePaper is a transflective LCD.
 */
object Texts {
    const val APP_NAME = "Daylight Ink"

    // Chip (SPEC 10)
    const val LOOKING = "Looking for your Mac"
    const val LOOK_AT_MAC = "Look at your Mac"
    const val NOT_ALLOWED = "Not allowed by the Mac"
    const val UPDATE_MAC = "Update Daylight on your Mac"
    const val CAMERA = "Camera"
    const val LIVE = "LIVE"
    const val RETURNING = "Returning"
    const val KEEP = "KEEP WHITEBOARD"
    fun returningIn(seconds: Int) = "Returning in $seconds"
    fun inkSourceIs(sourceName: String) = "Ink source is $sourceName on the Mac"
    const val SWITCH_SOURCE_HOW = "On the Mac: menu bar > Ink source > Daylight Ink app"

    // Pills (overlay)
    const val PILL_PIN = "Pin"
    const val PILL_KEEP = "KEEP"
    const val PILL_CLEAR = "Clear"

    // Toolbar
    const val TOOL_PEN = "Pen"
    const val TOOL_HIGHLIGHT = "Highlight"
    const val TOOL_ERASE = "Erase"
    const val TOOL_UNDO = "Undo"
    const val TOOL_REDO = "Redo"
    const val TOOL_NEW_PAGE = "New page"
    const val TOOL_CLEAR = "Clear"
    const val TOOL_SETTINGS = "Settings"

    // Onboarding (SPEC 13.3 rows 29 and 30; research-android-ink 4.1 wording for Android 13)
    const val ONBOARDING_TITLE = "Welcome to Daylight Ink"
    const val ONBOARDING_FIND = "Looking for your Mac... Enter its address if this takes long"
    const val ONBOARDING_HOST_HINT = "Mac address, for example 100.64.1.2 or 192.168.1.40"
    const val ONBOARDING_OVERLAY_TITLE = "Allow display over other apps"
    const val ONBOARDING_OVERLAY_BODY = "The Pin and Clear pills float over your note app in mirror mode. In the next screen tap Daylight Ink, switch on Allow display over other apps, then press Back."
    const val ONBOARDING_OVERLAY_BUTTON = "Open the permission screen"
    const val ONBOARDING_OVERLAY_DONE = "Allowed"
    const val ONBOARDING_OVERLAY_UNAVAILABLE = "This screen is not available on this tablet. Over USB the Mac grants it for you."
    const val ONBOARDING_NOTIFICATIONS_TITLE = "Allow notifications"
    const val ONBOARDING_NOTIFICATIONS_BODY = "The pills run as a service with one quiet notification. Without this permission they still work, the notice is just hidden."
    const val ONBOARDING_NOTIFICATIONS_BUTTON = "Allow notifications"
    const val ONBOARDING_SKIP = "Skip"
    const val ONBOARDING_DONE = "Start writing"

    // Settings
    const val SETTINGS_TITLE = "Daylight Ink settings"
    const val SETTING_FRONT_BUFFER = "Front buffer (lowest latency wet ink)"
    const val SETTING_UNBUFFERED = "Unbuffered input"
    const val SETTING_SEND_PER_EVENT = "Send every pen sample at once (A/B against per-frame batching)"
    const val SETTING_PILLS_AT_BOOT = "Start the pills at boot"
    const val SETTING_PILLS_POSITION = "Pills at the bottom instead of the top"
    const val SETTING_MANUAL_HOST = "Mac address (when Bonjour does not find it)"
    const val SETTING_FORGET = "Forget this Mac"
    const val SETTING_PILLS_NOW = "Show the pills now"
    const val SETTING_PILLS_STOP = "Hide the pills"
    const val SETTING_SETUP_AGAIN = "Setup again"
    const val SETTING_FACTS = "This tablet"

    // Screen sharing with the Mac (Wi-Fi mirror transport, PROTOCOL 14)
    const val MIRROR_SECTION = "Share this screen with the Mac over Wi-Fi (no cable, no USB debugging)"
    const val MIRROR_SHARE = "Share screen with your Mac"
    const val MIRROR_STOP = "Stop sharing"
    const val MIRROR_NOTIFICATION_TITLE = "Sharing screen with your Mac"
    const val MIRROR_NOTIFICATION_BODY = "Daylight Camera can show this screen. Tap Stop to end sharing."
    const val MIRROR_NOTIFICATION_STOP = "Stop"
    const val MIRROR_STREAM_CHANNEL = "Screen sharing"
    const val MIRROR_REQUEST_CHANNEL = "Screen sharing requests"
    const val MIRROR_REQUEST_TITLE = "Your Mac wants to mirror this screen. Tap to allow."
    const val MIRROR_REQUEST_BODY = "Android asks before any screen is shared. Stop it any time from the notification."
    fun mirrorState(code: Int): String = when (code) {
        0 -> "Not sharing. Tap Share, then pick Mirror as the ink source on the Mac."
        1 -> "Waiting for you to allow screen sharing"
        2 -> "Starting the picture"
        3 -> "Sharing with your Mac"
        4 -> "Ready. The Mac starts the picture when it needs it"
        5 -> "Screen sharing was not allowed. Tap Share to try again"
        6 -> "This tablet could not start its video encoder"
        7 -> "Sharing stopped on this tablet"
        8 -> "This tablet cannot share its screen"
        else -> "Unknown sharing state"
    }

    // Failure rows the tablet shows itself
    const val PILLS_NEED_PERMISSION = "Allow display over other apps"           // row 29
    const val MDNS_SLOW = ONBOARDING_FIND                                        // row 30

    val INK_SOURCE_NAMES: Map<Int, String> = mapOf(0 to "web", 1 to "Daylight Ink", 2 to "mirror")
    fun inkSourceName(code: Int): String = INK_SOURCE_NAMES[code] ?: "another source"
}
