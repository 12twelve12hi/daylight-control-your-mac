package com.twelve.daylight.ink.mirror

import com.twelve.daylight.ink.protocol.MirrorControl
import com.twelve.daylight.ink.protocol.MirrorParams
import com.twelve.daylight.ink.protocol.MirrorStatusFields

/** MIRROR_STATUS `state` values, exactly PROTOCOL 14.3. */
enum class MirrorState(val code: Int) {
    IDLE(0),
    CONSENT_NEEDED(1),
    STARTING(2),
    STREAMING(3),
    PAUSED(4),
    CONSENT_DENIED(5),
    ENCODER_UNAVAILABLE(6),
    PROJECTION_ENDED(7),
    UNSUPPORTED(8),
}

/** What the encoder is configured with: the Mac's START parameters after the thermal rule. */
data class EncoderParams(val maxSize: Int, val bitrateBps: Int, val maxFps: Int, val keyIntervalSeconds: Int)

/** What [MirrorSession] asks the Android glue to do, in order. */
sealed class MirrorEffect {
    /** The app is on screen: open the consent activity now. */
    object RequestConsent : MirrorEffect()
    /** The app is in the background: post "Your Mac wants to mirror this screen. Tap to allow." */
    object ShowConsentNotification : MirrorEffect()
    object CancelConsentNotification : MirrorEffect()
    /** (Re)start the encoder: stop any running one first, then a new MIRROR_HELLO and session packet follow. */
    data class StartEncoder(val params: EncoderParams) : MirrorEffect()
    object StopEncoder : MirrorEffect()
    /** Stop the MediaProjection, release the virtual display, leave the foreground. */
    object ReleaseProjection : MirrorEffect()
    object RequestSyncFrame : MirrorEffect()
    /** Send MIRROR_STATUS now (built with [MirrorSession.report]). */
    object SendStatus : MirrorEffect()
}

/**
 * The tablet side of the Wi-Fi mirror transport (PROTOCOL 14) as a pure state machine: no Android, no threads. The
 * glue feeds it the Mac's MIRROR_CONTROL, the consent result, the projection and encoder callbacks, the connection
 * edges and the thermal and battery saver changes, and performs the returned [MirrorEffect]s in order.
 *
 * Status cadence (PROTOCOL 14.3): once after every HANDSHAKE_ACK status 0, on every change of state or flags, and at
 * 1 Hz ([tick]) while STREAMING or PAUSED; never while the connection is not allowed.
 */
