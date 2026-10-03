import CoreMedia
import CoreVideo
import DaylightKit
import Foundation
import XCTest
@testable import Daylight

/// SPEC F3 with the committed fixtures: six BGRA 320x240 IOSurface-backed frames in PTS order from
/// `testsrc-320x240-6f.h264`; a second SPS (160x120) takes the format-change path; the key-frame gate; D41's
/// per-access-unit block buffer. Skipped (with the status logged) when the runner has no H.264 decoder.
final class H264DecoderTests: XCTestCase {
    let queue = DispatchQueue(label: "com.twelve.daylight.tests.decode")

    struct AccessUnit {
        var annexB: [UInt8]
        var keyFrame: Bool
    }

    static func fixture(_ name: String) throws -> [UInt8] {
        guard let url = Bundle(for: H264DecoderTests.self).url(forResource: name, withExtension: "h264") else {
            throw XCTSkip("fixture \(name).h264 is not in the test bundle (XcodeGen puts unknown extensions in the resources phase)")
        }
        return Array(try Data(contentsOf: url))
    }

    /// Groups a raw Annex-B stream into access units: every slice NAL (1 or 5) ends one, SEI and AUD before it belong
    /// to it, SPS and PPS are left out (they go through `setParameterSets`).
    static func accessUnits(_ stream: [UInt8]) -> [AccessUnit] {
        var units: [AccessUnit] = []
        var pending: [UInt8] = []
        for range in AnnexB.nalUnits(stream) {
            let nal = Array(stream[range])
            let type = AnnexB.nalType(nal[0])
            switch type {
            case AnnexB.nalTypeSPS, AnnexB.nalTypePPS:
                continue
            case AnnexB.nalTypeIDR, AnnexB.nalTypeNonIDRSlice:
                units.append(AccessUnit(annexB: pending + [0, 0, 0, 1] + nal, keyFrame: type == AnnexB.nalTypeIDR))
                pending = []
            default:
                pending += [0, 0, 0, 1] + nal
            }
        }
        return units
    }

    /// Creates the decoder with the fixture's parameter sets or skips when the runner cannot decode.
    private func makeDecoder(sps: [UInt8], pps: [UInt8]) throws -> H264Decoder {
        let decoder = H264Decoder(queue: queue)
        do {
            try decoder.setParameterSets(sps: [sps], pps: [pps])
        } catch let error as H264DecoderError {
            if case let .sessionCreate(status) = error {
                print("h264-decoder: VTDecompressionSessionCreate returned \(status) on this runner; skipping")
                throw XCTSkip("no H.264 decoder on this runner (VTDecompressionSessionCreate \(status))")
            }
            throw error
        }
        return decoder
    }

    func testFixtureShapeMatchesThePlan() throws {
        let stream = try H264DecoderTests.fixture("testsrc-320x240-6f")
        XCTAssertEqual(stream.count, 7846)
        let types = AnnexB.nalUnits(stream).map { AnnexB.nalType(stream[$0.lowerBound]) }
        XCTAssertEqual(types, [7, 8, 6, 5, 1, 1, 7, 8, 5, 1, 1])
        let sets = AnnexB.parameterSets(stream)
        XCTAssertEqual(sets.sps.count, 2)
        XCTAssertEqual(sets.pps.count, 2)
        XCTAssertEqual(sets.sps[0], sets.sps[1], "repeat-headers=1 repeats the same SPS")
        XCTAssertEqual(Hex.encode(sets.sps[0]), "6742c00dd90141fb0110000003001000000303c0f142a480")
        XCTAssertEqual(Hex.encode(sets.pps[0]), "68cb83cb20")
        let units = H264DecoderTests.accessUnits(stream)
        XCTAssertEqual(units.count, 6)
        XCTAssertEqual(units.map { $0.keyFrame }, [true, false, false, true, false, false])
    }

