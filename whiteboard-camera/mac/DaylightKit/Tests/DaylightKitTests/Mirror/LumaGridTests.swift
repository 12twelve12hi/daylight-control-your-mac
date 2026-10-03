import Foundation
import XCTest
import DaylightKit

/// `LumaGrid.sample`: BGRA byte order, Y = (54 R + 183 G + 19 B) >> 8, each cell the rounded mean of a stride x stride
/// sub-sample of its whole area, crop in UV fractions, row padding. Buffers are built with explicit loops
/// (ARCHITECTURE 18 toolchain facts).
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

    private func sample(_ bytes: [UInt8], bytesPerRow: Int, width: Int, height: Int, crop: UVRect = .full, gridWidth: Int, gridHeight: Int, stride: Int = LumaGrid.defaultStride) -> [UInt8] {
        return bytes.withUnsafeBytes { raw in
            LumaGrid.sample(bgra: raw, bytesPerRow: bytesPerRow, width: width, height: height, crop: crop, gridWidth: gridWidth, gridHeight: gridHeight, stride: stride)
        }
    }

    private static func ramp(_ x: Int, _ y: Int) -> UInt8 {
        return UInt8(x * 10 + y * 50)
    }

    func testSizes() {
        XCTAssertEqual(LumaGrid.portraitSize.width, 144)
        XCTAssertEqual(LumaGrid.portraitSize.height, 192)
        XCTAssertEqual(LumaGrid.landscapeSize.width, 192)
        XCTAssertEqual(LumaGrid.landscapeSize.height, 144)
        XCTAssertEqual(LumaGrid.defaultStride, 2)
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

    func testOneCellPerPixelSamplesEveryPixel() {
        let image = grayImage(width: 4, height: 4, bytesPerRow: 16, value: LumaGridTests.ramp)
        let one = sample(image, bytesPerRow: 16, width: 4, height: 4, gridWidth: 4, gridHeight: 4)
        var expected: [UInt8] = []
        for y in 0..<4 {
            for x in 0..<4 {
                expected.append(LumaGridTests.ramp(x, y))
            }
        }
        XCTAssertEqual(one, expected, "row-major")
    }

    func testACellIsTheRoundedMeanOfItsStrideSubSample() {
        let image = grayImage(width: 4, height: 4, bytesPerRow: 16, value: LumaGridTests.ramp)
        // Stride 2 over one 4 x 4 cell reads (0, 0), (2, 0), (0, 2), (2, 2): 0, 20, 100, 120.
        XCTAssertEqual(sample(image, bytesPerRow: 16, width: 4, height: 4, gridWidth: 1, gridHeight: 1), [60])
        // Stride 1 reads all 16 pixels: mean x 10 = 15, mean y 50 = 75.
        XCTAssertEqual(sample(image, bytesPerRow: 16, width: 4, height: 4, gridWidth: 1, gridHeight: 1, stride: 1), [90])
        XCTAssertEqual(sample(image, bytesPerRow: 16, width: 4, height: 4, gridWidth: 1, gridHeight: 1, stride: 0), [90], "a stride below 1 counts as 1")
        // 2 x 2 cells of 2 x 2 px, stride 2: each cell reads its top-left pixel.
        XCTAssertEqual(sample(image, bytesPerRow: 16, width: 4, height: 4, gridWidth: 2, gridHeight: 2), [0, 20, 100, 120])
        // Rounding: 1 and 2 average to 1.5, which rounds up.
        let pair = grayImage(width: 2, height: 1, bytesPerRow: 8) { x, _ in UInt8(x + 1) }
        XCTAssertEqual(sample(pair, bytesPerRow: 8, width: 2, height: 1, gridWidth: 1, gridHeight: 1, stride: 1), [2])
    }

    /// The point of pooling: a 2 px line anywhere inside an 8 px cell darkens the cell. One pixel at the cell centre
    /// (the earlier design) read pixel (4, 4), which stays white here.
    func testThinInkAnywhereInsideACellMovesIt() {
        let image = grayImage(width: 16, height: 16, bytesPerRow: 64) { x, _ in x == 6 || x == 7 ? 0 : 255 }
        let grid = sample(image, bytesPerRow: 64, width: 16, height: 16, gridWidth: 2, gridHeight: 2)
        // Cell 0 reads columns 0, 2, 4, 6 of rows 0, 2, 4, 6: column 6 is ink, so 12 of 16 samples are white.
        XCTAssertEqual(grid, [191, 255, 191, 255])
        XCTAssertGreaterThanOrEqual(255 - Int(grid[0]), FrameDiffEngage.Config().cellDelta)
    }

    func testCellRangesCoverTheCropAndAreNeverEmpty() {
        let image = grayImage(width: 6, height: 3, bytesPerRow: 24, value: LumaGridTests.ramp)
        // 3 columns over 6 px: [0, 2), [2, 4), [4, 6); one row over 3 px, stride 2: rows 0 and 2 (ramp y 0 and 100).
        let grid = sample(image, bytesPerRow: 24, width: 6, height: 3, gridWidth: 3, gridHeight: 1)
        XCTAssertEqual(grid, [50, 70, 90])
        // A grid finer than the image: 4 cells over 2 px still read one pixel each (0, 0, 1, 1).
        let fine = sample(image, bytesPerRow: 24, width: 2, height: 1, gridWidth: 4, gridHeight: 1)
        XCTAssertEqual(fine, [0, 0, 10, 10])
    }

    func testRowPaddingIsSkipped() {
        let image = grayImage(width: 4, height: 4, bytesPerRow: 24, value: LumaGridTests.ramp)
        // Rounded means of each 2x2 block: (0+10+50+60+2)/4, (20+30+70+80+2)/4, (100+110+150+160+2)/4, (120+130+170+180+2)/4.
        let expected: [UInt8] = [30, 50, 130, 150]
        XCTAssertEqual(sample(image, bytesPerRow: 24, width: 4, height: 4, gridWidth: 2, gridHeight: 2, stride: 1), expected)
        XCTAssertEqual(sample(image, bytesPerRow: 24, width: 4, height: 4, gridWidth: 1, gridHeight: 1, stride: 1), [90], "the 0xFF padding never enters a mean")
    }

    func testCropPoolsOnlyInsideTheRect() {
        let image = grayImage(width: 4, height: 4, bytesPerRow: 16, value: LumaGridTests.ramp)
        let topRight = UVRect(u0: 0.5, v0: 0, u1: 1, v1: 0.5)
        // Pixels (2, 0), (3, 0), (2, 1), (3, 1): 20, 30, 70, 80.
        XCTAssertEqual(sample(image, bytesPerRow: 16, width: 4, height: 4, crop: topRight, gridWidth: 1, gridHeight: 1, stride: 1), [50])
        XCTAssertEqual(sample(image, bytesPerRow: 16, width: 4, height: 4, crop: topRight, gridWidth: 2, gridHeight: 2), [
            LumaGridTests.ramp(2, 0), LumaGridTests.ramp(3, 0), LumaGridTests.ramp(2, 1), LumaGridTests.ramp(3, 1),
        ])
        let bottom = UVRect(u0: 0, v0: 0.5, u1: 1, v1: 1)
        // Left cell: pixels (0, 2), (1, 2), (0, 3), (1, 3) = 100, 110, 150, 160.
        XCTAssertEqual(sample(image, bytesPerRow: 16, width: 4, height: 4, crop: bottom, gridWidth: 2, gridHeight: 1, stride: 1), [130, 150])
    }

    func testOutOfRangeCropClampsToTheImage() {
        let image = grayImage(width: 4, height: 4, bytesPerRow: 16, value: LumaGridTests.ramp)
        let wide = UVRect(u0: -1, v0: -1, u1: 2, v1: 2)
        // Columns: [-4, 0) clamps to pixel 0, [0, 4) is the image, [4, 8) clamps to pixel 3; rows: the same, middle cell
        // rows 0 and 2 at stride 2.
        let grid = sample(image, bytesPerRow: 16, width: 4, height: 4, crop: wide, gridWidth: 3, gridHeight: 3)
        XCTAssertEqual(grid.count, 9)
        XCTAssertEqual(grid[0], LumaGridTests.ramp(0, 0))
        XCTAssertEqual(grid[4], 60, "pixels (0, 0), (2, 0), (0, 2), (2, 2)")
        XCTAssertEqual(grid[8], LumaGridTests.ramp(3, 3))
    }

    func testInvalidInputsGiveZerosOrNothing() {
        let image = grayImage(width: 4, height: 4, bytesPerRow: 16, value: LumaGridTests.ramp)
        XCTAssertEqual(sample(Array(image.prefix(40)), bytesPerRow: 16, width: 4, height: 4, gridWidth: 2, gridHeight: 2), [0, 0, 0, 0], "buffer shorter than the image")
        XCTAssertEqual(sample(image, bytesPerRow: 8, width: 4, height: 4, gridWidth: 2, gridHeight: 2), [0, 0, 0, 0], "row narrower than width")
        XCTAssertEqual(sample(image, bytesPerRow: 16, width: 0, height: 4, gridWidth: 2, gridHeight: 2), [0, 0, 0, 0])
        XCTAssertEqual(sample(image, bytesPerRow: 16, width: 4, height: 4, gridWidth: 0, gridHeight: 2), [])
        let nan = UVRect(u0: .nan, v0: 0, u1: 1, v1: 1)
        XCTAssertEqual(sample(image, bytesPerRow: 16, width: 4, height: 4, crop: nan, gridWidth: 2, gridHeight: 1).count, 2, "a NaN crop clamps instead of trapping")
    }

    func testPortraitGridOfAThinStroke() {
        // A 1200 x 1600 white page with a 2 px black horizontal line on rows 801...802: every cell of exactly one grid row
        // sees it (8 px cells; the row at stride 2 starting at an even pixel reads row 802).
        let width = 1200
        let height = 1600
        var image = [UInt8](repeating: 255, count: width * height * 4)
        for y in 801...802 {
            for x in 0..<width {
                let i = (y * width + x) * 4
                image[i] = 0
                image[i + 1] = 0
                image[i + 2] = 0
            }
        }
        let size = LumaGrid.portraitSize
        let grid = sample(image, bytesPerRow: width * 4, width: width, height: height, gridWidth: size.width, gridHeight: size.height)
        XCTAssertEqual(grid.count, 144 * 192)
        var darkRows: [Int] = []
        for gy in 0..<size.height {
            var dark = 0
            for gx in 0..<size.width where 255 - Int(grid[gy * size.width + gx]) >= FrameDiffEngage.Config().cellDelta {
                dark += 1
            }
            if dark > 0 {
                XCTAssertEqual(dark, size.width, "row \(gy)")
                darkRows.append(gy)
            }
        }
        // 1600 / 192 = 8.33 px per row: row 96 covers [800, 808).
        XCTAssertEqual(darkRows, [96])
    }
}
