import Foundation
import XCTest
import DaylightKit

/// SPEC F4 and D40: insets are fractions of the CURRENT session size; two session sizes crop the same screen region.
final class CropInsetsTests: XCTestCase {
    func testDefaultsFromSpec11() {
        XCTAssertEqual(Settings.defaults.mirrorCropInsetsPortrait, CropInsets(top: 96, left: 0, right: 0, bottom: 0))
        XCTAssertEqual(Settings.defaults.mirrorCropInsetsLandscape, CropInsets(top: 72, left: 0, right: 0, bottom: 0))
        XCTAssertEqual(CropInsets.nativePortrait.width, 1200)
        XCTAssertEqual(CropInsets.nativePortrait.height, 1600)
        XCTAssertEqual(CropInsets.nativeLandscape.width, 1600)
        XCTAssertEqual(CropInsets.nativeLandscape.height, 1200)
    }

    func testPortraitDefaultCropAsFractions() {
        let insets = CropInsets(top: 96)
        let uv = insets.uv(sessionWidth: 1200, sessionHeight: 1600, nativeWidth: 1200, nativeHeight: 1600)
        XCTAssertEqual(uv.u0, 0)
        XCTAssertEqual(uv.v0, 0.06, accuracy: 1e-12)
        XCTAssertEqual(uv.u1, 1)
        XCTAssertEqual(uv.v1, 1)
        XCTAssertEqual(insets.croppedAspect(nativeWidth: 1200, nativeHeight: 1600), 1200.0 / 1504.0, accuracy: 1e-12)
        // SPEC 6.5: 1200x1504 fits at 0.675 into 810x1080 giving 810x1015.2 (about 32 px cream bars).
        let slot = PixelRect(x: 235, y: 0, w: 810, h: 1080)
        let fitted = StudioLayout.fit(aspect: insets.croppedAspect(nativeWidth: 1200, nativeHeight: 1600), into: slot)
        XCTAssertEqual(fitted.w, 810, accuracy: 1e-9)
        XCTAssertEqual(fitted.h, 1015.2, accuracy: 1e-9)
        XCTAssertEqual(fitted.y, (1080 - 1015.2) / 2, accuracy: 1e-9)
    }

    func testTwoSessionSizesCropTheSameScreenRegion() {
        let insets = CropInsets(top: 96, left: 24, right: 12, bottom: 40)
        let full = insets.uv(sessionWidth: 1200, sessionHeight: 1600, nativeWidth: 1200, nativeHeight: 1600)
        let fallback = insets.uv(sessionWidth: 960, sessionHeight: 1280, nativeWidth: 1200, nativeHeight: 1600)
        XCTAssertEqual(full, fallback, "fractions do not depend on the encoder's output size")
        let rectFull = insets.pixelRect(sessionWidth: 1200, sessionHeight: 1600, nativeWidth: 1200, nativeHeight: 1600)
        let rectFallback = insets.pixelRect(sessionWidth: 960, sessionHeight: 1280, nativeWidth: 1200, nativeHeight: 1600)
        XCTAssertEqual(rectFull.y, 96, accuracy: 1e-9)
        XCTAssertEqual(rectFallback.y, 76.8, accuracy: 1e-9, "96 of 1600 is 76.8 of 1280: the same screen row")
        XCTAssertEqual(rectFull.x, 24, accuracy: 1e-9)
        XCTAssertEqual(rectFallback.x, 19.2, accuracy: 1e-9)
        XCTAssertEqual(rectFallback.w / rectFallback.h, rectFull.w / rectFull.h, accuracy: 1e-9)
    }

    func testLandscapeUsesItsOwnInsetsAndNativeSize() {
        let insets = Settings.defaults.mirrorCropInsetsLandscape
        let uv = insets.uv(sessionWidth: 1600, sessionHeight: 1200, nativeWidth: 1600, nativeHeight: 1200)
        XCTAssertEqual(uv.v0, 0.06, accuracy: 1e-12, "72 of 1200")
        XCTAssertEqual(insets.croppedAspect(nativeWidth: 1600, nativeHeight: 1200), 1600.0 / 1128.0, accuracy: 1e-12)
        XCTAssertEqual(CropInsets.nativeSize(for: .landscape).width, 1600)
        XCTAssertEqual(CropInsets.nativeSize(for: .portrait).height, 1600)
        XCTAssertEqual(StudioLayout.CanvasOrientation(width: 1600, height: 1200), .landscape)
        XCTAssertEqual(StudioLayout.CanvasOrientation(width: 960, height: 1280), .portrait)
    }

    func testClampingNeverInvertsTheCrop() {
        let absurd = CropInsets(top: 1500, left: -5, right: 1300, bottom: 400)
        let c = absurd.clamped(nativeWidth: 1200, nativeHeight: 1600)
        XCTAssertEqual(c.left, 0)
        XCTAssertGreaterThanOrEqual(1200 - c.left - c.right, CropInsets.minimumRemaining)
        XCTAssertGreaterThanOrEqual(1600 - c.top - c.bottom, CropInsets.minimumRemaining)
        let uv = absurd.uv(sessionWidth: 1200, sessionHeight: 1600, nativeWidth: 1200, nativeHeight: 1600)
        XCTAssertLessThan(uv.u0, uv.u1)
        XCTAssertLessThan(uv.v0, uv.v1)
        XCTAssertGreaterThan(absurd.croppedAspect(nativeWidth: 1200, nativeHeight: 1600), 0)
        XCTAssertEqual(CropInsets.zero.uv(sessionWidth: 10, sessionHeight: 10, nativeWidth: 0, nativeHeight: 0), .full)
    }

    func testTopInsetIsZeroWhenPillsAreOff() {
        let insets = CropInsets(top: 96, left: 10, right: 20, bottom: 30)
        XCTAssertEqual(insets.effective(pillsEnabled: true), insets)
        XCTAssertEqual(insets.effective(pillsEnabled: false), CropInsets(top: 0, left: 10, right: 20, bottom: 30))
        XCTAssertTrue(MirrorPinClearMode.both.includesPills)
        XCTAssertTrue(MirrorPinClearMode.pills.includesPills)
        XCTAssertFalse(MirrorPinClearMode.penButton.includesPills)
    }

    func testCodableRoundTrip() throws {
        let insets = CropInsets(top: 1, left: 2, right: 3, bottom: 4)
        let data = try JSONEncoder().encode(insets)
        XCTAssertEqual(try JSONDecoder().decode(CropInsets.self, from: data), insets)
    }
}