    func testSixFramesDecodeToBGRAIOSurfacesInOrder() throws {
        let stream = try H264DecoderTests.fixture("testsrc-320x240-6f")
        let sets = AnnexB.parameterSets(stream)
        let decoder = try makeDecoder(sps: sets.sps[0], pps: sets.pps[0])
        XCTAssertEqual(decoder.dimensions?.width, 320)
        XCTAssertEqual(decoder.dimensions?.height, 240)
        print("h264-decoder: hardware=\(decoder.usingHardware.map { "\($0)" } ?? "unknown")")
        var frames: [(width: Int, height: Int, format: OSType, surface: Bool, pts: UInt64)] = []
        decoder.onFrame = { buffer, pts in
            frames.append((CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), CVPixelBufferGetPixelFormatType(buffer), CVPixelBufferGetIOSurface(buffer) != nil, pts))
        }
        for (index, unit) in H264DecoderTests.accessUnits(stream).enumerated() {
            try decoder.decode(annexB: unit.annexB, ptsUs: UInt64(index) * 33_333, keyFrame: unit.keyFrame)
        }
        XCTAssertEqual(frames.count, 6)
        XCTAssertEqual(decoder.framesDecoded, 6)
        XCTAssertEqual(decoder.framesDropped, 0)
        XCTAssertEqual(decoder.decodeErrors, 0)
        XCTAssertEqual(decoder.outOfOrderFrames, 0)
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(frame.width, 320)
            XCTAssertEqual(frame.height, 240)
            XCTAssertEqual(frame.format, kCVPixelFormatType_32BGRA)
            XCTAssertTrue(frame.surface, "IOSurface-backed output")
            XCTAssertEqual(frame.pts, UInt64(index) * 33_333)
        }
        XCTAssertFalse(decoder.needsKeyFrame)
    }

    func testSecondSPSTakesTheFormatChangePath() throws {
        let big = try H264DecoderTests.fixture("testsrc-320x240-6f")
        let small = try H264DecoderTests.fixture("testsrc-160x120-2f")
        let bigSets = AnnexB.parameterSets(big)
        let smallSets = AnnexB.parameterSets(small)
        XCTAssertNotEqual(bigSets.sps[0], smallSets.sps[0])
        let decoder = try makeDecoder(sps: bigSets.sps[0], pps: bigSets.pps[0])
        let firstUnits = H264DecoderTests.accessUnits(big)
        try decoder.decode(annexB: firstUnits[0].annexB, ptsUs: 0, keyFrame: true)
        XCTAssertEqual(decoder.framesDecoded, 1)
        try decoder.setParameterSets(sps: [smallSets.sps[0]], pps: [smallSets.pps[0]])
        XCTAssertEqual(decoder.formatChanges, 1, "a different SPS is a format change (accepted or a new session)")
        XCTAssertEqual(decoder.dimensions?.width, 160)
        XCTAssertEqual(decoder.dimensions?.height, 120)
        print("h264-decoder: sessions created after the SPS change = \(decoder.sessionsCreated)")
        var sizes: [(Int, Int)] = []
        decoder.onFrame = { buffer, _ in sizes.append((CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))) }
        for (index, unit) in H264DecoderTests.accessUnits(small).enumerated() {
            try decoder.decode(annexB: unit.annexB, ptsUs: 1_000_000 + UInt64(index) * 33_333, keyFrame: unit.keyFrame)
        }
        XCTAssertEqual(sizes.count, 2)
        XCTAssertEqual(sizes.first?.0, 160)
        XCTAssertEqual(sizes.first?.1, 120)
    }

    func testNonKeyFramesAreDroppedUntilAKeyFrame() throws {
        let stream = try H264DecoderTests.fixture("testsrc-320x240-6f")
        let sets = AnnexB.parameterSets(stream)
        let decoder = try makeDecoder(sps: sets.sps[0], pps: sets.pps[0])
        let units = H264DecoderTests.accessUnits(stream)
        var frames = 0
        decoder.onFrame = { _, _ in frames += 1 }
        XCTAssertTrue(decoder.needsKeyFrame)
        try decoder.decode(annexB: units[1].annexB, ptsUs: 10, keyFrame: false)
        try decoder.decode(annexB: units[2].annexB, ptsUs: 20, keyFrame: false)
        XCTAssertEqual(frames, 0)
        XCTAssertEqual(decoder.framesDropped, 2)
        XCTAssertNotNil(decoder.keyFrameWaitStart, "the wait for a key frame is armed")
        XCTAssertFalse(decoder.shouldRestartServer(now: decoder.keyFrameWaitStart! + 11.9))
        XCTAssertTrue(decoder.shouldRestartServer(now: decoder.keyFrameWaitStart! + 12), "row 27: restart after 12 s without a key frame")
        try decoder.decode(annexB: units[3].annexB, ptsUs: 30, keyFrame: true)
        XCTAssertEqual(frames, 1)
        XCTAssertFalse(decoder.needsKeyFrame)
        XCTAssertNil(decoder.keyFrameWaitStart)
        XCTAssertEqual(H264Decoder.keyFrameRestartSeconds, 12)
    }

    func testDecodeWithoutParameterSetsThrows() {
        let decoder = H264Decoder(queue: queue)
        XCTAssertThrowsError(try decoder.decode(annexB: [0, 0, 0, 1, 0x65, 0x88], ptsUs: 0, keyFrame: true)) { error in
            XCTAssertEqual(error as? H264DecoderError, .noFormat)
        }
        XCTAssertThrowsError(try decoder.setParameterSets(sps: [], pps: [[0x68]])) { error in
            XCTAssertEqual(error as? H264DecoderError, .noParameterSets)
        }
    }

    /// Finder W4(b): a frame without a usable format (no config, or rejected parameter sets) threw `.noFormat` without
    /// arming the key-frame wait, so `shouldRestartServer` could never become true and row 27 never fired. Before the
    /// fix `keyFrameWaitStart` stays nil and the 12 s check is false.
    func testDecodeWithoutAFormatArmsTheRow27Wait() {
        let now = Locked(500.0)
        let decoder = H264Decoder(queue: queue, clock: { now.withLock { $0 } })
        XCTAssertThrowsError(try decoder.decode(annexB: [0, 0, 0, 1, 0x41, 0x9A], ptsUs: 0, keyFrame: false)) { error in
            XCTAssertEqual(error as? H264DecoderError, .noFormat)
        }
        XCTAssertEqual(decoder.keyFrameWaitStart, 500, "the wait is armed on the injected clock")
        XCTAssertEqual(decoder.decodeErrors, 1)
        XCTAssertFalse(decoder.shouldRestartServer(now: 511.9))
        XCTAssertTrue(decoder.shouldRestartServer(now: 512), "row 27: restart after 12 s without a decodable frame")
        now.withLock { $0 = 512 }
        XCTAssertTrue(decoder.shouldRestartServer(), "the default reads the injected clock")
        decoder.resetKeyFrameWait()
        XCTAssertFalse(decoder.shouldRestartServer())
    }

    /// Finder W5: after a demuxer reset the decoder must wait for a key frame. Before the fix there was no way to arm
    /// the gate from outside, so a delta frame right after the reset was decoded against lost references.
    func testAwaitKeyFrameDropsDeltaFramesUntilTheNextKeyFrame() throws {
        let stream = try H264DecoderTests.fixture("testsrc-320x240-6f")
        let sets = AnnexB.parameterSets(stream)
        let decoder = try makeDecoder(sps: sets.sps[0], pps: sets.pps[0])
        let units = H264DecoderTests.accessUnits(stream)
        var frames = 0
        decoder.onFrame = { _, _ in frames += 1 }
        try decoder.decode(annexB: units[0].annexB, ptsUs: 0, keyFrame: true)
        try decoder.decode(annexB: units[1].annexB, ptsUs: 10, keyFrame: false)
        XCTAssertEqual(frames, 2)
        XCTAssertFalse(decoder.needsKeyFrame)
        decoder.awaitKeyFrame()
        XCTAssertTrue(decoder.needsKeyFrame)
        XCTAssertEqual(decoder.decodeErrors, 0, "not an error")
        try decoder.decode(annexB: units[2].annexB, ptsUs: 20, keyFrame: false)
        XCTAssertEqual(frames, 2, "the delta frame after the reset is dropped")
        XCTAssertEqual(decoder.framesDropped, 1)
    }

    func testSampleBufferOwnsACopyOfTheAccessUnit() throws {
        let stream = try H264DecoderTests.fixture("testsrc-320x240-6f")
        let sets = AnnexB.parameterSets(stream)
        let format = try H264Decoder.makeFormatDescription(parameterSets: [sets.sps[0], sets.pps[0]])
        let avcc = AnnexB.toAVCC(H264DecoderTests.accessUnits(stream)[0].annexB)
        let sample = try H264Decoder.makeSampleBuffer(avcc: avcc, ptsUs: 123_456, format: format)
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return XCTFail("no block buffer") }
        XCTAssertEqual(CMBlockBufferGetDataLength(block), avcc.count)
        var copied = [UInt8](repeating: 0, count: avcc.count)
        let status = copied.withUnsafeMutableBytes { raw in CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: avcc.count, destination: raw.baseAddress!) }
        XCTAssertEqual(status, kCMBlockBufferNoErr)
        XCTAssertEqual(copied, avcc, "the block buffer holds its own copy of the bytes")
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).value, 123_456)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).timescale, 1_000_000)
        XCTAssertTrue(CMSampleBufferDataIsReady(sample))
    }
}
