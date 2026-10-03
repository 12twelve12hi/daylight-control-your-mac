import CoreMedia
import CoreVideo
import DaylightKit
import Foundation
import os
import QuartzCore
import VideoToolbox

enum H264DecoderError: Error, Equatable {
    case noParameterSets
    case formatDescription(OSStatus)
    case sessionCreate(OSStatus)
    case noFormat
    case blockBuffer(OSStatus)
    case sampleBuffer(OSStatus)
    case decode(OSStatus)
    case output(OSStatus)

    var statusCode: OSStatus? {
        switch self {
        case .noParameterSets, .noFormat: return nil
        case let .formatDescription(s), let .sessionCreate(s), let .blockBuffer(s), let .sampleBuffer(s), let .decode(s), let .output(s): return s
        }
    }
}

/// VideoToolbox H.264 decode into BGRA, IOSurface-backed, Metal-compatible pixel buffers (ARCHITECTURE 6 item 5, SPEC
/// F3, D41). The caller runs everything on one serial queue (mirror.queue). Each access unit gets a fresh block buffer
/// that owns its memory (never reused); decoding is synchronous (flags `[]`), so the output handler has run when
/// `decode` returns and the frame is published in decode order.
final class H264Decoder {
    static let log = Logger(subsystem: "com.twelve.daylight", category: "decode")
    /// SPEC 13.3 row 27: after an error, drop until a key frame; restart the server when none arrives within 12 s.
    static let keyFrameRestartSeconds: Double = 12

    let queue: DispatchQueue
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var formatDescription: CMFormatDescription?
    private var session: VTDecompressionSession?
    private(set) var needsKeyFrame = true
    private(set) var keyFrameWaitStart: Double?
    private(set) var sessionsCreated = 0
    private(set) var formatChanges = 0
    private(set) var framesDecoded: UInt64 = 0
    private(set) var framesDropped: UInt64 = 0
    private(set) var decodeErrors: UInt64 = 0
    private(set) var outOfOrderFrames: UInt64 = 0
    private(set) var usingHardware: Bool?
    private(set) var lastPtsUs: UInt64?
    private var loggedOutOfOrder = false

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit {
        invalidate()
    }

    /// The coded size of the current format description.
    var dimensions: (width: Int, height: Int)? {
        guard let format = formatDescription else { return nil }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        return (Int(size.width), Int(size.height))
    }

    // MARK: Parameter sets

    /// Builds the format description (NAL length 4). With a live session: keep it when it accepts the new format,
    /// otherwise wait, invalidate and recreate.
    func setParameterSets(sps: [[UInt8]], pps: [[UInt8]]) throws {
        guard !sps.isEmpty, !pps.isEmpty else { throw H264DecoderError.noParameterSets }
        let sets = sps + pps
        let newFormat = try H264Decoder.makeFormatDescription(parameterSets: sets)
        if let current = session {
            if VTDecompressionSessionCanAcceptFormatDescription(current, formatDescription: newFormat) {
                formatDescription = newFormat
                formatChanges += 1
                onLog?("decoder accepted the new parameter sets without a new session")
                return
            }
            VTDecompressionSessionWaitForAsynchronousFrames(current)
            VTDecompressionSessionInvalidate(current)
            session = nil
            formatChanges += 1
            onLog?("decoder session recreated for new parameter sets")
        }
        formatDescription = newFormat
        try createSession(format: newFormat)
    }

