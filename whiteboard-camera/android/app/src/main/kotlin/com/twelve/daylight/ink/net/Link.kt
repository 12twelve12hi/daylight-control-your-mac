package com.twelve.daylight.ink.net

import com.twelve.daylight.ink.ink.PageGeometry
import com.twelve.daylight.ink.protocol.Decoder
import com.twelve.daylight.ink.protocol.Encoder
import com.twelve.daylight.ink.protocol.HandshakeAck
import com.twelve.daylight.ink.protocol.ServerMessage
import com.twelve.daylight.ink.protocol.SolStream
import com.twelve.daylight.ink.protocol.StateReport

/** Connection phase as the chip sees it (SPEC 10, PROTOCOL 6.14 and 8). */
enum class Phase {
    SEARCHING,      // no socket, a dial is scheduled
    CONNECTING,     // socket opening or HANDSHAKE sent, no ACK yet
    PENDING,        // ACK 1: the Mac shows the Allow panel; ink is not sent
    LIVE,           // ACK 0
    DENIED,         // ACK 2: no re-dial until the owner taps the chip
    INCOMPATIBLE,   // ACK 3 or the server did not echo solstream.v1: no re-dial until tapped
}

/** What the state machine asks the platform layer to do. */
interface LinkActions {
    fun dial(url: String, afterMs: Long)
    fun send(frame: ByteArray): Boolean
    /** Close the socket (code and reason are informational; the Mac logs them). */
    fun close(code: Int, reason: String)
    fun phaseChanged(phase: Phase)
    fun stateChanged(state: StateReport)
    fun pong(sequence: Long, rttMs: Long)
}

/**
 * The connection state machine, free of OkHttp and Android: candidates, backoff, the HANDSHAKE and ACK rules of
 * PROTOCOL 8, the subprotocol rule of PROTOCOL 1 and the ink gate (PROTOCOL 9). InkConnection drives it from the
 * main thread.
 */
