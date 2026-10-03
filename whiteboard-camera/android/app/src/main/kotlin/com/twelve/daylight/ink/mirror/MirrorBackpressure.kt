package com.twelve.daylight.ink.mirror

/**
 * PROTOCOL 14.2 backpressure, pure: before a non-key, non-config packet the tablet looks at the OkHttp
 * `WebSocket.queueSize()`. Above [HIGH_BYTES] (1 MiB) queued the packet is dropped and counted, and the next
 * MIRROR_STATUS carries flags bit3; once the queue has drained below [LOW_BYTES] (256 KiB) one sync frame is requested
 * so the Mac's decoder recovers from the gap. After any drop (this rule or [markGap] for an access unit above the
 * payload cap) every later delta frame is dropped too until a key frame is admitted: a delta predicts from the frame
 * before it, so sending one after a gap would decode against the wrong reference until the next key frame. Key frames
 * and codec config are always sent. Thread safe: the drain thread admits packets, the main thread takes the report
 * flag.
 */
class MirrorBackpressure {
    companion object {
        const val HIGH_BYTES: Long = 1L shl 20
        const val LOW_BYTES: Long = 256L shl 10
    }

    /** Packets dropped since the stream object was created. */
    @get:Synchronized
    var dropped: Long = 0
        private set
    private var awaitingDrain = false
    private var droppedSinceReport = false
    /** A packet was dropped since the last key frame: deltas are dropped until the next one. */
    private var dropUntilKey = false

    /** True when the packet may be sent; false when it is dropped (and counted). */
    @Synchronized
    fun admit(queuedBytes: Long, keyOrConfig: Boolean): Boolean {
        if (keyOrConfig) {
            dropUntilKey = false
            return true
        }
        if (!dropUntilKey && queuedBytes <= HIGH_BYTES) return true
        dropped++
        droppedSinceReport = true
        awaitingDrain = true
        dropUntilKey = true
        return false
    }

    /**
     * An access unit was dropped outside [admit] (above the 1 MiB payload cap; the caller requests the sync frame at
     * once): the deltas that follow are dropped until a key frame.
     */
    @Synchronized
    fun markGap() {
        dropUntilKey = true
    }

    /** Call before each packet: true exactly once after drops, when the queue first reads below 256 KiB. */
    @Synchronized
    fun syncFrameWanted(queuedBytes: Long): Boolean {
        if (awaitingDrain && queuedBytes < LOW_BYTES) {
            awaitingDrain = false
            return true
        }
        return false
    }

    /** MIRROR_STATUS flags bit3: packets were dropped since the previous report. Reading clears it. */
    @Synchronized
    fun takeReportFlag(): Boolean {
        val f = droppedSinceReport
        droppedSinceReport = false
        return f
    }

    @Synchronized
    fun reset() {
        awaitingDrain = false
        droppedSinceReport = false
        dropUntilKey = false
    }
}
