import Foundation

/// The HANDSHAKE name: "<role>;<clientId>;<label>" (PROTOCOL section 7).
/// Rules: exactly a known role, a non-empty clientId (at most 64 UTF-8 bytes as an extra limit), and a label of at most
/// 64 UTF-8 bytes. A name without two semicolons is rejected (the server answers ACK status 3).
public struct Identity: Equatable {
    public static let maxClientIDBytes = 64
    public static let maxLabelBytes = 64

    public var role: SolStream.Role
    public var clientID: String
    public var label: String

    public init(role: SolStream.Role, clientID: String, label: String) {
        self.role = role
        self.clientID = clientID
        self.label = label
    }

    public init?(name: String) {
        let parts = name.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let role = SolStream.Role(rawValue: String(parts[0])) else { return nil }
        let id = String(parts[1])
        guard !id.isEmpty, id.utf8.count <= Identity.maxClientIDBytes else { return nil }
        let label = String(parts[2])
        guard label.utf8.count <= Identity.maxLabelBytes else { return nil }
        self.role = role
        self.clientID = id
        self.label = label
    }

    public var name: String { return "\(role.rawValue);\(clientID);\(label)" }

    /// Which messages a role may send in every ink source (PROTOCOL section 8): overlay and test send the three
    /// control messages everywhere; test sends everything; web and ink send ink only while they are the active source.
    public func mayControl(_ opcode: SolStream.Opcode) -> Bool {
        switch role {
        case .test: return true
        case .overlay:
            return opcode == .togglePin || opcode == .clearCanvas || opcode == .autoEngageReturn || opcode == .ping || opcode == .handshake
        case .web, .ink:
            return opcode == .togglePin || opcode == .clearCanvas || opcode == .autoEngageReturn || opcode == .ping || opcode == .handshake
        }
    }
}
