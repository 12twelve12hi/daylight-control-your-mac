import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import os.log

let DaylightFrameRate: Int = 30
let DaylightFrameWidth: Int32 = 1920
let DaylightFrameHeight: Int32 = 1080

/// One device "Daylight Camera" with a source stream (what Zoom reads) and a sink stream (what Daylight.app feeds).
/// Shape: OBS OBSCameraDeviceSource.swift (timer-driven consume at 3x the frame rate) with Daylight names.
final class DaylightDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!

    private var streamSource: DaylightSourceStream!
    private var streamSink: DaylightSinkStream!

    private var streamingCounter: UInt32 = 0
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
            // Order matters: the host assumes streams[0] is the source and streams[1] the sink.
            try device.addStream(streamSource.stream)
            try device.addStream(streamSink.stream)
        } catch let error {
            fatalError("Daylight camera extension: addStream failed: \(error.localizedDescription)")
        }
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

    // MARK: Source lifecycle (a viewer such as Zoom started the camera)

    func startStreaming() {
        guard bufferPool != nil else { return }
        streamingCounter += 1

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(DaylightFrameRate), leeway: .seconds(0))
        timer.setEventHandler {
            if self.sinkStarted {
                return   // the host is feeding real frames
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, self.bufferPool, self.bufferAuxAttributes, &pixelBuffer)
            if status == kCVReturnPoolAllocationFailed {
                os_log(.error, "Daylight camera extension: no available pixel buffers in the pool")
            }
            guard let pixelBuffer = pixelBuffer else { return }
            Placeholder.fill(pixelBuffer)

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
    }

    // MARK: Sink lifecycle (Daylight.app opened our sink stream and enqueues frames)

    func consumeBuffer(_ client: CMIOExtensionClient) {
        if !sinkStarted {
            return
        }
        streamSink.stream.consumeSampleBuffer(from: client) { sampleBuffer, sequenceNumber, discontinuity, hasMoreSampleBuffers, error in
            if let sampleBuffer = sampleBuffer {
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                let output = CMIOExtensionScheduledOutput(
                    sequenceNumber: sequenceNumber,
                    hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC)))
                if self.streamingCounter > 0 {
                    self.streamSource.stream.send(
                        sampleBuffer,
                        discontinuity: [],
                        hostTimeInNanoseconds: UInt64(sampleBuffer.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
                }
                self.streamSink.stream.notifyScheduledOutputChanged(output)
            }
        }
    }

    func startStreamingSink(client: CMIOExtensionClient) {
        streamingSinkCounter += 1
        sinkStarted = true

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / (Double(DaylightFrameRate) * 3.0), leeway: .seconds(0))
        timer.setEventHandler {
            self.consumeBuffer(client)
        }
        timer.setCancelHandler {}
        consumeBufferTimer = timer
        timer.resume()
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
    }
}
