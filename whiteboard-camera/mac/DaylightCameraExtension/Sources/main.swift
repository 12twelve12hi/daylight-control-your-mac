// Daylight Camera extension entry point (shape: OBS camera-extension/main.swift, OffcutsCam Extension/main.swift).
import CoreMediaIO
import Foundation
import os

/// The UUID under `key` in this bundle's Info.plist. A missing or invalid value is a packaging mistake: it is logged as
/// a fault and the built-in value (the same as `project.yml`) is used, because a `fatalError` here would crash the
/// extension again on every launch the system makes.
func resolvedUUID(_ key: String, fallback: UUID) -> UUID {
    let value = Bundle.main.object(forInfoDictionaryKey: key)
    if let uuid = DaylightExtensionRules.uuid(fromPlistValue: value) {
        return uuid
    }
    extensionLog.fault("Info.plist \(key, privacy: .public) is missing or not a UUID (\(String(describing: value), privacy: .public)); using the built-in \(fallback.uuidString, privacy: .public)")
    return fallback
}

let deviceUUID = resolvedUUID("DaylightCameraDeviceUUID", fallback: DaylightExtensionRules.defaultDeviceUUID)
let sourceUUID = resolvedUUID("DaylightCameraSourceUUID", fallback: DaylightExtensionRules.defaultSourceUUID)
let sinkUUID = resolvedUUID("DaylightCameraSinkUUID", fallback: DaylightExtensionRules.defaultSinkUUID)

let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
extensionLog.info("starting build \(bundleVersion, privacy: .public) device=\(deviceUUID.uuidString, privacy: .public)")

let providerSource = DaylightProviderSource(clientQueue: nil, deviceUUID: deviceUUID, sourceUUID: sourceUUID, sinkUUID: sinkUUID)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
