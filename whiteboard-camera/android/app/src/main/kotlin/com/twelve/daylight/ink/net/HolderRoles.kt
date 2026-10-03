package com.twelve.daylight.ink.net

/**
 * The role the one socket carries for its holders (PROTOCOL 7 and 8): `ink` while any holder is on the canvas side,
 * else `overlay`. A new role means a new socket (the role travels in the HANDSHAKE name), so a running screen share
 * would redial on every app switch. Hence one exception: while the socket is LIVE as `ink`, the screen share
 * ([SCREEN]) holds it and the pills ([PILLS]) do not, the downgrade to `overlay` waits until the share releases the
 * socket or the socket redials for another reason. The upgrade to `ink` is never deferred (ink from an `overlay`
 * socket is never honoured), and with the pills present the downgrade is never deferred (their TOGGLE_PIN,
 * CLEAR_CANVAS and AUTO_ENGAGE_RETURN need `overlay` in every ink source, PROTOCOL 8).
 */
object HolderRoles {
    /** The screen share's holder tag (MirrorController.HOLDER). */
    const val SCREEN = "screen"
    /** The pills' holder tag (OverlayService.HOLDER). */
    const val PILLS = "overlay"

    /** The role the holders ask for, holder tag to role. */
    fun wanted(holders: Map<String, String>): String =
        if (holders.values.any { it == Identity.ROLE_INK }) Identity.ROLE_INK else Identity.ROLE_OVERLAY

    /** The role to configure now, given the socket's [current] role and whether it is [live]. */
    fun role(holders: Map<String, String>, current: String, live: Boolean): String {
        val wanted = wanted(holders)
        val deferDowngrade = wanted == Identity.ROLE_OVERLAY && current == Identity.ROLE_INK && live &&
            SCREEN in holders && PILLS !in holders
        return if (deferDowngrade) Identity.ROLE_INK else wanted
    }
}
