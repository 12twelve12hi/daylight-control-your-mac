import Foundation
import XCTest
import DaylightKit

/// `LumaGrid.sample`: BGRA byte order, Y = (54 R + 183 G + 19 B) >> 8, one pixel at each cell centre, crop in UV
/// fractions, row padding. Buffers are built with explicit loops (ARCHITECTURE 18 toolchain facts).
final class LumaGridTests: XCTestCase {
    /// A width x height BGRA image whose pixel (x, y) is gray `value(x, y)`; `bytesPerRow` may add padding (0xFF).
    private func grayImage(width: Int, height: Int, bytesPerRow: Int, value: (Int, Int) -> UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0xFF, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let g = value(x, y)
                let i = y * bytesPerRow + x * 4
                bytes[i] = g
                bytes[i + 1] = g
                bytes[i + 2] = g
                bytes[i + 3] = 255
            }
        }
        return bytes
    }

    private func sample(_ bytes: [UInt8], bytesPerRow: Int, width: Int, height: Int, crop: UVRect = .full, gridWidth: Int, gridHeight: Int) -> [UInt8] {
        return bytes.withUnsafeBytes { raw in
            LumaGrid.sample(bgra: raw, bytesPerRow: bytesPerRow, width: width, height: height, crop: crop, gridWidth: gridWidth, gridHeight: gridHeight)
        }
    }

    private static func ramp(_ x: Int, _ y: Int) -> UInt8 {
        return UInt8(x * 10 + y * 50)
    }

    func testSizes() {
        XCTAssertEqual(LumaGrid.portraitSize.width, 48)
        XCTAssertEqual(LumaGrid.portraitSize.height, 64)
        XCTAssertEqual(LumaGrid.landscapeSize.width, 64)
        XCTAssertEqual(LumaGrid.landscapeSize.height, 48)
    }

    func testLumaWeights() {
        XCTAssertEqual(LumaGrid.luma(b: 255, g: 255, r: 255), 255, "54 + 183 + 19 = 256")
        XCTAssertEqual(LumaGrid.luma(b: 0, g: 0, r: 0), 0)
        XCTAssertEqual(LumaGrid.luma(b: 0, g: 0, r: 255), 53)
        XCTAssertEqual(LumaGrid.luma(b: 0, g: 255, r: 0), 182)
        XCTAssertEqual(LumaGrid.luma(b: 255, g: 0, r: 0), 18)
        XCTAssertEqual(LumaGrid.luma(b: 100, g: 100, r: 100), 100, "gray stays gray")
    }

    func testByteOrderIsBGRA() {
        var bytes = [UInt8](repeating: 0, count: 2 * 4)
        bytes[0] = 255   // pixel 0 blue
        bytes[6] = 255   // pixel 1 red
        let grid = sample(bytes, bytesPerRow: 8, width: 2, height: 1, gridWidth: 2, gridHeight: 1)
        XCTAssertEqual(grid, [18, 53])
    }

    func testCellCentresOnAFullCrop() {
        let image = grayImage(width: 4, height: 4, bytesPerRow: 16, value: LumaGridTests.ramp)
        // 2 x 2 cells: centres at u, v = 0.25 and 0.75, so pixels 1 and 3.
        let grid = sample(image, bytesPerRow: 16, width: 4, height: 4, gridWidth: 2, gridHeight: 2)
        XCTAssertEqual(grid, [60, 80, 160, 180], "row-major")
        let one = sample(image, bytesPerRow: 16, width: 4, height: 4, gridWidth: 4, gridHeight: 4)
        var expected: [UInt8] = []
        for y in 0..<4 {
            for x in 0..<4 {
                expected.append(LumaGridTests.ramp(x, y))
            }
        }
        XCTAssertEqual(one, expected, "one cell per pixel samples every pixel")
    }

    func testThirdsLandOnTheSamePixelsEverywhere() {
        let image = grayImage(width: 6, height: 3, bytesPerRow: 24, value: LumaGridTests.ramp)
        // 3 columns over 6 px: centres at 1.0, 3.0 and 5.0 px exactly; 1 row over 3 px: centre 1.5.
        let grid = sample(image, bytesPerRow: 24, width: 6, height: 3, gridWidth: 3, gridHeight: 1)
        XCTAssertEqual(grid, [LumaGridTests.ramp(1, 1), LumaGridTests.ramp(3, 1), LumaGridTests.ramp(5, 1)])
    }

    func testRowPaddingIsSkipped() {
        let image = grayImage(width: 4, height: 4, bytesPerRow: 24, value: LumaGridTests.ramp)
        let grid = sample(image, bytesPerRow: 24, width: 4, height: 4, gridWidth: 2, gridHeight: 2)
        XCTAssertEqual(grid, [60, 80, 160, 180])
    }

    func testCropSamplesInsideTheRect() {
        let image = grayImage(width: 4, height: 4, bytesPerRow: 16, value: LumaGridTests.ramp)
        let topRight = UVRect(u0: 0.5, v0: 0, u1: 1, v1: 0.5)
        XCTAssertEqual(sample(image, bytesPerRow: 16, width: 4, height: 4, crop: topRight, gridWidth: 1, gridHeight: 1), [LumaGridTests.ramp(3, 1)])
        XCTAssertEqual(sample(image, bytesPerRow: 16, width: 4, height: 4, crop: topRight, gridWidth: 2, gridHeight: 2), [
            LumaGridTests.ramp(2, 0), LumaGridTests.ramp(3, 0), LumaGridTests.ramp(2, 1), LumaGridTests.ramp(3, 1),
        ])
        let bottom = UVRect(u0: 0, v0: 0.5, u1: 1, v1: 1)
        XCTAssertEqual(sample(image, bytesPerRow: 16, width: 4, height: 4, crop: bottom, gridWidth: 2, gridHeight: 1), [LumaGridTests.ramp(1, 3), LumaGridTests.ramp(3, 3)])
    }

    func testOutOfRangeCropClampsToTheImage() {
        let image = grayImage(width: 4, height: 4, bytesPerRow: 16, value: LumaGridTests.ramp)
        let wide = UVRect(u0: -1, v0: -1, u1: 2, v1: 2)
        XCTAssertEqual(sample(image, bytesPerRow: 16, width: 4, height: 4, crop: wide, gridWidth: 3, gridHeight: 1), [LumaGridTests.ramp(0, 2), LumaGridTests.ramp(2, 2), LumaGridTests.ramp(3, 2)], "u -0.5, 0.5, 1.5 and v 0.5 of the image")
    }

    func testInvalidInputsGiveZerosOrNothing() {
        let image = grayImage(width: 4, height: 4, bytesPerRow: 16, value: LumaGridTests.ramp)
        XCTAssertEqual(sample(Array(image.prefix(40)), bytesPerRow: 16, width: 4, height: 4, gridWidth: 2, gridHeight: 2), [0, 0, 0, 0], "buffer shorter than the image")
        XCTAssertEqual(sample(image, bytesPerRow: 8, width: 4, height: 4, gridWidth: 2, gridHeight: 2), [0, 0, 0, 0], "row narrower than width")
        XCTAssertEqual(sample(image, bytesPerRow: 16, width: 0, height: 4, gridWidth: 2, gridHeight: 2), [0, 0, 0, 0])
        XCTAssertEqual(sample(image, bytesPerRow: 16, width: 4, height: 4, gridWidth: 0, gridHeight: 2), [])
    }

    func testPortraitGridOfAStroke() {
        // A 96 x 128 white page with a black horizontal line on rows 63...64: the 48 x 64 grid sees it in exactly one row.
        let width = 96
        let height = 128
        var image = [UInt8](repeating: 255, count: width * height * 4)
        for y in 63...64 {
            for x in 0..<width {
                let i = (y * width + x) * 4
                image[i] = 0
                image[i + 1] = 0
                image[i + 2] = 0
            }
        }
        let grid = sample(image, bytesPerRow: width * 4, width: width, height: height, gridWidth: 48, gridHeight: 64)
        XCTAssertEqual(grid.count, 48 * 64)
        var darkRows: [Int] = []
        for gy in 0..<64 {
            var dark = 0
            for gx in 0..<48 where grid[gy * 48 + gx] == 0 {
                dark += 1
            }
            if dark > 0 {
                XCTAssertEqual(dark, 48, "row \(gy)")
                darkRows.append(gy)
            }
        }
        XCTAssertEqual(darkRows, [31], "cell row 31 has its centre on pixel row 63")
    }
}
