import XCTest
import DaylightKit

/// Camera line weight (DRAWING-DEEP-DIVE D14): 2.5 output px at 1080p for the pen, 6 for the highlighter, scaled with
/// the output height; strokes already wider are untouched; the eraser has no minimum.
final class CameraLineWeightTests: XCTestCase {
    func testMinimumsInCanvasAndOutputPixels() {
        XCTAssertEqual(CameraLineWeight.penMinimumOutputPixels, 2.5)
        XCTAssertEqual(CameraLineWeight.highlighterMinimumOutputPixels, 6.0)
        let pen = CameraLineWeight.minimumCanvasWidth(for: .pen)
        XCTAssertEqual(pen, 2.5 * 1600 / 1080, accuracy: 1e-12, "about 3.7 canvas px")
        XCTAssertEqual(CameraLineWeight.outputWidth(canvasWidth: pen, outputHeight: 1080), 2.5, accuracy: 1e-12)
        XCTAssertEqual(CameraLineWeight.outputWidth(canvasWidth: pen, outputHeight: 720), 2.5 * 720 / 1080, accuracy: 1e-12, "1.7 px at 720p is the consequence")
        let highlighter = CameraLineWeight.minimumCanvasWidth(for: .highlighter)
        XCTAssertGreaterThan(highlighter, pen, "the highlighter has its own, larger minimum")
        XCTAssertEqual(CameraLineWeight.outputWidth(canvasWidth: highlighter, outputHeight: 1080), 6.0, accuracy: 1e-12)
        XCTAssertEqual(CameraLineWeight.minimumCanvasWidth(for: .eraser), 0)
        XCTAssertEqual(CameraLineWeight.minimumCanvasWidth(for: .lasso), pen)
    }

    func testClampRaisesThinStrokesAndLeavesWideOnesUnchanged() {
        let pen = CameraLineWeight.minimumCanvasWidth(for: .pen)
        XCTAssertEqual(CameraLineWeight.cameraWidth(1, tool: .pen), pen)
        XCTAssertEqual(CameraLineWeight.cameraWidth(6, tool: .pen), 6, "a 6 px stroke is unchanged")
        XCTAssertEqual(CameraLineWeight.cameraWidth(1, tool: .highlighter), CameraLineWeight.minimumCanvasWidth(for: .highlighter))
        XCTAssertEqual(CameraLineWeight.cameraWidth(17.4, tool: .highlighter), 17.4)
        XCTAssertEqual(CameraLineWeight.cameraWidth(0.5, tool: .eraser), 0.5, "eraser geometry unchanged")
        // The shipped pen (base 3.2): pressure 1 draws 4.64 px, above the floor; light pressure is raised to it.
        XCTAssertEqual(CameraLineWeight.cameraWidth(StrokeStore.width(base: 3.2, pressure: 1), tool: .pen), 4.64, accuracy: 1e-9)
        XCTAssertEqual(CameraLineWeight.cameraWidth(StrokeStore.width(base: 3.2, pressure: 0), tool: .pen), pen)
    }

    func testRedrawMarginCoversHalfTheWidestMinimumPlusAntialiasing() {
        let margin = CameraLineWeight.redrawMargin()
        XCTAssertGreaterThanOrEqual(margin, CameraLineWeight.minimumCanvasWidth(for: .highlighter) / 2 + 1)
        XCTAssertEqual(margin, margin.rounded(), "whole pixels")
        XCTAssertEqual(margin, 6)
    }
}
