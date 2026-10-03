import CoreVideo
import DaylightKit
import Metal
import Vision
import XCTest
@testable import Daylight

/// The mask processor's IIR and feather blur against the Kit formulas (OverlayLayout.smoothed, featherWeights) on a
/// tiny synthetic mask, plus the CPU helpers. GPU tests skip without a Metal device.
final class MaskProcessorTests: XCTestCase {
    private let width = 8
    private let height = 4

    private func mask(_ value: (Int, Int) -> Float) -> [Float] {
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { values[y * width + x] = value(x, y) }
        }
        return values
    }

    private func assertClose(_ got: [Float], _ expected: [Float], _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, expected.count, message, file: file, line: line)
        let worst = zip(got, expected).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(worst, 0.005, "\(message): max error \(worst)\ngot \(got)\nexpected \(expected)", file: file, line: line)
    }

    func testFirstMaskIsBlurredAsIsAndTheSecondIsSmoothed() throws {
        let device = try OverlayFakes.device()
        let first = mask { x, _ in x < 4 ? 1 : 0 }
        let second = mask { x, y in x < 6 && y > 0 ? 1 : 0 }
        let a = try XCTUnwrap(MaskProcessor.makeMaskTexture(device: device, width: width, height: height, values: first))
        let b = try XCTUnwrap(MaskProcessor.makeMaskTexture(device: device, width: width, height: height, values: second))
        let processor = try MaskProcessor(device: device, smoothing: 0.6, feather: 2)
        let out1 = try processor.process(source: a, at: 1, coverage: 0.5)
        let got1 = try XCTUnwrap(MaskProcessor.readBack(out1.texture, device: device))
        assertClose(got1, OverlaySelfTest.reference(previous: nil, current: first, width: width, height: height, smoothing: 0.6, feather: 2).blurred, "first mask: no history, blur only")
        let out2 = try processor.process(source: b, at: 2, coverage: 0.6)
        let got2 = try XCTUnwrap(MaskProcessor.readBack(out2.texture, device: device))
        let expected = OverlaySelfTest.reference(previous: first, current: second, width: width, height: height, smoothing: 0.6, feather: 2)
        assertClose(got2, expected.blurred, "second mask: IIR 0.6 then the 5-tap blur")
        XCTAssertEqual(expected.smoothed[0], Float(0.6 * 1 + 0.4 * 0), accuracy: 1e-6, "OverlayLayout.smoothed at (0, 0)")
        XCTAssertFalse(out1.texture === out2.texture, "rotating outputs")
        XCTAssertEqual(processor.latest?.at, 2)
        XCTAssertEqual(processor.latest?.coverage, 0.6)
    }

    func testRadiusZeroAndNoSmoothingPassTheMaskThrough() throws {
        let device = try OverlayFakes.device()
        let values = mask { x, y in Float((x + y) % 2) }
        let source = try XCTUnwrap(MaskProcessor.makeMaskTexture(device: device, width: width, height: height, values: values))
        let processor = try MaskProcessor(device: device, smoothing: 0, feather: 0)
        _ = try processor.process(source: source, at: 0, coverage: 0.5)
        let out = try processor.process(source: source, at: 0.1, coverage: 0.5)
        assertClose(try XCTUnwrap(MaskProcessor.readBack(out.texture, device: device)), values, "featherWeights(0) = [1], smoothing 0")
        XCTAssertEqual(OverlayLayout.featherWeights(radius: 0), [1])
    }

    func testSmoothingSettlesTowardsTheNewMask() throws {
        let device = try OverlayFakes.device()
        let ones = try XCTUnwrap(MaskProcessor.makeMaskTexture(device: device, width: width, height: height, values: mask { _, _ in 1 }))
        let zeros = try XCTUnwrap(MaskProcessor.makeMaskTexture(device: device, width: width, height: height, values: mask { _, _ in 0 }))
        let processor = try MaskProcessor(device: device, smoothing: 0.5, feather: 1)
        _ = try processor.process(source: ones, at: 0, coverage: 1)
        var expected = 1.0
        for i in 1...3 {
            let out = try processor.process(source: zeros, at: Double(i), coverage: 0)
            expected = OverlayLayout.smoothed(previous: expected, new: 0, smoothing: 0.5)
            let got = try XCTUnwrap(MaskProcessor.readBack(out.texture, device: device))
            XCTAssertEqual(Double(got[0]), expected, accuracy: 0.005, "step \(i)")
        }
        XCTAssertEqual(expected, 0.125, accuracy: 1e-12)
    }

    func testVisionShapedBuffersTakeTheCacheOrTheCopyPath() throws {
        let device = try OverlayFakes.device()
        for iosurface in [true, false] {
            let buffer = OverlayFakes.maskBuffer(width: 16, height: 8, value: 0, iosurface: iosurface)
            OverlayFakes.fill(buffer) { x, _ in x < 8 ? 255 : 0 }
            let processor = try MaskProcessor(device: device, smoothing: 0, feather: 0)
            let out = try processor.process(mask: buffer, at: 0, coverage: PersonSegmenter.coverage(of: buffer))
            let got = try XCTUnwrap(MaskProcessor.readBack(out.texture, device: device))
            XCTAssertEqual(got.count, 16 * 8)
            XCTAssertEqual(got[0], 1, accuracy: 0.005, "iosurface=\(iosurface)")
            XCTAssertEqual(got[15], 0, accuracy: 0.005, "iosurface=\(iosurface)")
            XCTAssertEqual(out.coverage, 0.5, accuracy: 1e-9)
        }
    }

    func testCoverageSamplesEveryFourthPixel() {
        let buffer = OverlayFakes.maskBuffer(width: 64, height: 64, value: 0, iosurface: false)
        OverlayFakes.fill(buffer) { x, _ in x < 32 ? 255 : 0 }
        XCTAssertEqual(PersonSegmenter.coverage(of: buffer), 0.5, accuracy: 1e-9)
        XCTAssertEqual(PersonSegmenter.coverage(of: OverlayFakes.maskBuffer(value: 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(PersonSegmenter.coverage(of: OverlayFakes.maskBuffer(value: 255)), 1, accuracy: 1e-9)
        XCTAssertEqual(PersonSegmenter.coverage(of: SelfTest.gradientBuffer(width: 8, height: 8)!), 1, "a non-mask format counts as full coverage")
    }

    func testHalfFloatDecoding() {
        XCTAssertEqual(MaskProcessor.halfToFloat(0x0000), 0)
        XCTAssertEqual(MaskProcessor.halfToFloat(0x3C00), 1)
        XCTAssertEqual(MaskProcessor.halfToFloat(0x3800), 0.5)
        XCTAssertEqual(MaskProcessor.halfToFloat(0xC000), -2)
        XCTAssertEqual(MaskProcessor.halfToFloat(0x3555), 0.333251953125)
        XCTAssertEqual(MaskProcessor.halfToFloat(0x0001), powf(2, -24))
    }

    func testVisionQualityLevels() {
        XCTAssertEqual(VisionPersonEngine.level(.fast), .fast)
        XCTAssertEqual(VisionPersonEngine.level(.balanced), .balanced)
        XCTAssertEqual(VisionPersonEngine.level(.accurate), .accurate)
    }
}