    static func makeFormatDescription(parameterSets sets: [[UInt8]]) throws -> CMFormatDescription {
        let buffers: [UnsafeMutableBufferPointer<UInt8>] = sets.map { set in
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(1, set.count))
            _ = buffer.initialize(from: set)
            return buffer
        }
        defer { for buffer in buffers { buffer.deallocate() } }
        let pointers: [UnsafePointer<UInt8>] = buffers.map { UnsafePointer($0.baseAddress!) }
        let sizes: [Int] = sets.map { $0.count }
        var format: CMFormatDescription?
        let status: OSStatus = pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointerBuffer.baseAddress!,
                    parameterSetSizes: sizeBuffer.baseAddress!,
                    nalUnitHeaderLength: Int32(AnnexB.avccLengthPrefix),
                    formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let created = format else { throw H264DecoderError.formatDescription(status) }
        return created
    }

    private func createSession(format: CMFormatDescription) throws {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created)
        guard status == noErr, let newSession = created else { throw H264DecoderError.sessionCreate(status) }
        session = newSession
        sessionsCreated += 1
        needsKeyFrame = true
        keyFrameWaitStart = nil
        var value: CFTypeRef?
        if VTSessionCopyProperty(newSession, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: kCFAllocatorDefault, valueOut: &value) == noErr,
           let number = value as? NSNumber {
            usingHardware = number.boolValue
        } else {
            usingHardware = nil
        }
        if let size = dimensions {
            onLog?("decoder session \(sessionsCreated): \(size.width)x\(size.height) BGRA hardware=\(usingHardware.map { "\($0)" } ?? "unknown")")
        }
    }

    // MARK: Frames

    func decode(annexB: [UInt8], ptsUs: UInt64, keyFrame: Bool) throws {
        try annexB.withUnsafeBytes { raw in try decode(annexB: raw, ptsUs: ptsUs, keyFrame: keyFrame) }
    }

    /// Decodes one access unit synchronously and publishes the frame through `onFrame`. Frames that arrive while a
    /// key frame is awaited are dropped (counted). A decode error arms the key-frame wait.
    func decode(annexB: UnsafeRawBufferPointer, ptsUs: UInt64, keyFrame: Bool) throws {
        guard let format = formatDescription, let session = session else { throw H264DecoderError.noFormat }
        if needsKeyFrame && !keyFrame && !AnnexB.containsIDR(annexB) {
            framesDropped += 1
            if keyFrameWaitStart == nil { keyFrameWaitStart = CACurrentMediaTime() }
            return
        }
        let avcc = AnnexB.toAVCC(annexB)
        guard !avcc.isEmpty else {
            framesDropped += 1
            return
        }
        let sampleBuffer = try H264Decoder.makeSampleBuffer(avcc: avcc, ptsUs: ptsUs, format: format)
        var infoFlags = VTDecodeInfoFlags()
        var outputStatus: OSStatus = noErr
        var produced: CVPixelBuffer?
        let decodeStatus = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: &infoFlags) { status, _, imageBuffer, _, _ in
            outputStatus = status
            if status == noErr, let image = imageBuffer { produced = image }
        }
        if decodeStatus != noErr {
            noteError()
            throw H264DecoderError.decode(decodeStatus)
        }
        if outputStatus != noErr {
            noteError()
            throw H264DecoderError.output(outputStatus)
        }
        guard let frame = produced else {
            // Nothing produced and no error (dropped by the decoder): keep waiting.
            framesDropped += 1
            return
        }
        needsKeyFrame = false
        keyFrameWaitStart = nil
        framesDecoded += 1
        if let last = lastPtsUs, ptsUs < last {
            outOfOrderFrames += 1
            if !loggedOutOfOrder {
                loggedOutOfOrder = true
                onLog?("out-of-order PTS from the encoder: \(ptsUs) after \(last) (LOOSE_ENDS D13)")
            }
        }
        lastPtsUs = ptsUs
        onFrame?(frame, ptsUs)
    }

    /// A block buffer that owns a fresh copy of this access unit (D41), wrapped in a ready sample buffer with the PTS.
    static func makeSampleBuffer(avcc: [UInt8], ptsUs: UInt64, format: CMFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let blockBuffer = block else { throw H264DecoderError.blockBuffer(status) }
        status = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == kCMBlockBufferNoErr else { throw H264DecoderError.blockBuffer(status) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTimeMake(value: Int64(ptsUs), timescale: 1_000_000), decodeTimeStamp: .invalid)
        var sampleSize = avcc.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample)
        guard status == noErr, let sampleBuffer = sample else { throw H264DecoderError.sampleBuffer(status) }
        return sampleBuffer
    }

    private func noteError() {
        decodeErrors += 1
        needsKeyFrame = true
        if keyFrameWaitStart == nil { keyFrameWaitStart = CACurrentMediaTime() }
    }

    /// Row 27: true when the decoder has waited `keyFrameRestartSeconds` for a key frame that never came.
    func shouldRestartServer(now: Double = CACurrentMediaTime()) -> Bool {
        guard needsKeyFrame, let start = keyFrameWaitStart else { return false }
        return now - start >= H264Decoder.keyFrameRestartSeconds
    }

    /// Forgets the key-frame wait (after a server restart).
    func resetKeyFrameWait() {
        keyFrameWaitStart = nil
    }

    func invalidate() {
        if let current = session {
            VTDecompressionSessionWaitForAsynchronousFrames(current)
            VTDecompressionSessionInvalidate(current)
            session = nil
        }
        formatDescription = nil
        needsKeyFrame = true
        keyFrameWaitStart = nil
    }

    var hasSession: Bool { return session != nil }

    var diagnostics: [String: String] {
        var d: [String: String] = [:]
        d["decoder.frames"] = "\(framesDecoded)"
        d["decoder.dropped"] = "\(framesDropped)"
        d["decoder.errors"] = "\(decodeErrors)"
        d["decoder.sessions"] = "\(sessionsCreated)"
        d["decoder.formatChanges"] = "\(formatChanges)"
        d["decoder.outOfOrder"] = "\(outOfOrderFrames)"
        d["decoder.hardware"] = usingHardware.map { "\($0)" } ?? "unknown"
        if let size = dimensions { d["decoder.size"] = "\(size.width)x\(size.height)" }
        d["decoder.needsKeyFrame"] = "\(needsKeyFrame)"
        return d
    }
}
