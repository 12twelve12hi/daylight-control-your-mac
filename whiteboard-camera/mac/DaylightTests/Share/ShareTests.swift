import AppKit
import CoreVideo
import DaylightKit
import XCTest
@testable import Daylight

/// The share window (docs/product/TOO-SMALL.md section 8, SH1 and SH2): the renderer equals the compositor's canvas
/// blend, the window geometry, the settings blob, the menu, the how-to text and a real window drawing a frame.
final class ShareRendererTests: XCTestCase {
    func testComposeMatchesTheCanvasShader() throws {
        let surfaces = try CanvasSurfaces(device: nil)
        ShareSelfTest.fill(surfaces.ink, x: 100, y: 100, size: 10, bgra: (0x11, 0x11, 0x11, 0xFF))
        ShareSelfTest.fill(surfaces.highlight, x: 500, y: 500, size: 10, bgra: (0x00, 0x80, 0x80, 0x80))
        // Ink over highlighter: the ink wins.
        ShareSelfTest.fill(surfaces.highlight, x: 300, y: 300, size: 10, bgra: (0x00, 0x80, 0x80, 0x80))
        ShareSelfTest.fill(surfaces.ink, x: 300, y: 300, size: 10, bgra: (0x11, 0x11, 0x11, 0xFF))
        let image = try XCTUnwrap(ShareCanvasRenderer.compose(ink: surfaces.ink, highlight: surfaces.highlight))
        XCTAssertEqual(image.width, 1200)
        XCTAssertEqual(image.height, 1600)
        let p = Tokens.paperBg
        XCTAssertTrue(ShareSelfTest.close(ShareCanvasRenderer.pixel(image, x: 105, y: 105), (0x11, 0x11, 0x11)))
        XCTAssertTrue(ShareSelfTest.close(ShareCanvasRenderer.pixel(image, x: 305, y: 305), (0x11, 0x11, 0x11)))
        XCTAssertTrue(ShareSelfTest.close(ShareCanvasRenderer.pixel(image, x: 0, y: 0), (ShareSelfTest.byte(p.b), ShareSelfTest.byte(p.g), ShareSelfTest.byte(p.r))))
        let a = 128.0 / 255.0
        XCTAssertTrue(ShareSelfTest.close(ShareCanvasRenderer.pixel(image, x: 505, y: 505), (ShareSelfTest.byte(p.b * (1 - a)), ShareSelfTest.byte(p.g), ShareSelfTest.byte(p.r)), tolerance: 4),
                      "\(ShareSelfTest.describe(ShareCanvasRenderer.pixel(image, x: 505, y: 505)))")
        // Row 0 of the surface is the top of the page (no flip on the way to the window).
        XCTAssertTrue(ShareSelfTest.close(ShareCanvasRenderer.pixel(image, x: 105, y: 1600 - 105), (ShareSelfTest.byte(p.b), ShareSelfTest.byte(p.g), ShareSelfTest.byte(p.r))))
    }

    func testRenderKeyFollowsTheCanvasSeed() throws {
        let surfaces = try CanvasSurfaces(device: nil)
        let a = ShareWindowController.key(for: .layers(surfaces))
        surfaces.noteWrite()
        let b = ShareWindowController.key(for: .layers(surfaces))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(ShareWindowController.key(for: .none), .none)
        XCTAssertNil(ShareWindowController.render(.none))
    }

    func testMirrorCropIsFlippedToCoreImage() {
        let r = ShareCanvasRenderer.cropRect(uv: UVRect(u0: 0.1, v0: 0.2, u1: 0.9, v1: 0.7), width: 1000, height: 2000)
        XCTAssertEqual(r.origin.x, 100, accuracy: 1e-9)
        XCTAssertEqual(r.origin.y, 600, accuracy: 1e-9, "(1 - v1) * height")
        XCTAssertEqual(r.width, 800, accuracy: 1e-9)
        XCTAssertEqual(r.height, 1000, accuracy: 1e-9)
        let clamped = ShareCanvasRenderer.cropRect(uv: UVRect(u0: -1, v0: -1, u1: 2, v1: 2), width: 10, height: 20)
        XCTAssertEqual(clamped, CGRect(x: 0, y: 0, width: 10, height: 20))
    }

    func testMirrorImageCropsTheBuffer() throws {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        XCTAssertEqual(CVPixelBufferCreate(nil, 200, 100, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        let image = try XCTUnwrap(ShareCanvasRenderer.mirrorImage(pixels, uv: UVRect(u0: 0, v0: 0, u1: 0.5, v1: 1)))
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 100)
    }
}

final class ShareWindowTests: XCTestCase {
    func testConstants() {
        XCTAssertEqual(ShareWindowController.refreshHz, 30, "SH1")
        XCTAssertEqual(ShareWindowController.screenFraction, 0.85, "SH2")
        XCTAssertEqual(ShareWindowController.title, "Daylight Whiteboard")
    }

