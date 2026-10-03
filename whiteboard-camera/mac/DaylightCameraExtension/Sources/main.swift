// Daylight Camera extension entry point (shape: OBS camera-extension/main.swift, OffcutsCam Extension/main.swift).
import CoreMediaIO
import Foundation
import os

let deviceUUIDString = Bundle.main.object(forInfoDictionaryKey: "DaylightCameraDeviceUUID") as? String
let sourceUUIDString = Bundle.main.object(forInfoDictionaryKey: "DaylightCameraSourceUUID") as? String
let sinkUUIDString = Bundle.main.object(forInfoDictionaryKey: "DaylightCameraSinkUUID") as? String

guard let deviceUUIDString = deviceUUIDString, let sourceUUIDString = sourceUUIDString, let sinkUUIDString = sinkUUIDString else {
    fatalError("Daylight camera extension: UUID keys missing from Info.plist")
}
guard let deviceUUID = UUID(uuidString: deviceUUIDString), let sourceUUID = UUID(uuidString: sourceUUIDString),
    let sinkUUID = UUID(uuidString: sinkUUIDString)
else {
    fatalError("Daylight camera extension: Info.plist UUID values are not UUIDs")
}

let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
Logger(subsystem: "com.twelve.daylight", category: "extension").info("starting build \(bundleVersion, privacy: .public) device=\(deviceUUIDString, privacy: .public)")

let providerSource = DaylightProviderSource(clientQueue: nil, deviceUUID: deviceUUID, sourceUUID: sourceUUID, sinkUUID: sinkUUID)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
