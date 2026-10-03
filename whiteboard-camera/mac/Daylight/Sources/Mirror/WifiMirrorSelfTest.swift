import CoreMedia
import CoreVideo
import DaylightKit
import Foundation
import VideoToolbox

/// A tiny H.264 stream made on this Mac for `--self-test` (the app bundle carries no H.264 bytes): one solid-colour
/// BGRA frame encoded by VideoToolbox, returned as the Annex-B codec config (SPS and PPS) and one key frame, the two
/// payloads a tablet sends after MIRROR_HELLO and the session packet (PROTOCOL 14.2).
enum SolidColourStream {
    struct Encoded {
        var config: [UInt8]
        var keyFrame: [UInt8]
    }

    static let startCode: [UInt8] = [0, 0, 0, 1]

    /// AVCC (4-byte big-endian lengths) to Annex-B (start codes).
    static func annexB(fromAVCC avcc: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i + 4 <= avcc.count {
            let n = Int(avcc[i]) << 24 | Int(avcc[i + 1]) << 16 | Int(avcc[i + 2]) << 8 | Int(avcc[i + 3])
            i += 4
            guard n > 0, i + n <= avcc.count else { break }
            out += startCode
            out += avcc[i..<(i + n)]
            i += n
        }
        return out
    }

    static func pixelBuffer(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var created: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created) == kCVReturnSuccess, let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                var offset = y * stride
                for _ in 0..<width {
                    bytes[offset] = b
                    bytes[offset + 1] = g
                    bytes[offset + 2] = r
                    bytes[offset + 3] = 255
                    offset += 4
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Encodes one forced key frame; `.failure` carries the reason (reported as a skip, never a pass).
    static func make(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> Result<Encoded, String> {
        guard let frame = pixelBuffer(width: width, height: height, r: r, g: g, b: b) else { return .failure("CVPixelBufferCreate failed") }
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let session = created else { return .failure("VTCompressionSessionCreate returned \(status)") }
        defer { VTCompressionSessionInvalidate(session) }
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        _ = VTCompressionSessionPrepareToEncodeFrames(session)
        let output = Locked<(OSStatus, CMSampleBuffer?)?>(nil)
        let options: [CFString: Any] = [kVTEncodeFrameOptionKey_ForceKeyFrame: true]
        let properties = options as CFDictionary
        let encodeStatus = VTCompressionSessionEncodeFrame(session, imageBuffer: frame, presentationTimeStamp: CMTime(value: 0, timescale: 1_000_000), duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { status, _, sample in
            output.withLock { $0 = (status, sample) }
        }
        guard encodeStatus == noErr else { return .failure("VTCompressionSessionEncodeFrame returned \(encodeStatus)") }
        _ = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard let result = output.withLock({ $0 }) else { return .failure("the encoder produced no output") }
        guard result.0 == noErr, let sample = result.1 else { return .failure("encoder output status \(result.0)") }
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return .failure("no format description") }
        var config: [UInt8] = []
        var count = 0
        var index = 0
        repeat {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            var nalLength: Int32 = 0
            let s = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength)
            guard s == noErr, let p = pointer else { return .failure("parameter set \(index): \(s)") }
            config += startCode
            config += Array(UnsafeBufferPointer(start: p, count: size))
            index += 1
        } while index < count
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return .failure("no data buffer") }
        let length = CMBlockBufferGetDataLength(block)
        var avcc = [UInt8](repeating: 0, count: length)
        let copy = avcc.withUnsafeMutableBytes { raw in CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!) }
        guard copy == kCMBlockBufferNoErr else { return .failure("CMBlockBufferCopyDataBytes returned \(copy)") }
        let keyFrame = annexB(fromAVCC: avcc)
        guard AnnexB.containsIDR(keyFrame) else { return .failure("the encoded frame has no IDR slice") }
        return .success(Encoded(config: config, keyFrame: keyFrame))
    }
}