    func testContentSizeFitsTheScreen() {
        XCTAssertEqual(ShareWindowController.contentSize(aspect: 0.75, visible: CGSize(width: 1512, height: 944)), CGSize(width: 602, height: 802))
        // A landscape mirror picture on the same screen: the height binds again.
        XCTAssertEqual(ShareWindowController.contentSize(aspect: 4.0 / 3.0, visible: CGSize(width: 1512, height: 944)), CGSize(width: 1070, height: 802))
        // A very wide picture on a narrow screen: the width binds.
        XCTAssertEqual(ShareWindowController.contentSize(aspect: 3, visible: CGSize(width: 1000, height: 1000)), CGSize(width: 850, height: 283))
        XCTAssertEqual(ShareWindowController.contentSize(aspect: 0, visible: CGSize(width: 1000, height: 1000)), CGSize(width: 600, height: 800))
    }

    func testStyleMaskFollowsTheTitleBarSetting() {
        XCTAssertTrue(ShareWindowController.styleMask(hideTitleBar: false).contains(.titled))
        XCTAssertFalse(ShareWindowController.styleMask(hideTitleBar: true).contains(.titled))
        XCTAssertTrue(ShareWindowController.styleMask(hideTitleBar: true).contains(.resizable))
    }

    func testWindowShowsTheCanvasAndFollowsSettings() throws {
        guard Thread.isMainThread else { return }
        let surfaces = try CanvasSurfaces(device: nil)
        ShareSelfTest.fill(surfaces.ink, x: 0, y: 0, size: 20, bgra: (0x11, 0x11, 0x11, 0xFF))
        surfaces.noteWrite()
        let controller = ShareWindowController()
        controller.source = { .layers(surfaces) }
        var visibility: [Bool] = []
        controller.onVisibility = { visibility.append($0) }
        controller.show(activate: false)
        defer { controller.hide() }
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.title, "Daylight Whiteboard")
        XCTAssertEqual(window.sharingType, .readOnly, "a call app must be able to capture it")
        XCTAssertEqual(window.level, .normal)
        let drawn = expectation(description: "a frame is drawn")
        func poll() {
            if controller.framesDrawn > 0 { drawn.fulfill(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
        }
        poll()
        wait(for: [drawn], timeout: 5)
        let view = try XCTUnwrap(window.contentView as? ShareCanvasView)
        let image = try XCTUnwrap(view.currentImage)
        XCTAssertEqual(image.width, 1200)
        // No canvas change, no new frame (SH1: redraw only on change).
        let frames = controller.framesDrawn
        controller.tick()
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(controller.framesDrawn, frames)
        controller.apply(ShareSettings(floats: true, hideTitleBar: true, openWithBoard: false))
        XCTAssertEqual(window.level, .floating)
        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertTrue(window.isMovableByWindowBackground)
        controller.apply(ShareSettings())
        XCTAssertTrue(window.styleMask.contains(.titled))
        controller.hide()
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(visibility.first, true)
        XCTAssertEqual(visibility.last, false)
    }
}

final class ShareSettingsTests: XCTestCase {
    func testDefaultsAndLenientDecoding() throws {
        XCTAssertEqual(ShareSettings.defaults, ShareSettings(floats: false, hideTitleBar: false, openWithBoard: false))
        let decoded = try JSONDecoder().decode(ShareSettings.self, from: Data(#"{"floats":true,"future":1}"#.utf8))
        XCTAssertEqual(decoded, ShareSettings(floats: true))
        XCTAssertEqual(ShareSettings.userDefaultsKey, "com.twelve.daylight.share.v1")
    }

    func testStorePersistsAndReportsChanges() throws {
        let suite = "com.twelve.daylight.tests.share"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShareSettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings, .defaults)
        var seen: [ShareSettings] = []
        store.onChange = { seen.append($0) }
        store.settings.openWithBoard = true
        XCTAssertEqual(seen, [ShareSettings(openWithBoard: true)])
        XCTAssertEqual(ShareSettingsStore(defaults: defaults).settings, ShareSettings(openWithBoard: true))
    }
}

final class ShareMenuTests: XCTestCase {
    func testMenuItems() {
        let menu = ShareMenu(controller: ShareWindowController())
        let item = menu.makeItem()
        XCTAssertEqual(item.title, "Share the whiteboard")
        XCTAssertEqual(item.submenu?.items.map { $0.title }, ["Show share window", "How to share it in a call...", "Share settings..."])
        XCTAssertEqual(item.submenu?.items.first?.state, .off)
    }

    func testGuideNamesTheWindowAndFollowsTheWritingRules() {
        let text = ShareGuide.heading + ShareGuide.text
        XCTAssertTrue(ShareGuide.zoom.contains("\"Daylight Whiteboard\""))
        XCTAssertTrue(ShareGuide.meet.contains("\"Daylight Whiteboard\""))
        XCTAssertTrue(ShareGuide.teams.contains("\"Daylight Whiteboard\""))
        XCTAssertFalse(text.contains("\u{2014}"), "no em-dashes")
        XCTAssertFalse(text.contains("\u{2013}"))
    }

    func testSettingsTabExists() {
        XCTAssertEqual(SettingsTab.named("share"), .share)
        XCTAssertEqual(SettingsTab.share.lastElementID, "daylight.settings.share.last")
    }
}
