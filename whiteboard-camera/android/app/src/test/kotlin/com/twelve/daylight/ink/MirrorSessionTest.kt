package com.twelve.daylight.ink

import com.twelve.daylight.ink.mirror.EncoderParams
import com.twelve.daylight.ink.mirror.MirrorEffect
import com.twelve.daylight.ink.mirror.MirrorEffect.CancelConsentNotification
import com.twelve.daylight.ink.mirror.MirrorEffect.ReleaseProjection
import com.twelve.daylight.ink.mirror.MirrorEffect.RequestConsent
import com.twelve.daylight.ink.mirror.MirrorEffect.RequestSyncFrame
import com.twelve.daylight.ink.mirror.MirrorEffect.SendStatus
import com.twelve.daylight.ink.mirror.MirrorEffect.ShowConsentNotification
import com.twelve.daylight.ink.mirror.MirrorEffect.StartEncoder
import com.twelve.daylight.ink.mirror.MirrorEffect.StopEncoder
import com.twelve.daylight.ink.mirror.MirrorSession
import com.twelve.daylight.ink.mirror.MirrorState
import com.twelve.daylight.ink.protocol.MirrorControl
import com.twelve.daylight.ink.protocol.MirrorStatusFields
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** PROTOCOL 14.3 (states, flags, cadence) and 14.4 (commands) on the tablet's pure state machine. */
class MirrorSessionTest {
    private var now = 10_000L
    private fun session(capable: Boolean = true) = MirrorSession(capable) { now }

    private fun start(maxSize: Int = 0, bitrate: Long = 0, fps: Int = 0, key: Int = 0) = MirrorControl(MirrorControl.START, maxSize, bitrate, fps, key)
    private val stop = MirrorControl(MirrorControl.STOP, 0, 0, 0, 0)
    private val keyFrame = MirrorControl(MirrorControl.REQUEST_KEY_FRAME, 0, 0, 0, 0)
    private val release = MirrorControl(MirrorControl.RELEASE, 0, 0, 0, 0)
    private val defaults = EncoderParams(1600, 7_000_000, 30, 2)

    /** Allowed connection, projection held, streaming at 1200 x 1600. */
    private fun streaming(): MirrorSession {
        val s = session()
        s.connectionAllowed()
        s.control(start())
        s.consentGranted()
        s.encoderStarted(1200, 1600)
        assertEquals(MirrorState.STREAMING, s.state)
        return s
    }

    @Test
    fun stateCodesAreProtocol143() {
        assertEquals(listOf(0, 1, 2, 3, 4, 5, 6, 7, 8), MirrorState.values().map { it.code })
        assertEquals(listOf("IDLE", "CONSENT_NEEDED", "STARTING", "STREAMING", "PAUSED", "CONSENT_DENIED", "ENCODER_UNAVAILABLE", "PROJECTION_ENDED", "UNSUPPORTED"),
            MirrorState.values().map { it.name })
    }

    @Test
    fun aCapableTabletAnnouncesIdleOnceAfterEveryAllowedConnection() {
        val s = session()
        assertEquals(MirrorState.IDLE, s.state)
        assertEquals(listOf(SendStatus), s.connectionAllowed())
        assertEquals(MirrorStatusFields(0, 0, 0, 0, 0, 7_000_000, 0), s.report(123, 456, false))
        s.connectionLost()
        assertEquals(listOf(SendStatus), s.connectionAllowed())
    }

    @Test
    fun withoutAnEncoderTheTabletAnnouncesUnsupportedAndRepeatsItOnStart() {
        val s = session(capable = false)
        assertEquals(MirrorState.UNSUPPORTED, s.state)
        assertEquals(listOf(SendStatus), s.connectionAllowed())
        assertEquals(8, s.report(0, 0, false).state)
        assertEquals(listOf(SendStatus), s.control(start()))
        assertEquals(MirrorState.UNSUPPORTED, s.state)
        assertEquals(emptyList<MirrorEffect>(), s.shareRequested())
    }

