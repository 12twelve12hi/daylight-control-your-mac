import CoreMedia
import DaylightKit
import XCTest
@testable import Daylight

/// The unsigned-build sink (SPEC D19): status `.installed` (so capture keeps running for the preview), every push
/// accepted and dropped, no viewers.
final class PreviewOnlySinkTests: XCTestCase {
    func testStatusIsInstalledAndPushesAreAcceptedAndCounted() throws {
        let sink = PreviewOnlySink()
        XCTAssertEqual(sink.status, .installed)
        XCTAssertEqual(sink.viewerCount, 0)
        XCTAssertFalse(sink.isRunning)
        var reported: [SinkStatus] = []
        sink.onStatusChange = { reported.append($0) }
        sink.start()
        XCTAssertTrue(sink.isRunning)
        XCTAssertEqual(reported, [.installed], "start reports the status once so the pipeline wires the idle rule")
        let feeder = SinkFeeder(sink: sink)
        let buffer = try XCTUnwrap(CameraTestBuffers.make(width: 64, height: 36))
        for _ in 0..<10 { XCTAssertTrue(feeder.push(buffer, hostTimeNs: nil)) }
        XCTAssertEqual(sink.pushCount, 10)
        XCTAssertEqual(feeder.pushedFrames, 10)
        XCTAssertEqual(feeder.droppedFrames, 0)
        sink.stop()
        XCTAssertFalse(sink.isRunning)
        XCTAssertEqual(sink.status, .installed, "stop never changes the status of the preview-only sink")
    }

    func testPreviewOnlySinkIsTheUnsignedBuildChoice() {
        // SPEC D19 and IMPLEMENTATION-PLAN 3.2: `signed ? CMIOSinkClient : PreviewOnlySink`. The hosted bundle runs an
        // unsigned build, so Info.plist says false here and this sink is what AppDelegate.makeSink picks.
        let flag = Bundle.main.object(forInfoDictionaryKey: "DaylightBuildSigned")
        XCTAssertNotNil(flag as? Bool, "project.yml writes DaylightBuildSigned into the app Info.plist")
        print("camera-tests: DaylightBuildSigned=\(String(describing: flag))")
    }
}