extension SelfTest {
    /// The Wi-Fi mirror probe: a role `ink` client on the real listener announces MIRROR_STATUS, gets START, streams
    /// MIRROR_HELLO, a session packet, the config and one key frame through the same ingest the app wires; the frame
    /// decodes and the pipeline composes it into the canvas slot.
    static func wifiMirrorProbe(port: UInt16, wifi: WifiMirrorSource, pipeline: FramePipeline, router: InkRouter, inkQueue: DispatchQueue, lastFrame: Locked<CVPixelBuffer?>, report: Report) {
        let name = "wifi mirror: composed frame"
        let colour: (r: UInt8, g: UInt8, b: UInt8) = (30, 150, 220)
        let width = 240, height = 320
        let encoded: SolidColourStream.Encoded
        switch SolidColourStream.make(width: width, height: height, r: colour.r, g: colour.g, b: colour.b) {
        case let .success(stream): encoded = stream
        case let .failure(reason):
            report.note("SKIP \(name) (no H.264 encoder on this machine: \(reason))")
            return
        }
        report.note("wifi mirror: encoded \(width)x\(height) config \(encoded.config.count) bytes key frame \(encoded.keyFrame.count) bytes")
        let client = Client(url: URL(string: "ws://127.0.0.1:\(port)/ink")!)
        client.connect()
        client.sendMessage(.handshake(canvasWidth: 1200, canvasHeight: 1600, dpi: 300, name: "ink;self-test-wifi-mirror;Self-test tablet"))
        guard client.wait(where: { $0.header.knownOpcode == .handshakeAck }, timeout: 5) != nil else {
            report.check(name, false, "no HANDSHAKE_ACK for the ink client; \(client.errorText ?? "")")
            client.close()
            return
        }
        func send(_ message: MirrorStream.Message) {
            client.sendRaw(Data(MirrorStream.encode(message, timestampUs: InkConnection.nowUs()))) { _ in }
        }
        send(.status(MirrorStream.Status(state: .idle, flags: [], fpsX10: 0, width: 0, height: 0, bitrateBps: 0, sentBps: 0)))
        let start = client.wait(where: { MirrorStream.peekOpcode($0.bytes) == MirrorStream.opcodeControl }, timeout: 3)
        var started = false
        if let start = start, let decoded = try? MirrorStream.decode(start.bytes), case let .control(control) = decoded.message {
            started = control.command == .start
            report.check("wifi mirror: MIRROR_CONTROL START after MIRROR_STATUS", started, WifiMirrorSource.describe(control))
        } else {
            report.check("wifi mirror: MIRROR_CONTROL START after MIRROR_STATUS", false, "none within 3 s")
        }
        send(.hello(deviceName: "Self-test", codecID: ScrcpyDemuxer.codecH264))
        send(.packet(.session(width: UInt32(width), height: UInt32(height))))
        send(.status(MirrorStream.Status(state: .streaming, flags: [.projectionHeld], fpsX10: 300, width: UInt16(width), height: UInt16(height), bitrateBps: 7_000_000, sentBps: 0)))
        send(.packet(.media(ptsFlags: ScrcpyDemuxer.flagConfig, annexB: encoded.config)))
        send(.packet(.media(ptsFlags: ScrcpyDemuxer.flagKeyFrame | 33_333, annexB: encoded.keyFrame)))
        var decoded = false
        for _ in 0..<60 {
            if wifi.frameSeed > 0 { decoded = true; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        report.check("wifi mirror: key frame decoded through the ingest", decoded, "frameSeed=\(wifi.frameSeed) status=\(MirrorController.describe(wifi.status))")
        guard decoded, let latest = wifi.latest() else {
            report.check(name, false, "no decoded frame")
            client.close()
            return
        }
        report.note("wifi mirror: frame \(CVPixelBufferGetWidth(latest.buffer))x\(CVPixelBufferGetHeight(latest.buffer)) orientation \(latest.orientation) uv \(latest.uv)")
        pipeline.setMirrorSource(wifi)
        switchSource(.mirror, pipeline: pipeline, router: router, inkQueue: inkQueue)
        var hit = false
        var seen = "no frame"
        for _ in 0..<60 {
            if let frame = lastFrame.withLock({ $0 }), CVPixelBufferGetWidth(frame) == 1920 {
                let centre = pixel(frame, 640, 540)
                seen = describe(centre)
                if abs(Int(centre.r) - Int(colour.r)) <= 24 && abs(Int(centre.g) - Int(colour.g)) <= 24 && abs(Int(centre.b) - Int(colour.b)) <= 24 { hit = true; break }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        report.check(name, hit && started, "centre \(seen), expected about rgb \(String(format: "%02X%02X%02X", colour.r, colour.g, colour.b))")
        switchSource(.web, pipeline: pipeline, router: router, inkQueue: inkQueue)
        client.close()
    }
}
