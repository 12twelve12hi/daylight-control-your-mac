import XCTest
@testable import Daylight

/// SPEC C3's extension rules, called directly: `ExtensionRules.swift` is compiled into this bundle (project.yml), so a
/// changed rule fails here instead of passing a source-text check (test review TSTB-02, camera review CAMB-01, CAMA-03).
final class ExtensionRulesTests: XCTestCase {
    func testOnlyTheHostMayFeedTheSink() {
        XCTAssertTrue(DaylightExtensionRules.authorizesSink(signingID: nil), "an unsigned development host is let through")
        XCTAssertTrue(DaylightExtensionRules.authorizesSink(signingID: "com.twelve.daylight"))
        XCTAssertFalse(DaylightExtensionRules.authorizesSink(signingID: "com.twelve.daylight.evil"))
        XCTAssertFalse(DaylightExtensionRules.authorizesSink(signingID: "com.twelve.daylight.camera"), "not even the extension's own id")
        XCTAssertFalse(DaylightExtensionRules.authorizesSink(signingID: "com.twelve"))
        XCTAssertFalse(DaylightExtensionRules.authorizesSink(signingID: "COM.TWELVE.DAYLIGHT"))
        XCTAssertFalse(DaylightExtensionRules.authorizesSink(signingID: ""))
        XCTAssertFalse(DaylightExtensionRules.authorizesSink(signingID: "us.zoom.xos"))
    }

    func testThePlaceholderIsDrawnOnlyWithoutAHostWhileSomebodyWatches() {
        XCTAssertFalse(DaylightExtensionRules.drawsPlaceholder(sinkStarted: false, streamingCounter: 0), "nobody watching")
        XCTAssertTrue(DaylightExtensionRules.drawsPlaceholder(sinkStarted: false, streamingCounter: 1), "a viewer and no host: the card")
        XCTAssertTrue(DaylightExtensionRules.drawsPlaceholder(sinkStarted: false, streamingCounter: 3))
        XCTAssertFalse(DaylightExtensionRules.drawsPlaceholder(sinkStarted: true, streamingCounter: 0))
        XCTAssertFalse(DaylightExtensionRules.drawsPlaceholder(sinkStarted: true, streamingCounter: 1), "the host feeds real frames")
    }

    func testSinkFramesAreForwardedOnlyWhileAViewerStreams() {
        XCTAssertFalse(DaylightExtensionRules.forwardsSinkFrames(streamingCounter: 0))
        XCTAssertTrue(DaylightExtensionRules.forwardsSinkFrames(streamingCounter: 1))
        XCTAssertTrue(DaylightExtensionRules.forwardsSinkFrames(streamingCounter: 12))
    }

    func testTheViewersPropertyRoundTripsThroughTheHostParser() {
        for count: UInt32 in [0, 1, 2, 12, 1000] {
            let published = DaylightExtensionRules.viewersPropertyValue(streamingCounter: count)
            XCTAssertEqual(ViewerWatcher.parseCount(.string(published)), Int(count), "published \(published)")
        }
        XCTAssertEqual(DaylightExtensionRules.viewersPropertyName, "4cc_dlvw_glob_0000")
        XCTAssertEqual(CMIOProperties.fourCC(DaylightExtensionRules.viewersPropertyFourCC), CMIOProperties.fourCC("dlvw"))
    }

    /// CAMB-01: one host stopping must not clear the started state while another host still feeds the sink.
    func testSinkStaysStartedWhileAnotherHostIsStreaming() {
        var counter: UInt32 = 2   // two starts
        var state = DaylightExtensionRules.sinkStateAfterStop(counter: counter)
        XCTAssertEqual(state.counter, 1)
        XCTAssertTrue(state.started, "the second host still has the sink open")
        counter = state.counter
        state = DaylightExtensionRules.sinkStateAfterStop(counter: counter)
        XCTAssertEqual(state.counter, 0)
        XCTAssertFalse(state.started, "the last stop clears the sink")
        state = DaylightExtensionRules.sinkStateAfterStop(counter: 0)
        XCTAssertEqual(state.counter, 0, "an extra stop never wraps the counter")
        XCTAssertFalse(state.started)
    }

    /// CAMA-03: a disconnecting client stops the sink only when it is the client the sink authorised.
    func testDisconnectStopsTheSinkOnlyForItsAuthorisedClient() {
        let host = UUID()
        let viewer = UUID()
        XCTAssertTrue(DaylightExtensionRules.stopsSinkOnDisconnect(sinkClientID: host, disconnectingClientID: host))
        XCTAssertFalse(DaylightExtensionRules.stopsSinkOnDisconnect(sinkClientID: host, disconnectingClientID: viewer), "Zoom leaving does not stop the host's sink")
        XCTAssertFalse(DaylightExtensionRules.stopsSinkOnDisconnect(sinkClientID: nil, disconnectingClientID: host), "no authorised client (or already stopped): nothing to stop")
    }

    /// VP decision (charter item 6): Info.plist values that are missing or not UUIDs fall back instead of crashing.
    func testPlistUUIDParsingAndDistinctDefaults() {
        XCTAssertEqual(DaylightExtensionRules.uuid(fromPlistValue: "AB51C6BA-17FD-4A67-BE3A-06A8540BA6AA"), DaylightExtensionRules.defaultDeviceUUID)
        XCTAssertNil(DaylightExtensionRules.uuid(fromPlistValue: nil), "missing key")
        XCTAssertNil(DaylightExtensionRules.uuid(fromPlistValue: "not-a-uuid"), "typo in project.yml")
        XCTAssertNil(DaylightExtensionRules.uuid(fromPlistValue: 42), "wrong type")
        let defaults = [DaylightExtensionRules.defaultDeviceUUID, DaylightExtensionRules.defaultSourceUUID, DaylightExtensionRules.defaultSinkUUID]
        XCTAssertEqual(Set(defaults).count, 3, "the three built-in UUIDs are distinct")
        XCTAssertEqual(DaylightExtensionRules.defaultDeviceUUID.uuidString, "AB51C6BA-17FD-4A67-BE3A-06A8540BA6AA")
        XCTAssertEqual(DaylightExtensionRules.defaultSourceUUID.uuidString, "8C5A2272-C779-469F-8439-BFE8BEBA229A")
        XCTAssertEqual(DaylightExtensionRules.defaultSinkUUID.uuidString, "4B856AE3-B992-490B-8DC5-1F2A9475D6E7")
    }
}
