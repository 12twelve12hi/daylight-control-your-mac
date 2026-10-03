import CoreMedia
import CoreMediaIO
import Foundation
import os.log

/// The stream Daylight.app writes into. Shape: OBS OBSCameraStreamSink.swift; queue size 1, one buffer to start.
final class DaylightSinkStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat
    var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .sink, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] {
        return [streamFormat]
    }

    var activeFormatIndex: Int = 0 {
        didSet {
            if activeFormatIndex >= 1 {
                os_log(.error, "Daylight camera extension: invalid sink format index")
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [
            .streamActiveFormatIndex,
            .streamFrameDuration,
            .streamSinkBufferQueueSize,
            .streamSinkBuffersRequiredForStartup,
            .streamSinkBufferUnderrunCount,
            .streamSinkEndOfData,
        ]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: Int32(DaylightFrameRate))
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 1
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        // Later: only the host app may feed the sink (client.signingID == "com.twelve.daylight").
        self.client = client
        return true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? DaylightDeviceSource else {
            fatalError("Daylight camera extension: unexpected device source \(String(describing: device.source))")
        }
        if let client = client {
            deviceSource.startStreamingSink(client: client)
        }
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? DaylightDeviceSource else {
            fatalError("Daylight camera extension: unexpected device source \(String(describing: device.source))")
        }
        deviceSource.stopStreamingSink()
    }
}
