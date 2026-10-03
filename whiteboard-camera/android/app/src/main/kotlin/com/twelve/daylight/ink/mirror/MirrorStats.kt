package com.twelve.daylight.ink.mirror

/**
 * MIRROR_STATUS `fps_x10` and `sent_bps` (PROTOCOL 14.3) over the last second: access units sent times 10, and
 * MIRROR_PACKET bytes sent times 8. A packet counts while `now - t < 1000`. Thread safe (the drain thread records,
 * the main thread reports).
 */
class MirrorStats(private val windowMs: Long = 1000L) {
    private val times = ArrayDeque<Long>()
    private val sizes = ArrayDeque<Long>()
    private val units = ArrayDeque<Boolean>()
    private var bytesInWindow = 0L
    private var unitsInWindow = 0

    /** One MIRROR_PACKET of [bytes] sent at [nowMs]; [accessUnit] is false for session and config packets. */
    @Synchronized
    fun record(nowMs: Long, bytes: Long, accessUnit: Boolean) {
        expire(nowMs)
        times.addLast(nowMs); sizes.addLast(bytes); units.addLast(accessUnit)
        bytesInWindow += bytes
        if (accessUnit) unitsInWindow++
    }

    @Synchronized
    fun fpsX10(nowMs: Long): Int {
        expire(nowMs)
        return (unitsInWindow * 10L * 1000L / windowMs).toInt()
    }

    @Synchronized
    fun sentBps(nowMs: Long): Long {
        expire(nowMs)
        return bytesInWindow * 8L * 1000L / windowMs
    }

    @Synchronized
    fun reset() {
        times.clear(); sizes.clear(); units.clear()
        bytesInWindow = 0; unitsInWindow = 0
    }

    private fun expire(nowMs: Long) {
        while (times.isNotEmpty() && nowMs - times.first() >= windowMs) {
            times.removeFirst()
            bytesInWindow -= sizes.removeFirst()
            if (units.removeFirst()) unitsInWindow--
        }
    }
}
