import CoreMedia
import CoreMediaIO
import Foundation
import os.log

/// The stream viewers (Zoom, Meet, FaceTime) read. Shape: OBS OBSCameraStreamSource.swift.
final class DaylightSourceStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] {
        return [streamFormat]
    }

    var activeFormatIndex: Int = 0 {
        didSet {
            if activeFormatIndex >= 1 {
                os_log(.error, "Daylight camera extension: invalid source format index")
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: Int32(DaylightFrameRate))
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        return true   // any app may view the camera
    }

    func startStream() throws {
        guard let deviceSource = device.source as? DaylightDeviceSource else {
            fatalError("Daylight camera extension: unexpected device source \(String(describing: device.source))")
        }
        deviceSource.startStreaming()
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? DaylightDeviceSource else {
            fatalError("Daylight camera extension: unexpected device source \(String(describing: device.source))")
        }
        deviceSource.stopStreaming()
    }
}
