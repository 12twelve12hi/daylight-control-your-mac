import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import os

let DaylightFrameRate: Int = DaylightExtensionRules.frameRate
let DaylightFrameWidth: Int32 = DaylightExtensionRules.frameWidth
let DaylightFrameHeight: Int32 = DaylightExtensionRules.frameHeight

let extensionLog = Logger(subsystem: "com.twelve.daylight", category: "extension")

/// One device "Daylight Camera" with a source stream (what Zoom reads) and a sink stream (what Daylight.app feeds).
/// Shape: OBS OBSCameraDeviceSource.swift (timer-driven consume at 3x the frame rate) with Daylight names, plus the
/// ARCHITECTURE 2.4 additions: the compile-time consume strategy, the viewers property, the forward-only-when-watched
/// rule and `notifyScheduledOutputChanged` on every consumed buffer. Nothing here blocks.
final class DaylightDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!

    private var streamSource: DaylightSourceStream!
    private var streamSink: DaylightSinkStream!

    /// Viewers consuming the source stream (Zoom, Meet, FaceTime).
    private var streamingCounter: UInt32 = 0
    /// Hosts that opened the sink (at most one in practice).
    private var streamingSinkCounter: UInt32 = 0

    private var placeholderTimer: DispatchSourceTimer?
    private var consumeBufferTimer: DispatchSourceTimer?

    private let timerQueue = DispatchQueue(
        label: "com.twelve.daylight.camera.timer",
        qos: .userInteractive,
        attributes: [],
        autoreleaseFrequency: .workItem,
        target: .global(qos: .userInteractive))

    private var videoDescription: CMFormatDescription!
    private var bufferPool: CVPixelBufferPool!
    private var bufferAuxAttributes: NSDictionary!

    private(set) var sinkStarted = false

    /// Debug-only consume statistics (ARCHITECTURE 2.4 item 1: once per second to the unified log).
    private var consumedSinceLog: UInt64 = 0
    private var emptyConsumesSinceLog: UInt64 = 0
    private var lastConsumeLogHostTime: UInt64 = 0

    init(localizedName: String, deviceUUID: UUID, sourceUUID: UUID, sinkUUID: UUID) {
        super.init()

        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceUUID, legacyDeviceID: nil, source: self)

        let dimensions = CMVideoDimensions(width: DaylightFrameWidth, height: DaylightFrameHeight)
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: dimensions.width,
            height: dimensions.height,
            extensions: nil,
            formatDescriptionOut: &videoDescription)

        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: dimensions.width,
            kCVPixelBufferHeightKey: dimensions.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: CFTypeRef](),
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes, &bufferPool)
        bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]

        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: videoDescription,
            maxFrameDuration: CMTime(value: 1, timescale: Int32(DaylightFrameRate)),
            minFrameDuration: CMTime(value: 1, timescale: Int32(DaylightFrameRate)),
            validFrameDurations: nil)

        streamSource = DaylightSourceStream(localizedName: "Daylight Camera Source", streamID: sourceUUID, streamFormat: streamFormat, device: device)
        streamSink = DaylightSinkStream(localizedName: "Daylight Camera Sink", streamID: sinkUUID, streamFormat: streamFormat, device: device)

        do {
            // Order matters: the host assumes streams[0] is the source and streams[1] the sink (OBS, ldenoue).
            try device.addStream(streamSource.stream)
            try device.addStream(streamSink.stream)
        } catch let error {
            fatalError("Daylight camera extension: addStream failed: \(error.localizedDescription)")
        }
        extensionLog.info("device ready: \(localizedName, privacy: .public) consume=\(String(describing: DaylightExtensionRules.consumeStrategy), privacy: .public) hz=\(DaylightExtensionRules.consumeHz)")
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "Daylight Camera"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
    }

    /// The number of viewers streaming the source, published through the custom property (SPEC C3).
    var viewerCount: UInt32 {
        return streamingCounter
    }

    // MARK: Source lifecycle (a viewer such as Zoom started the camera)

    func startStreaming() {
        guard bufferPool != nil else { return }
        streamingCounter += 1
        extensionLog.info("viewer started: streamingCounter=\(self.streamingCounter) sinkStarted=\(self.sinkStarted)")
        streamSource.publishViewerCount(streamingCounter)
        if placeholderTimer != nil {
            return   // one placeholder timer serves every viewer
        }

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(DaylightFrameRate), leeway: .seconds(0))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard DaylightExtensionRules.drawsPlaceholder(sinkStarted: self.sinkStarted, streamingCounter: self.streamingCounter) else {
                return   // the host is feeding real frames, or nobody is watching
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, self.bufferPool, self.bufferAuxAttributes, &pixelBuffer)
            if status == kCVReturnPoolAllocationFailed {
                extensionLog.error("placeholder: no available pixel buffers in the pool")
            }
            guard let pixelBuffer = pixelBuffer else { return }
            Placeholder.shared.fill(pixelBuffer)

            var sampleBuffer: CMSampleBuffer!
            var timingInfo = CMSampleTimingInfo()
            timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
            let err = CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: self.videoDescription,
                sampleTiming: &timingInfo,
                sampleBufferOut: &sampleBuffer)
            if err == noErr {
                self.streamSource.stream.send(
                    sampleBuffer,
                    discontinuity: [],
                    hostTimeInNanoseconds: UInt64(timingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
            }
        }
        timer.setCancelHandler {}
        placeholderTimer = timer
        timer.resume()
    }

    func stopStreaming() {
        if streamingCounter > 1 {
            streamingCounter -= 1
        } else {
            streamingCounter = 0
            if let timer = placeholderTimer {
                timer.cancel()
                placeholderTimer = nil
            }
        }
        extensionLog.info("viewer stopped: streamingCounter=\(self.streamingCounter)")
        streamSource.publishViewerCount(streamingCounter)
    }

    // MARK: Sink lifecycle (Daylight.app opened our sink stream and enqueues frames)

    /// One consume. With `.recursive` the completion re-arms itself; with `.timer90Hz` the timer calls this.
    func consumeBuffer(_ client: CMIOExtensionClient) {
        if !sinkStarted {
            return
        }
        streamSink.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, discontinuity, hasMoreSampleBuffers, error in
            guard let self = self else { return }
            if let sampleBuffer = sampleBuffer {
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                let output = CMIOExtensionScheduledOutput(
                    sequenceNumber: sequenceNumber,
                    hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC)))
                if DaylightExtensionRules.forwardsSinkFrames(streamingCounter: self.streamingCounter) {
                    self.streamSource.stream.send(
                        sampleBuffer,
                        discontinuity: [],
                        hostTimeInNanoseconds: UInt64(sampleBuffer.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
                }
                self.streamSink.stream.notifyScheduledOutputChanged(output)
                self.noteConsumed(empty: false)
            } else {
                self.noteConsumed(empty: true)
                if let error = error {
                    extensionLog.debug("consume returned no buffer: \(error.localizedDescription, privacy: .public)")
                }
            }
            if DaylightExtensionRules.consumeStrategy == .recursive {
                self.consumeBuffer(client)
            }
        }
    }

    func startStreamingSink(client: CMIOExtensionClient) {
        streamingSinkCounter += 1
        sinkStarted = true
        extensionLog.info("sink started: pid=\(client.pid) signingID=\(client.signingID ?? "nil", privacy: .public) strategy=\(String(describing: DaylightExtensionRules.consumeStrategy), privacy: .public)")

        switch DaylightExtensionRules.consumeStrategy {
        case .timer90Hz:
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
            timer.schedule(deadline: .now(), repeating: DaylightExtensionRules.consumeInterval, leeway: .seconds(0))
            timer.setEventHandler { [weak self] in
                self?.consumeBuffer(client)
            }
            timer.setCancelHandler {}
            consumeBufferTimer?.cancel()
            consumeBufferTimer = timer
            timer.resume()
        case .recursive:
            consumeBuffer(client)
        }
    }

    func stopStreamingSink() {
        sinkStarted = false
        if streamingSinkCounter > 1 {
            streamingSinkCounter -= 1
        } else {
            streamingSinkCounter = 0
            if let timer = consumeBufferTimer {
                timer.cancel()
                consumeBufferTimer = nil
            }
        }
        extensionLog.info("sink stopped: streamingSinkCounter=\(self.streamingSinkCounter)")
    }

    /// Once per second in debug builds: consumed buffers and empty consumes (ARCHITECTURE 2.4 item 1).
    private func noteConsumed(empty: Bool) {
        #if DEBUG
        if empty { emptyConsumesSinceLog += 1 } else { consumedSinceLog += 1 }
        let now = UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
        if lastConsumeLogHostTime == 0 {
            lastConsumeLogHostTime = now
            return
        }
        if now - lastConsumeLogHostTime >= NSEC_PER_SEC {
            extensionLog.debug("consume rate: buffers=\(self.consumedSinceLog) empty=\(self.emptyConsumesSinceLog) viewers=\(self.streamingCounter)")
            consumedSinceLog = 0
            emptyConsumesSinceLog = 0
            lastConsumeLogHostTime = now
        }
        #endif
    }
}