    @Test
    fun startWithoutAProjectionInTheBackgroundPostsTheConsentNotification() {
        val s = session()
        s.connectionAllowed()
        assertEquals(listOf(ShowConsentNotification, SendStatus), s.control(start()))
        assertEquals(MirrorState.CONSENT_NEEDED, s.state)
        assertTrue(s.startPending)
    }

    @Test
    fun startWithoutAProjectionWhileTheAppIsOnScreenOpensTheConsentActivity() {
        val s = session()
        s.setUiVisible(true)
        s.connectionAllowed()
        assertEquals(listOf(RequestConsent, SendStatus), s.control(start()))
        assertEquals(MirrorState.CONSENT_NEEDED, s.state)
    }

    @Test
    fun consentGrantedWithAPendingStartStartsTheEncoderThenStreams() {
        val s = session()
        s.connectionAllowed()
        s.control(start(maxSize = 1024, bitrate = 4_000_000, fps = 20, key = 1000))
        assertEquals(listOf(CancelConsentNotification, StartEncoder(EncoderParams(1024, 4_000_000, 20, 1)), SendStatus), s.consentGranted())
        assertEquals(MirrorState.STARTING, s.state)
        assertTrue(s.projectionHeld)
        assertFalse(s.startPending)
        assertEquals(listOf(SendStatus), s.encoderStarted(768, 1024))
        assertEquals(MirrorState.STREAMING, s.state)
        assertEquals(MirrorStatusFields(3, 1, 300, 768, 1024, 4_000_000, 6_543_210), s.report(300, 6_543_210, false))
    }

    @Test
    fun consentGrantedWithoutAStartWaitsPaused() {
        val s = session()
        s.connectionAllowed()
        s.setUiVisible(true)
        assertEquals(listOf(RequestConsent, SendStatus), s.shareRequested())
        assertEquals(MirrorState.CONSENT_NEEDED, s.state)
        assertEquals(listOf(CancelConsentNotification, SendStatus), s.consentGranted())
        assertEquals(MirrorState.PAUSED, s.state)
        assertEquals(1, s.report(0, 0, false).flags)
        // The Mac's START now resumes at once: no consent.
        assertEquals(listOf(StartEncoder(defaults), SendStatus), s.control(start()))
        assertEquals(MirrorState.STARTING, s.state)
    }

    @Test
    fun consentGrantedWhileDisconnectedWaitsPausedEvenWithAPendingStart() {
        val s = session()
        s.connectionAllowed()
        s.control(start())
        s.connectionLost()
        assertEquals(listOf(CancelConsentNotification), s.consentGranted())
        assertEquals(MirrorState.PAUSED, s.state)
    }

    @Test
    fun consentDeniedReportsConsentDenied() {
        val s = session()
        s.connectionAllowed()
        s.control(start())
        assertEquals(listOf(CancelConsentNotification, SendStatus), s.consentDenied())
        assertEquals(MirrorState.CONSENT_DENIED, s.state)
        assertFalse(s.startPending)
        assertEquals(MirrorStatusFields(5, 0, 0, 0, 0, 7_000_000, 0), s.report(0, 0, false))   // the golden consent_denied fields
        // A new START asks again.
        assertEquals(listOf(ShowConsentNotification, SendStatus), s.control(start()))
    }

    @Test
    fun aShareAfterCancellingTheMacsRequestStreamsAtOnce() {
        // The Mac sends START once per peer: after Cancel, "Share screen with your Mac" must still honour it.
        val s = session()
        s.setUiVisible(true)
        s.connectionAllowed()
        s.control(start())
        s.consentDenied()
        assertEquals(MirrorState.CONSENT_DENIED, s.state)
        assertTrue(s.macWantsStream)
        assertEquals(listOf(RequestConsent, SendStatus), s.shareRequested())
        assertEquals(listOf(CancelConsentNotification, StartEncoder(defaults), SendStatus), s.consentGranted())
        assertEquals(MirrorState.STARTING, s.state)
    }

    @Test
    fun aShareAfterTheOwnerStoppedStreamsAtOnceWhileTheMacStillWantsIt() {
        val s = streaming()
        s.userStopped()
        assertEquals(MirrorState.PROJECTION_ENDED, s.state)
        s.shareRequested()
        assertEquals(listOf(CancelConsentNotification, StartEncoder(defaults), SendStatus), s.consentGranted())
        assertEquals(MirrorState.STARTING, s.state)
    }

