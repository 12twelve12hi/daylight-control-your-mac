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
            fatalError("Daylight camera extension: addDevice failed: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
    }

    func disconnect(from client: CMIOExtensionClient) {
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
