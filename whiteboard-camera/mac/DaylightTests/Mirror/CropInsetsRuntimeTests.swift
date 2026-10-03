import CoreVideo
import DaylightKit
import Foundation
import XCTest
@testable import Daylight

/// SPEC F4 at the `MirrorFrameSource` level: UV for 1200x1600, 960x1280 and 1600x1200 sessions select the same screen
/// region; the pills rule; the frame seed.
final class CropInsetsRuntimeTests: XCTestCase {
    func testNoFrameBeforeTheFirstPublish() {
        let source = MirrorSource(settings: Settings.defaults)
        XCTAssertNil(source.latest())
        XCTAssertNil(source.latestForSave())
        XCTAssertEqual(source.frameSeed, 0)
        XCTAssertEqual(source.sessionSize.w, 1200)
        XCTAssertEqual(source.sessionSize.h, 1600)
    }

    func testPortraitSessionsOfTwoSizesCropTheSameRegion() throws {
        let source = MirrorSource(settings: Settings.defaults)
        guard let buffer = SelfTest.gradientBuffer(width: 1200, height: 1600) else { return XCTFail("buffer") }
        source.setSessionSize(width: 1200, height: 1600)
        source.publish(buffer, ptsUs: 1)
        guard let full = source.latest() else { return XCTFail("frame") }
        XCTAssertEqual(full.orientation, .portrait)
        XCTAssertEqual(full.uv.v0, 0.06, accuracy: 1e-12, "96 of 1600")
        XCTAssertEqual(full.uv.u0, 0)
        XCTAssertEqual(full.uv.u1, 1)
        XCTAssertEqual(full.uv.v1, 1)
        XCTAssertEqual(full.aspect, 1200.0 / 1504.0, accuracy: 1e-12)
        source.setSessionSize(width: 960, height: 1280)
        guard let fallback = source.latest() else { return XCTFail("frame") }
        XCTAssertEqual(fallback.uv, full.uv, "fractions of the current session size: the same screen rows")
        XCTAssertEqual(fallback.aspect, full.aspect, accuracy: 1e-12)
        XCTAssertEqual(fallback.orientation, .portrait)
        XCTAssertEqual(source.frameSeed, 1)
    }

    func testLandscapeSessionUsesTheLandscapeInsets() {
        let source = MirrorSource(settings: Settings.defaults)
        guard let buffer = SelfTest.gradientBuffer(width: 1600, height: 1200) else { return XCTFail("buffer") }
        source.setSessionSize(width: 1600, height: 1200)
        source.publish(buffer, ptsUs: 2)
        guard let frame = source.latest() else { return XCTFail("frame") }
        XCTAssertEqual(frame.orientation, .landscape)
        XCTAssertEqual(frame.uv.v0, 0.06, accuracy: 1e-12, "72 of 1200")
        XCTAssertEqual(frame.aspect, 1600.0 / 1128.0, accuracy: 1e-12)
        let save = source.latestForSave()
        XCTAssertEqual(save?.uv, frame.uv)
    }

    func testTopInsetIsZeroWhenPillsAreOff() {
        var settings = Settings.defaults
        settings.mirrorPinClearMode = .penButton
        let source = MirrorSource(settings: settings)
        guard let buffer = SelfTest.gradientBuffer(width: 1200, height: 1600) else { return XCTFail("buffer") }
        source.publish(buffer, ptsUs: 3)
        XCTAssertEqual(source.latest()?.uv, .full)
        XCTAssertEqual(source.latest()?.aspect ?? 0, 0.75, accuracy: 1e-12)
        settings.mirrorPinClearMode = .both
        source.updateSettings(settings)
        XCTAssertEqual(source.latest()?.uv.v0 ?? 0, 0.06, accuracy: 1e-12)
        settings.mirrorCropInsetsPortrait = CropInsets(top: 160, left: 40, right: 40, bottom: 80)
        source.updateSettings(settings)
        guard let custom = source.latest() else { return XCTFail("frame") }
        XCTAssertEqual(custom.uv.u0, 40.0 / 1200.0, accuracy: 1e-12)
        XCTAssertEqual(custom.uv.v0, 0.1, accuracy: 1e-12)
        XCTAssertEqual(custom.uv.u1, 1 - 40.0 / 1200.0, accuracy: 1e-12)
        XCTAssertEqual(custom.uv.v1, 1 - 80.0 / 1600.0, accuracy: 1e-12)
        XCTAssertEqual(custom.aspect, 1120.0 / 1360.0, accuracy: 1e-12)
    }

    func testSeedMovesOnEveryPublishAndOnClear() {
        let source = MirrorSource(settings: Settings.defaults)
        guard let buffer = SelfTest.gradientBuffer(width: 320, height: 240) else { return XCTFail("buffer") }
        source.publish(buffer, ptsUs: 1)
        source.publish(buffer, ptsUs: 2)
        XCTAssertEqual(source.frameSeed, 2)
        XCTAssertEqual(source.frameCount, 2)
        source.clear()
        XCTAssertEqual(source.frameSeed, 3)
        XCTAssertNil(source.latest())
    }

    func testGeometryIsPure() {
        let g = MirrorSource.geometry(sessionWidth: 800, sessionHeight: 600, portrait: CropInsets(top: 96), landscape: CropInsets(top: 72), pillsEnabled: true)
        XCTAssertEqual(g.orientation, .landscape)
        XCTAssertEqual(g.uv.v0, 0.06, accuracy: 1e-12)
        let p = MirrorSource.geometry(sessionWidth: 600, sessionHeight: 800, portrait: CropInsets(top: 96), landscape: CropInsets(top: 72), pillsEnabled: false)
        XCTAssertEqual(p.orientation, .portrait)
        XCTAssertEqual(p.uv, .full)
    }
}