    @Test
    fun aShareAfterTheMacsStopOrALostConnectionWaitsPaused() {
        val s = streaming()
        s.control(stop)
        assertFalse(s.macWantsStream)
        s.userStopped()
        s.shareRequested()
        assertEquals(listOf(CancelConsentNotification, SendStatus), s.consentGranted())
        assertEquals(MirrorState.PAUSED, s.state)
        // A lost connection forgets the wish too: the next connection's START asks again.
        val t = streaming()
        t.userStopped()
        t.connectionLost()
        t.connectionAllowed()
        assertFalse(t.macWantsStream)
        t.shareRequested()
        assertEquals(listOf(CancelConsentNotification, SendStatus), t.consentGranted())
        assertEquals(MirrorState.PAUSED, t.state)
        // And RELEASE.
        val r = streaming()
        r.control(release)
        assertFalse(r.macWantsStream)
    }

    @Test
    fun stopKeepsTheProjectionAndPauses() {
        val s = streaming()
        assertEquals(listOf(StopEncoder, SendStatus), s.control(stop))
        assertEquals(MirrorState.PAUSED, s.state)
        assertTrue(s.projectionHeld)
        assertEquals(MirrorStatusFields(4, 1, 0, 0, 0, 7_000_000, 0), s.report(300, 99, false))
        // START resumes with no consent (state 2 then 3).
        assertEquals(listOf(StartEncoder(defaults), SendStatus), s.control(start()))
        assertEquals(listOf(SendStatus), s.encoderStarted(1200, 1600))
        assertEquals(MirrorState.STREAMING, s.state)
    }

    @Test
    fun stopWhileWaitingForConsentCancelsTheRequest() {
        val s = session()
        s.connectionAllowed()
        s.control(start())
        assertEquals(listOf(CancelConsentNotification, SendStatus), s.control(stop))
        assertEquals(MirrorState.IDLE, s.state)
        assertFalse(s.startPending)
        assertEquals(listOf(CancelConsentNotification, SendStatus), s.consentGranted())
        assertEquals(MirrorState.PAUSED, s.state)                      // granted later: held, but not streaming
    }

    @Test
    fun stopWhenIdleDoesNothing() {
        val s = session()
        s.connectionAllowed()
        assertEquals(emptyList<MirrorEffect>(), s.control(stop))
    }

    @Test
    fun requestKeyFrameOnlyWhileStreaming() {
        val s = session()
        s.connectionAllowed()
        assertEquals(emptyList<MirrorEffect>(), s.control(keyFrame))
        val t = streaming()
        assertEquals(listOf(RequestSyncFrame), t.control(keyFrame))
        assertEquals(MirrorState.STREAMING, t.state)
    }

    @Test
    fun releaseStopsTheEncoderAndReleasesTheProjection() {
        val s = streaming()
        assertEquals(listOf(StopEncoder, ReleaseProjection, SendStatus), s.control(release))
        assertEquals(MirrorState.IDLE, s.state)
        assertFalse(s.projectionHeld)
        assertEquals(0, s.report(0, 0, false).flags)
        // The next START needs consent again.
        assertEquals(listOf(ShowConsentNotification, SendStatus), s.control(start()))
    }

    @Test
    fun releaseWhilePausedReportsTheFlagChangeEvenThoughTheStateIsIdleAgain() {
        val s = session()
        s.connectionAllowed()
        s.shareRequested()
        s.consentGranted()
        assertEquals(listOf(ReleaseProjection, SendStatus), s.control(release))
        assertEquals(MirrorState.IDLE, s.state)
    }

    @Test
    fun startWhileStreamingWithTheSameParametersIsIgnoredWithNewParametersRestarts() {
        val s = streaming()
        assertEquals(emptyList<MirrorEffect>(), s.control(start()))
        assertEquals(emptyList<MirrorEffect>(), s.control(start(1600, 7_000_000, 30, 2000)))   // explicit defaults
        assertEquals(listOf(StartEncoder(EncoderParams(1280, 7_000_000, 30, 2)), SendStatus), s.control(start(maxSize = 1280)))
        assertEquals(MirrorState.STARTING, s.state)
    }

