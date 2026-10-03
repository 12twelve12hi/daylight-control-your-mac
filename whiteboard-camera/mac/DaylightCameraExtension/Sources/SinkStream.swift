import CoreMedia
import CoreMediaIO
import Foundation
import os

/// The stream Daylight.app writes into. Shape: OBS OBSCameraStreamSink.swift; queue size 1, one buffer to start.
/// Daylight addition (SPEC C3): only a client signed as `com.twelve.daylight` may start the sink.
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
                extensionLog.error("invalid sink format index \(self.activeFormatIndex)")
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
        let signingID = client.signingID
        guard DaylightExtensionRules.authorizesSink(signingID: signingID) else {
            extensionLog.error("sink refused: pid=\(client.pid) signingID=\(signingID ?? "nil", privacy: .public)")
            return false
        }
        self.client = client
        return true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? DaylightDeviceSource else {
            throw DaylightDeviceSource.unexpectedSourceError(device, in: "sink startStream")
        }
        if let client = client {
            deviceSource.startStreamingSink(client: client)
        } else {
            extensionLog.error("sink startStream without an authorized client")
        }
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? DaylightDeviceSource else {
            throw DaylightDeviceSource.unexpectedSourceError(device, in: "sink stopStream")
        }
        guard client != nil else {
            // `disconnect(from:)` already stopped the sink for this client (it clears `client`): not a second stop.
            extensionLog.info("sink stopStream after the client disconnected; already stopped")
            return
        }
        deviceSource.stopStreamingSink()
    }
}
