import Foundation

/// The adb server's smart-socket framing (research-scrcpy-adb section 3.1, AOSP `OVERVIEW.TXT`): every request is a
/// 4-hex-digit length followed by the payload (`000Chost:version`); the reply is `OKAY` or `FAIL`, and a payload, when
/// one follows, is again `hex4 + bytes`. `host:track-devices` keeps the connection open and repeats the framed list.
public enum AdbHostProtocol {
    public static let defaultPort: UInt16 = 5037
    public static let hostVersion = "host:version"
    public static let hostTrackDevices = "host:track-devices"
    public static let hostDevicesLong = "host:devices-l"

    /// `host:version` -> `000chost:version` (adb accepts either case; lower-case matches `OVERVIEW.TXT`'s own examples).
    public static func encodeRequest(_ payload: String) -> [UInt8] {
        let bytes = Array(payload.utf8)
        var length = String(bytes.count, radix: 16)
        while length.count < 4 { length = "0" + length }
        return Array(length.utf8) + bytes
    }

    public enum Reply: Equatable {
        case okay
        case fail(reason: String)
        case payload(String)
    }

    /// Incremental reply parser: `OKAY`, `FAIL` + framed reason, then framed payloads for as long as the socket lives.
    public struct ReplyParser {
        private var buffer: [UInt8] = []
        private var sawStatus = false

        public init() {}

        public mutating func feed(_ bytes: [UInt8], emit: (Reply) -> Void) {
            buffer.append(contentsOf: bytes)
            while true {
                if !sawStatus {
                    guard buffer.count >= 4 else { return }
                    let status = String(decoding: buffer[0..<4], as: UTF8.self)
                    buffer.removeFirst(4)
                    sawStatus = true
                    if status == "OKAY" {
                        emit(.okay)
                        continue
                    }
                    // FAIL: the reason is one framed payload, then the connection closes.
                    guard let reason = takeFrame() else {
                        buffer.insert(contentsOf: Array("FAIL".utf8), at: 0)
                        sawStatus = false
                        return
                    }
                    emit(.fail(reason: reason))
                    continue
                }
                guard let payload = takeFrame() else { return }
                emit(.payload(payload))
            }
        }

        private mutating func takeFrame() -> String? {
            guard buffer.count >= 4, let length = Int(String(decoding: buffer[0..<4], as: UTF8.self), radix: 16) else { return nil }
            guard buffer.count >= 4 + length else { return nil }
            let payload = String(decoding: buffer[4..<(4 + length)], as: UTF8.self)
            buffer.removeFirst(4 + length)
            return payload
        }
    }
}
