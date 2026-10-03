import CoreMediaIO
import Foundation

final class DaylightProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DaylightDeviceSource!

    init(clientQueue: DispatchQueue?, deviceUUID: UUID, sourceUUID: UUID, sinkUUID: UUID) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DaylightDeviceSource(
            localizedName: "Daylight Camera",
            deviceUUID: deviceUUID,
            sourceUUID: sourceUUID,
            sinkUUID: sinkUUID)
        do {
            try provider.addDevice(deviceSource.device)
        } catch let error {
            // No crash loop: the provider service still starts, without a Daylight Camera to show (so no card either).
            // The host keeps reporting row 13 and the fault names the cause.
            extensionLog.fault("addDevice failed: \(error.localizedDescription, privacy: .public); the provider runs without a device")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
    }

    /// A client process went away (quit, crash, force quit). When it was the host feeding the sink, the sink is stopped
    /// here too, so the card does not depend on CMIO also calling the sink's `stopStream` (camera review CAMA-03).
    func disconnect(from client: CMIOExtensionClient) {
        deviceSource.clientDisconnected(client)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.providerName, .providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerName) {
            providerProperties.name = "Daylight Camera Provider"
        }
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "Twelve"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
    }
}
