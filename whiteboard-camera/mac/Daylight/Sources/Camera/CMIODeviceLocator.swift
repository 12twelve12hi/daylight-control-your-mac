import CoreMediaIO
import DaylightKit
import Foundation
import os

/// Finds the Daylight Camera CMIO device by its fixed UUID (OBS plugin-main.mm walk): `kCMIOHardwarePropertyDevices`,
/// `kCMIODevicePropertyDeviceUID == uuidString`, `kCMIODevicePropertyStreams`, `kCMIOStreamPropertyDirection` logged.
/// Which direction value marks the sink is UNVERIFIED (LOOSE_ENDS E2); the stream order the extension adds them in
/// (source first, sink second) is what both shipping hosts rely on, so index 1 is the rule and the directions are logged.
final class CMIODeviceLocator {
    static let log = Logger(subsystem: "com.twelve.daylight", category: "camera")

    let deviceUUID: UUID
    /// The direction value the sink is expected to report (0 = output stream in the SDK header wording; a sink receives
    /// data from the host, which is "output" from the device's point of view). Logged, never load-bearing.
    static let expectedSinkDirection: UInt32 = 0
    static let expectedSourceDirection: UInt32 = 1

    private var loggedDirections = false

    init(deviceUUID: UUID) {
        self.deviceUUID = deviceUUID
    }

    /// The device, its streams in extension order and their `kCMIOStreamPropertyDirection` values (0xFFFFFFFF when
    /// unreadable). nil when no device carries the fixed UUID (row 13).
    func locate() -> (device: CMIODeviceID, streams: [CMIOStreamID], directions: [UInt32])? {
        let wanted = deviceUUID.uuidString.uppercased()
        for device in CMIOProperties.objectIDs(CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices) {
            guard let uid = CMIOProperties.string(device, selector: kCMIODevicePropertyDeviceUID) else { continue }
            if uid.uppercased() != wanted { continue }
            let streams = CMIOProperties.objectIDs(device, selector: kCMIODevicePropertyStreams)
            let directions = streams.map { CMIOProperties.uint32($0, selector: kCMIOStreamPropertyDirection) ?? UInt32.max }
            if !loggedDirections {
                loggedDirections = true
                CMIODeviceLocator.log.info("Daylight Camera device \(device) streams=\(String(describing: streams), privacy: .public) directions=\(String(describing: directions), privacy: .public)")
            }
            return (device, streams, directions)
        }
        return nil
    }

    /// Every CMIO device UID on this Mac, for the row 13 log line.
    func deviceUIDs() -> [String] {
        return CMIOProperties.objectIDs(CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices).compactMap {
            CMIOProperties.string($0, selector: kCMIODevicePropertyDeviceUID)
        }
    }

    /// Index of the sink stream: the second stream, because the extension adds source then sink (OBS, ldenoue).
    /// nil when the device has fewer than two streams (row 14).
    static func sinkStreamIndex(streamCount: Int, directions: [UInt32]) -> Int? {
        guard streamCount >= 2 else { return nil }
        return 1
    }

    /// Index of the source stream (what viewers read, where the viewers property lives): the first stream.
    static func sourceStreamIndex(streamCount: Int) -> Int? {
        guard streamCount >= 1 else { return nil }
        return 0
    }

    /// True when the logged directions contradict the expected [source = 1, sink = 0] pattern, so the first owner run
    /// records which value is which (LOOSE_ENDS E2).
    static func directionsLookUnexpected(_ directions: [UInt32]) -> Bool {
        guard directions.count >= 2 else { return false }
        return !(directions[0] == expectedSourceDirection && directions[1] == expectedSinkDirection)
    }

    /// The row 14 log line text: `streams=[ids] directions=[v0, v1]`.
    static func layoutDescription(streams: [CMIOStreamID], directions: [UInt32]) -> (ids: String, directions: String) {
        let ids = "[" + streams.map { String($0) }.joined(separator: ", ") + "]"
        let dirs = "[" + directions.map { $0 == UInt32.max ? "?" : String($0) }.joined(separator: ", ") + "]"
        return (ids, dirs)
    }
}
