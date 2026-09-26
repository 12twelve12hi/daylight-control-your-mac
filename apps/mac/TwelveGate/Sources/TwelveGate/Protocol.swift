import Foundation

// Swift mirror of the subset of packages/protocol/src/index.ts the Mac needs.
// Field names match the JSON exactly. Timestamps are Unix milliseconds.

// MARK: - Server → client: state

/// `state.shield`: what the full-screen shield says.
struct ShieldInfo: Decodable {
    let title: String
    let body: String
}

/// `state.banner`: the check-in warning. `endsAt` is Unix milliseconds.
struct BannerInfo: Decodable {
    let text: String
    let endsAt: Double
    let canSnooze: Bool
}

/// `state.meeting`: the meeting that put the Mac into allowlist mode.
struct MeetingInfo: Decodable {
    let title: String
    let start: String
    let end: String
    let source: String
}

/// `state.clients`
struct ClientsInfo: Decodable {
    let mac: Bool
    let daylight: Bool
}

/// The subset of the server's `StateSnapshot` the Mac needs. Unknown keys are
/// ignored. Only `lockMode` is required; everything else has a safe default so
/// a slightly different server build cannot leave the Mac in a bad state.
struct StateSnapshot: Decodable {
    let now: Double
    let phase: String
    let lockMode: String
    let shield: ShieldInfo?
    let banner: BannerInfo?
    let allowlist: [String]
    let meeting: MeetingInfo?
    let emergencyUntil: Double?
    let nextCheckinAt: Double?
    let checkinLocksAt: Double?
    let clients: ClientsInfo
    let aiBusy: Bool

    private enum CodingKeys: String, CodingKey {
        case now, phase, lockMode, shield, banner, allowlist, meeting
        case emergencyUntil, nextCheckinAt, checkinLocksAt, clients, aiBusy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lockMode = try container.decode(String.self, forKey: .lockMode)
        now = try container.decodeIfPresent(Double.self, forKey: .now)
            ?? Date().timeIntervalSince1970 * 1000
        phase = try container.decodeIfPresent(String.self, forKey: .phase) ?? "idle"
        shield = try container.decodeIfPresent(ShieldInfo.self, forKey: .shield)
        banner = try container.decodeIfPresent(BannerInfo.self, forKey: .banner)
        allowlist = try container.decodeIfPresent([String].self, forKey: .allowlist) ?? []
        meeting = try container.decodeIfPresent(MeetingInfo.self, forKey: .meeting)
        emergencyUntil = try container.decodeIfPresent(Double.self, forKey: .emergencyUntil)
        nextCheckinAt = try container.decodeIfPresent(Double.self, forKey: .nextCheckinAt)
        checkinLocksAt = try container.decodeIfPresent(Double.self, forKey: .checkinLocksAt)
        clients = try container.decodeIfPresent(ClientsInfo.self, forKey: .clients)
            ?? ClientsInfo(mac: true, daylight: false)
        aiBusy = try container.decodeIfPresent(Bool.self, forKey: .aiBusy) ?? false
    }
}

extension StateSnapshot {
    /// True while a server-granted emergency unlock window is still open.
    var isEmergencyActive: Bool {
        guard let until = emergencyUntil else { return false }
        return until > Date().timeIntervalSince1970 * 1000
    }

    /// True while quitting the app must be refused (shield or allowlist mode,
    /// and no emergency unlock in progress).
    var isLocked: Bool {
        return (lockMode == "shield" || lockMode == "allowlist") && !isEmergencyActive
    }
}

// MARK: - Server → client: envelopes

/// Just the discriminator, decoded first to pick the concrete message.
struct ServerEnvelope: Decodable {
    let type: String
}

/// `{ "type": "state", "state": { ... } }`
struct StateMessage: Decodable {
    let type: String
    let state: StateSnapshot
}

/// `{ "type": "pong", "now": Double }`
struct PongMessage: Decodable {
    let type: String
    let now: Double
}

/// `{ "type": "error", "code": String, "message": String }`
struct ErrorMessage: Decodable {
    let type: String
    let code: String
    let message: String
}

// MARK: - Client → server

struct HelloMessage: Encodable {
    let type = "hello"
    let role = "mac"
    let deviceId: String
    let version: String
}

struct EmergencyUnlockMessage: Encodable {
    let type = "emergency.unlock"
    let reason: String
}

struct CheckinSnoozeMessage: Encodable {
    let type = "checkin.snooze"
}

struct MacForegroundMessage: Encodable {
    let type = "mac.foreground"
    let bundleId: String
    let name: String
}

struct PingMessage: Encodable {
    let type = "ping"
}

/// Everything the Mac ever sends, as one enum so callers never deal with
/// `Encodable` existentials.
enum ClientMessage {
    case hello(deviceId: String, version: String)
    case emergencyUnlock(reason: String)
    case checkinSnooze
    case macForeground(bundleId: String, name: String)
    case ping

    /// JSON bytes for the wire.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        switch self {
        case .hello(let deviceId, let version):
            return try encoder.encode(HelloMessage(deviceId: deviceId, version: version))
        case .emergencyUnlock(let reason):
            return try encoder.encode(EmergencyUnlockMessage(reason: reason))
        case .checkinSnooze:
            return try encoder.encode(CheckinSnoozeMessage())
        case .macForeground(let bundleId, let name):
            return try encoder.encode(MacForegroundMessage(bundleId: bundleId, name: name))
        case .ping:
            return try encoder.encode(PingMessage())
        }
    }
}
