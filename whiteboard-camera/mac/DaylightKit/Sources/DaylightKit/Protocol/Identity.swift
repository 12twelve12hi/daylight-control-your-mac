import Foundation

/// The HANDSHAKE name: "<role>;<clientId>;<label>" (PROTOCOL section 7).
public struct Identity: Equatable {
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
        guard !id.isEmpty, id.utf8.count <= 64 else { return nil }
        self.role = role
        self.clientID = id
        self.label = String(parts[2])
    }

    public var name: String { return "\(role.rawValue);\(clientID);\(label)" }
}
