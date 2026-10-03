package com.twelve.daylight.ink.net

/** PROTOCOL 7: `name = "<role>;<clientId>;<label>"`, label at most 64 UTF-8 bytes. */
object Identity {
    const val ROLE_INK = "ink"
    const val ROLE_OVERLAY = "overlay"
    const val LABEL_MAX_BYTES = 64

    fun handshakeName(role: String, clientId: String, label: String): String = "$role;$clientId;${clampLabel(label)}"

    /** Cuts on a character boundary so the UTF-8 encoding stays valid; semicolons would break the name, so they go. */
    fun clampLabel(label: String): String {
        var s = label.replace(';', ' ').trim()
        if (s.isEmpty()) s = "Daylight Ink"
        while (s.toByteArray(Charsets.UTF_8).size > LABEL_MAX_BYTES) {
            s = s.substring(0, s.offsetByCodePoints(s.length, -1))
        }
        return s
    }

    /** Default label from the device model, e.g. "Daylight Ink on DC-1". */
    fun defaultLabel(model: String?): String {
        val m = model?.trim().orEmpty()
        return if (m.isEmpty()) "Daylight Ink" else "Daylight Ink on $m"
    }
}