    @Test
    fun theNotificationStopEndsTheProjection() {
        val s = streaming()
        assertEquals(listOf(StopEncoder, ReleaseProjection, SendStatus), s.userStopped())
        assertEquals(MirrorState.PROJECTION_ENDED, s.state)
        assertFalse(s.projectionHeld)
        // The system's onStop that follows our own stop() changes nothing.
        assertEquals(emptyList<MirrorEffect>(), s.projectionStopped())
    }

    @Test
    fun theSystemEndingTheProjectionReportsProjectionEnded() {
        val s = streaming()
        assertEquals(listOf(StopEncoder, ReleaseProjection, SendStatus), s.projectionStopped())
        assertEquals(MirrorState.PROJECTION_ENDED, s.state)
        assertEquals(MirrorStatusFields(7, 0, 0, 0, 0, 7_000_000, 0), s.report(300, 5, false))
        // Paused projection ended by the system (lock screen): same state, no encoder to stop.
        val p = session()
        p.connectionAllowed()
        p.shareRequested()
        p.consentGranted()
        assertEquals(listOf(ReleaseProjection, SendStatus), p.projectionStopped())
        assertEquals(MirrorState.PROJECTION_ENDED, p.state)
    }

    @Test
    fun encoderFailureReportsEncoderUnavailableAndKeepsTheProjection() {
        val s = session()
        s.connectionAllowed()
        s.control(start())
        s.consentGranted()
        assertEquals(listOf(StopEncoder, SendStatus), s.encoderFailed())
        assertEquals(MirrorState.ENCODER_UNAVAILABLE, s.state)
        assertTrue(s.projectionHeld)
        assertEquals(1, s.report(0, 0, false).flags)
        assertEquals(emptyList<MirrorEffect>(), s.encoderFailed())          // only while an encoder runs
        assertEquals(listOf(StartEncoder(defaults), SendStatus), s.control(start()))   // START tries again
    }

    @Test
    fun encoderStartedOutsideStartingIsIgnored() {
        val s = session()
        s.connectionAllowed()
        assertEquals(emptyList<MirrorEffect>(), s.encoderStarted(1200, 1600))
        assertEquals(MirrorState.IDLE, s.state)
    }

    @Test
    fun losingTheConnectionPausesAndTheNextAllowedConnectionHearsPaused() {
        val s = streaming()
        assertEquals(listOf(StopEncoder), s.connectionLost())         // no status while not allowed
        assertEquals(MirrorState.PAUSED, s.state)
        assertTrue(s.projectionHeld)
        assertEquals(emptyList<MirrorEffect>(), s.tick())
        assertEquals(listOf(SendStatus), s.connectionAllowed())
        assertEquals(4, s.report(0, 0, false).state)
        assertEquals(listOf(StartEncoder(defaults), SendStatus), s.control(start()))
    }

    @Test
    fun noStatusIsEverRequestedWhileNotAllowed() {
        val s = session()
        s.setUiVisible(true)
        assertEquals(listOf(RequestConsent), s.shareRequested())
        assertEquals(listOf(CancelConsentNotification), s.consentGranted())
        assertEquals(emptyList<MirrorEffect>(), s.powerSaveChanged(true))
        assertEquals(emptyList<MirrorEffect>(), s.thermalStatusChanged(4))
        assertEquals(emptyList<MirrorEffect>(), s.tick())
    }

    @Test
    fun rotationRestartsTheEncoderWhileStreamingOnly() {
        val s = streaming()
        assertEquals(listOf(StartEncoder(defaults), SendStatus), s.displaySizeChanged())
        assertEquals(MirrorState.STARTING, s.state)
        assertEquals(listOf(SendStatus), s.encoderStarted(1600, 1200))
        assertEquals(1600, s.width)
        s.control(stop)
        assertEquals(emptyList<MirrorEffect>(), s.displaySizeChanged())
    }

