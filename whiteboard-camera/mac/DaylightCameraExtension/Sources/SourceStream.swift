import CoreMedia
import CoreMediaIO
import Foundation
import os

/// The stream viewers (Zoom, Meet, FaceTime) read. Shape: OBS OBSCameraStreamSource.swift, plus the custom viewers
/// property (`4cc_dlvw_glob_0000`, the ldenoue `4cc_just_glob_0000` pattern) that tells the host how many apps are
/// streaming, so the host can stop the webcam when nobody is in a call (SPEC D32).
final class DaylightSourceStream: NSObject, CMIOExtensionStreamSource {
    static let viewersProperty = CMIOExtensionProperty(rawValue: DaylightExtensionRules.viewersPropertyName)

    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat
    private var lastPublishedViewerCount: UInt32 = 0

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
                extensionLog.error("invalid source format index \(self.activeFormatIndex)")
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.streamActiveFormatIndex, .streamFrameDuration, DaylightSourceStream.viewersProperty]
    }

    private var viewerCount: UInt32 {
        return (device.source as? DaylightDeviceSource)?.viewerCount ?? 0
    }

    private func viewersState(_ count: UInt32) -> CMIOExtensionPropertyState<AnyObject> {
        return CMIOExtensionPropertyState(value: DaylightExtensionRules.viewersPropertyValue(streamingCounter: count) as NSString)
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: Int32(DaylightFrameRate))
        }
        if properties.contains(DaylightSourceStream.viewersProperty) {
            streamProperties.setPropertyState(viewersState(viewerCount), forProperty: DaylightSourceStream.viewersProperty)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
        // The viewers property is read-only; a write is ignored.
    }

    /// Tells listening hosts that the viewer count changed (so `CMIOObjectAddPropertyListenerBlock` has something to
    /// fire on, LOOSE_ENDS E3). The 1 Hz poll on the host is the fallback either way.
    func publishViewerCount(_ count: UInt32) {
        guard count != lastPublishedViewerCount, stream != nil else { return }
        lastPublishedViewerCount = count
        stream.notifyPropertiesChanged([DaylightSourceStream.viewersProperty: viewersState(count)])
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