class MirrorSession(
    /** False when this device has no H.264 encoder (state UNSUPPORTED for the whole process). */
    private val capable: Boolean,
    private val nowMs: () -> Long,
) {
    companion object {
        const val STATUS_PERIOD_MS = 1000L
        /** `PowerManager.THERMAL_STATUS_SEVERE`; at or above it the frame rate cap is halved (flag bit1). */
        const val THERMAL_SEVERE = 3

        const val FLAG_PROJECTION_HELD = 1
        const val FLAG_THERMAL_REDUCED = 2
        const val FLAG_POWER_SAVE = 4
        const val FLAG_BACKPRESSURE = 8
    }

    var state: MirrorState = if (capable) MirrorState.IDLE else MirrorState.UNSUPPORTED
        private set
    var projectionHeld = false
        private set
    var connected = false
        private set
    /** The parameters of the last START (defaults until the Mac sends one). */
    var params: MirrorParams = MirrorParams()
        private set
    var thermalReduced = false
        private set
    var powerSave = false
        private set
    var uiVisible = false
        private set
    /** Encoder output size while STREAMING, else 0. */
    var width = 0
        private set
    var height = 0
        private set
    /** A START arrived without a projection: stream as soon as consent is granted. */
    var startPending = false
        private set
    /**
     * The Mac's last command on this connection was START (cleared by STOP, RELEASE and a lost connection). The Mac
     * sends START once per peer, so a consent the owner grants later (after a Cancel or a Stop, from "Share screen
     * with your Mac") still streams at once (PROTOCOL 14.4: START on a tablet that holds a projection resumes).
     */
    var macWantsStream = false
        private set
    /**
     * Bumped by every StartEncoder, StopEncoder and ReleaseProjection effect. The encoder's results carry the
     * generation of the start that produced them; [encoderStarted] and [encoderFailed] ignore an older one, and the
     * glue sends no MIRROR_HELLO for a start whose generation is no longer this one.
     */
    var encoderGen = 0
        private set
    private var lastStatusMs = Long.MIN_VALUE / 2

    private val encoderRunning: Boolean get() = state == MirrorState.STARTING || state == MirrorState.STREAMING

    val flags: Int
        get() = (if (projectionHeld) FLAG_PROJECTION_HELD else 0) or
            (if (thermalReduced) FLAG_THERMAL_REDUCED else 0) or
            (if (powerSave) FLAG_POWER_SAVE else 0)

    /** The encoder parameters for the current START and thermal state: SEVERE or above halves the frame rate cap. */
    fun encoderParams(): EncoderParams {
        val fps = if (thermalReduced) (params.maxFps / 2).coerceAtLeast(1) else params.maxFps
        return EncoderParams(params.maxSize, params.bitrateBps, fps, params.keyIntervalSeconds)
    }

    /** MIRROR_STATUS fields; [fpsX10] and [sentBps] come from [MirrorStats], [backpressure] from [MirrorBackpressure]. */
    fun report(fpsX10: Int, sentBps: Long, backpressure: Boolean): MirrorStatusFields {
        val streaming = state == MirrorState.STREAMING
        return MirrorStatusFields(
            state = state.code,
            flags = flags or (if (backpressure) FLAG_BACKPRESSURE else 0),
            fpsX10 = if (streaming) fpsX10 else 0,
            width = if (streaming) width else 0,
            height = if (streaming) height else 0,
            bitrateBps = params.bitrateBps.toLong(),
            sentBps = if (streaming) sentBps else 0L,
        )
    }

    // ---- connection ----

    /** HANDSHAKE_ACK status 0 on a connection: announce the capability (PROTOCOL 14.3). */
    fun connectionAllowed(): List<MirrorEffect> {
        connected = true
        return listOf(statusNow())
    }

    /**
     * The socket closed or left LIVE. The stream cannot continue on another socket (a new MIRROR_HELLO must start it),
     * so a running encoder stops; a held projection is kept, so the Mac's next START needs no new consent.
     */
    fun connectionLost(): List<MirrorEffect> {
        connected = false
        macWantsStream = false
        val out = ArrayList<MirrorEffect>()
        if (encoderRunning) {
            encoderEffect(MirrorEffect.StopEncoder, out)
            setState(if (projectionHeld) MirrorState.PAUSED else MirrorState.IDLE, out)
        }
        return out
    }

    // ---- the Mac ----

    fun control(c: MirrorControl): List<MirrorEffect> = when (c.command) {
        MirrorControl.START -> start(c.params())
        MirrorControl.STOP -> stop()
        MirrorControl.REQUEST_KEY_FRAME -> if (state == MirrorState.STREAMING) listOf(MirrorEffect.RequestSyncFrame) else emptyList()
        MirrorControl.RELEASE -> release()
        else -> emptyList()                    // an unknown command is ignored like an unknown opcode
    }

    private fun start(p: MirrorParams): List<MirrorEffect> {
        val out = ArrayList<MirrorEffect>()
        if (!capable) {
            out.add(statusNow())               // repeat UNSUPPORTED so the Mac stops asking
            return out
        }
        val changed = p != params
        params = p
        macWantsStream = true
        when {
            projectionHeld && state == MirrorState.STREAMING && !changed -> {}
            projectionHeld && state == MirrorState.STARTING && !changed -> {}
            projectionHeld -> {
                if (!connected) return out
                encoderEffect(MirrorEffect.StartEncoder(encoderParams()), out)
                setState(MirrorState.STARTING, out)
            }
            else -> {
                startPending = true
                out.add(if (uiVisible) MirrorEffect.RequestConsent else MirrorEffect.ShowConsentNotification)
                setState(MirrorState.CONSENT_NEEDED, out)
            }
        }
        return out
    }

    private fun stop(): List<MirrorEffect> {
        val out = ArrayList<MirrorEffect>()
        startPending = false
        macWantsStream = false
        when {
            encoderRunning -> {
                encoderEffect(MirrorEffect.StopEncoder, out)
                setState(MirrorState.PAUSED, out)
            }
            state == MirrorState.CONSENT_NEEDED -> {
                out.add(MirrorEffect.CancelConsentNotification)
                setState(MirrorState.IDLE, out)
            }
        }
        return out
    }

    private fun release(): List<MirrorEffect> {
        val out = ArrayList<MirrorEffect>()
        startPending = false
        macWantsStream = false
        if (encoderRunning) encoderEffect(MirrorEffect.StopEncoder, out)
        if (state == MirrorState.CONSENT_NEEDED) out.add(MirrorEffect.CancelConsentNotification)
        val wasHeld = projectionHeld
        if (projectionHeld) {
            projectionHeld = false
            encoderEffect(MirrorEffect.ReleaseProjection, out)
        }
        width = 0; height = 0
        if (capable) setState(MirrorState.IDLE, out, flagsChanged = wasHeld)
        return out
    }

    // ---- the owner on the tablet ----

    /** The owner tapped "Share screen with your Mac" in the app (no START needed): ask for consent now. */
    fun shareRequested(): List<MirrorEffect> {
        if (!capable || projectionHeld) return emptyList()
        val out = ArrayList<MirrorEffect>()
        out.add(MirrorEffect.RequestConsent)
        setState(MirrorState.CONSENT_NEEDED, out)
        return out
    }

    /**
     * The projection was obtained (consent granted, foreground service started, `getMediaProjection` returned). With
     * a START pending, or the Mac's START still standing after a Cancel or a Stop ([macWantsStream]), on an allowed
     * connection the stream starts; otherwise the projection waits (PAUSED).
     */
    fun consentGranted(): List<MirrorEffect> {
        val out = ArrayList<MirrorEffect>()
        out.add(MirrorEffect.CancelConsentNotification)
        val wasHeld = projectionHeld
        projectionHeld = true
        if ((startPending || macWantsStream) && connected && capable) {
            startPending = false
            encoderEffect(MirrorEffect.StartEncoder(encoderParams()), out)
            setState(MirrorState.STARTING, out, flagsChanged = !wasHeld)
        } else {
            setState(MirrorState.PAUSED, out, flagsChanged = !wasHeld)
        }
        return out
    }

    /**
     * Whether a consent grant may be turned into a projection. While one is held ([projectionObtained]: the glue
     * already has its MediaProjection) a second grant, from a double tap that opened two dialogs, is ignored:
     * `getMediaProjection` for it makes the system stop the held projection, and that projection's late onStop would
     * end the share. Asking again stays possible whenever no projection is held ([shareRequested] while
     * CONSENT_NEEDED opens a new dialog, in case the first one was lost).
     */
    fun grantUsable(projectionObtained: Boolean): Boolean = !projectionHeld && !projectionObtained

    fun consentDenied(): List<MirrorEffect> {
        val out = ArrayList<MirrorEffect>()
        startPending = false
        out.add(MirrorEffect.CancelConsentNotification)
        if (!projectionHeld) setState(MirrorState.CONSENT_DENIED, out)
        return out
    }

    /** The notification's Stop or the in-app Stop: end the projection here (PROJECTION_ENDED). */
    fun userStopped(): List<MirrorEffect> = ended(release = true)

    /** `MediaProjection.Callback.onStop`: the system, its cast control or the lock screen ended the projection. */
    fun projectionStopped(): List<MirrorEffect> = if (projectionHeld) ended(release = true) else emptyList()

    private fun ended(release: Boolean): List<MirrorEffect> {
        val out = ArrayList<MirrorEffect>()
        startPending = false
        if (encoderRunning) encoderEffect(MirrorEffect.StopEncoder, out)
        val wasHeld = projectionHeld
        projectionHeld = false
        if (release && wasHeld) encoderEffect(MirrorEffect.ReleaseProjection, out)
        width = 0; height = 0
        if (wasHeld || encoderRunning || state == MirrorState.CONSENT_NEEDED) {
            if (state == MirrorState.CONSENT_NEEDED) out.add(MirrorEffect.CancelConsentNotification)
            setState(MirrorState.PROJECTION_ENDED, out, flagsChanged = wasHeld)
        }
        return out
    }

    fun setUiVisible(visible: Boolean) { uiVisible = visible }

    // ---- the encoder ----

    /** The encoder of start [gen] is configured at this size (its MIRROR_HELLO is out). An older start's is ignored. */
    fun encoderStarted(gen: Int, width: Int, height: Int): List<MirrorEffect> {
        if (gen != encoderGen || state != MirrorState.STARTING) return emptyList()
        this.width = width
        this.height = height
        val out = ArrayList<MirrorEffect>()
        setState(MirrorState.STREAMING, out)
        return out
    }

    /**
     * No H.264 encoder, or configure or start failed at every fallback size, for start [gen]. The projection stays
     * held. A failure of an older start (a restart for rotation or the thermal cap is already on its way) is ignored.
     */
    fun encoderFailed(gen: Int): List<MirrorEffect> {
        if (gen != encoderGen || !encoderRunning) return emptyList()
        width = 0; height = 0
        val out = ArrayList<MirrorEffect>()
        encoderEffect(MirrorEffect.StopEncoder, out)
        setState(MirrorState.ENCODER_UNAVAILABLE, out)
        return out
    }

    /** The display size changed (rotation): restart the encoder so a new HELLO and session packet carry the size. */
    fun displaySizeChanged(): List<MirrorEffect> {
        if (!encoderRunning || !connected) return emptyList()
        val out = ArrayList<MirrorEffect>()
        encoderEffect(MirrorEffect.StartEncoder(encoderParams()), out)
        setState(MirrorState.STARTING, out)
        return out
    }

    // ---- the device ----

    /** `PowerManager.OnThermalStatusChangedListener`: SEVERE (3) or above halves the frame rate cap and sets bit1. */
    fun thermalStatusChanged(status: Int): List<MirrorEffect> {
        val reduced = status >= THERMAL_SEVERE
        if (reduced == thermalReduced) return emptyList()
        thermalReduced = reduced
        val out = ArrayList<MirrorEffect>()
        if (encoderRunning && connected) {
            encoderEffect(MirrorEffect.StartEncoder(encoderParams()), out)
            setState(MirrorState.STARTING, out, flagsChanged = true)
        } else if (connected) {
            out.add(statusNow())
        }
        return out
    }

    /** `PowerManager.isPowerSaveMode` changed: flag bit2 only (the encoder settings stay). */
    fun powerSaveChanged(on: Boolean): List<MirrorEffect> {
        if (on == powerSave) return emptyList()
        powerSave = on
        return if (connected) listOf(statusNow()) else emptyList()
    }

    /** Call about every 250 ms (or at least once a second): the 1 Hz report while STREAMING or PAUSED. */
    fun tick(): List<MirrorEffect> {
        if (!connected) return emptyList()
        if (state != MirrorState.STREAMING && state != MirrorState.PAUSED) return emptyList()
        if (nowMs() - lastStatusMs < STATUS_PERIOD_MS) return emptyList()
        return listOf(statusNow())
    }

    private fun encoderEffect(e: MirrorEffect, out: MutableList<MirrorEffect>) {
        encoderGen++
        out.add(e)
    }

    private fun statusNow(): MirrorEffect {
        lastStatusMs = nowMs()
        return MirrorEffect.SendStatus
    }

    private fun setState(s: MirrorState, out: MutableList<MirrorEffect>, flagsChanged: Boolean = false) {
        val changed = s != state || flagsChanged
        state = s
        if (changed && connected) out.add(statusNow())
    }
}