    @Test
    fun thermalSevereHalvesTheFrameRateCapAndSetsBit1() {
        val s = streaming()
        assertEquals(emptyList<MirrorEffect>(), s.thermalStatusChanged(2))            // MODERATE: nothing
        assertEquals(listOf(StartEncoder(EncoderParams(1600, 7_000_000, 15, 2)), SendStatus), s.thermalStatusChanged(3))
        assertTrue(s.thermalReduced)
        assertEquals(1 or 2, s.report(0, 0, false).flags)
        assertEquals(emptyList<MirrorEffect>(), s.thermalStatusChanged(4))            // still reduced
        s.encoderStarted(1200, 1600)
        assertEquals(listOf(StartEncoder(defaults), SendStatus), s.thermalStatusChanged(1))
        assertEquals(1, s.report(0, 0, false).flags)
    }

    @Test
    fun thermalHalvingNeverGoesBelowOneFps() {
        val s = session()
        s.connectionAllowed()
        s.control(start(fps = 1))
        s.thermalStatusChanged(6)
        assertEquals(1, s.encoderParams().maxFps)
        s.control(start(fps = 25))
        assertEquals(12, s.encoderParams().maxFps)
    }

    @Test
    fun thermalChangeWhilePausedOnlyReports() {
        val s = streaming()
        s.control(stop)
        assertEquals(listOf(SendStatus), s.thermalStatusChanged(3))
        assertEquals(MirrorState.PAUSED, s.state)
        assertEquals(listOf(StartEncoder(EncoderParams(1600, 7_000_000, 15, 2)), SendStatus), s.control(start()))
    }

    @Test
    fun powerSaveSetsBit2AndReportsOnChange() {
        val s = streaming()
        assertEquals(listOf(SendStatus), s.powerSaveChanged(true))
        assertEquals(1 or 4, s.report(0, 0, false).flags)
        assertEquals(emptyList<MirrorEffect>(), s.powerSaveChanged(true))
        assertEquals(MirrorState.STREAMING, s.state)                              // the encoder is not touched
        assertEquals(listOf(SendStatus), s.powerSaveChanged(false))
        assertEquals(1, s.report(0, 0, false).flags)
    }

    @Test
    fun backpressureIsBit3() {
        val s = streaming()
        assertEquals(1 or 8, s.report(0, 0, true).flags)
    }

    @Test
    fun statusRepeatsAt1HzWhileStreamingOrPausedOnly() {
        val s = session()
        s.connectionAllowed()
        now += 5000
        assertEquals(emptyList<MirrorEffect>(), s.tick())                             // IDLE: never repeated
        s.control(start())
        now += 5000
        assertEquals(emptyList<MirrorEffect>(), s.tick())                             // CONSENT_NEEDED: never repeated
        s.consentGranted()
        s.encoderStarted(1200, 1600)                                                  // a status at `now`
        now += 999
        assertEquals(emptyList<MirrorEffect>(), s.tick())
        now += 1
        assertEquals(listOf(SendStatus), s.tick())
        now += 250
        assertEquals(emptyList<MirrorEffect>(), s.tick())
        now += 750
        assertEquals(listOf(SendStatus), s.tick())
        s.control(stop)                                                               // PAUSED: still 1 Hz
        now += 1000
        assertEquals(listOf(SendStatus), s.tick())
        s.control(release)                                                            // IDLE again: silent
        now += 5000
        assertEquals(emptyList<MirrorEffect>(), s.tick())
    }

    @Test
    fun aChangeReportResetsThe1HzClock() {
        val s = streaming()
        now += 600
        s.powerSaveChanged(true)
        now += 600
        assertEquals(emptyList<MirrorEffect>(), s.tick())
        now += 400
        assertEquals(listOf(SendStatus), s.tick())
    }

    @Test
    fun unknownCommandsAreIgnored() {
        val s = streaming()
        assertEquals(emptyList<MirrorEffect>(), s.control(MirrorControl(9, 0, 0, 0, 0)))
        assertEquals(MirrorState.STREAMING, s.state)
    }

    @Test
    fun widthAndHeightAreZeroUnlessStreaming() {
        val s = streaming()
        s.displaySizeChanged()
        assertEquals(MirrorStatusFields(2, 1, 0, 0, 0, 7_000_000, 0), s.report(300, 1000, false))
    }
}