class Link(
    private val actions: LinkActions,
    private val encoder: Encoder,
    val candidates: Candidates,
    private val backoff: Backoff = Backoff(),
    private val nowMs: () -> Long = { System.currentTimeMillis() },
) {
    var phase: Phase = Phase.SEARCHING
        private set
    var lastState: StateReport? = null
        private set
    /** Uptime stamp of the last STATE, for the chip's local countdown. */
    var lastStateAtMs: Long = 0L
        private set
    var lastAck: HandshakeAck? = null
        private set
    var currentUrl: String? = null
        private set
    var role: String = Identity.ROLE_INK
        private set
    var clientId: String = ""
        private set
    var label: String = "Daylight Ink"
        private set
    var lastRttMs: Long = -1
        private set
    private var pingSequence = 0L
    private var started = false

    /** PROTOCOL 9: ink leaves only after ACK 0; the Mac drops it otherwise (and closes 1008 when denied). */
    val inkAllowed: Boolean get() = phase == Phase.LIVE

    fun configure(role: String, clientId: String, label: String) {
        val roleChanged = role != this.role && started
        this.role = role
        this.clientId = clientId
        this.label = label
        if (roleChanged && (phase == Phase.CONNECTING || phase == Phase.PENDING || phase == Phase.LIVE)) {
            // The role travels in the HANDSHAKE name, so a new role means a new socket.
            actions.close(1000, "role change")
            setPhase(Phase.SEARCHING)
            scheduleDial(0)
        }
    }

    fun start() {
        if (started) return
        started = true
        setPhase(Phase.SEARCHING)
        scheduleDial(0)
    }

    fun stop() {
        started = false
        if (currentUrl != null) actions.close(1000, "stopped")
        currentUrl = null
        lastState = null
        setPhase(Phase.SEARCHING)
    }

    /** The platform layer is about to open `url` (it tells us so a failure can be attributed). */
    fun dialing(url: String) {
        currentUrl = url
        setPhase(Phase.CONNECTING)
    }

    /** Socket open. `echoedSubprotocol` is the server's Sec-WebSocket-Protocol header (null when absent). */
    fun opened(echoedSubprotocol: String?) {
        if (!started) return
        if (echoedSubprotocol != SolStream.SUBPROTOCOL) {
            // PROTOCOL 1: offered and not echoed -> incompatible server; stop retrying.
            actions.close(1002, "no solstream.v1")
            setPhase(Phase.INCOMPATIBLE)
            return
        }
        val name = Identity.handshakeName(role, clientId, label)
        actions.send(encoder.handshake(PageGeometry.CANVAS_WIDTH, PageGeometry.CANVAS_HEIGHT, PageGeometry.DPI, name))
        setPhase(Phase.CONNECTING)
    }

    /** A binary frame from the Mac. */
    fun received(bytes: ByteArray) {
        if (!started) return
        when (val msg = Decoder.decode(bytes)) {
            is ServerMessage.Ack -> ack(msg.ack)
            is ServerMessage.State -> {
                lastState = msg.state
                lastStateAtMs = nowMs()
                actions.stateChanged(msg.state)
            }
            is ServerMessage.Pong -> {
                val rtt = nowMs() - msg.clientTimeUs / 1000L
                lastRttMs = rtt
                actions.pong(msg.sequence, rtt)
            }
            is ServerMessage.Unknown, null -> {}      // PROTOCOL 10: unknown opcodes are ignored
        }
    }

    private fun ack(a: HandshakeAck) {
        lastAck = a
        when (a.status) {
            HandshakeAck.OK -> {
                currentUrl?.let { candidates.reportSuccess(it) }
                backoff.reset()
                setPhase(Phase.LIVE)
            }
            HandshakeAck.PENDING_APPROVAL -> setPhase(Phase.PENDING)
            HandshakeAck.DENIED -> setPhase(Phase.DENIED)
            else -> setPhase(Phase.INCOMPATIBLE)
        }
    }

    /** onClosed or onFailure: re-dial unless the owner must act first. */
    fun closed(failure: Boolean) {
        val url = currentUrl
        currentUrl = null
        lastState = null
        if (!started) return
        if (phase == Phase.DENIED || phase == Phase.INCOMPATIBLE) {
            actions.phaseChanged(phase)   // the chip keeps its text; nothing is scheduled
            return
        }
        val wasLive = phase == Phase.LIVE
        if (url != null && (failure || !wasLive)) candidates.reportFailure(url)
        setPhase(Phase.SEARCHING)
        // A drop after a working session waits one backoff step; a failed candidate moves on to the next one at once
        // (scheduleDial adds the backoff itself when the whole rotation has failed).
        scheduleDial(if (wasLive) backoff.nextDelayMs() else 0L)
    }

    /** `send()` returned false: the queue overflowed or the socket is closing (research 3.2). */
    fun sendFailed() {
        if (currentUrl == null) return
        actions.close(1001, "send failed")
        closed(failure = true)
    }

    /** The owner tapped the chip while denied or incompatible: one more try. */
    fun userRetry() {
        if (!started) return
        if (phase == Phase.DENIED || phase == Phase.INCOMPATIBLE) {
            backoff.reset()
            candidates.resetFailures()
            setPhase(Phase.SEARCHING)
            scheduleDial(0)
        }
    }

    /** A new candidate appeared (Bonjour or a host typed in): dial it now if nothing is connected. */
    fun candidatesChanged() {
        if (!started) return
        if (phase == Phase.SEARCHING) scheduleDial(0)
    }

    /**
     * Application-level PING (PROTOCOL 6.15), every 10 s while the socket is open and the HANDSHAKE was answered: the
     * Mac closes 1002 "handshake expected" on anything that arrives before the HANDSHAKE, so CONNECTING sends nothing.
     */
    fun ping() {
        if (currentUrl == null || !(phase == Phase.PENDING || phase == Phase.LIVE)) return
        pingSequence += 1
        actions.send(encoder.ping(pingSequence, nowMs() * 1000L))
    }

    private fun scheduleDial(afterMs: Long) {
        val url = candidates.next()
        if (candidates.rotationCompleted && afterMs == 0L) {
            actions.dial(url, backoff.nextDelayMs())
        } else {
            actions.dial(url, afterMs)
        }
    }

    private fun setPhase(p: Phase) {
        val changed = p != phase
        phase = p
        if (changed) actions.phaseChanged(p)
    }
}
