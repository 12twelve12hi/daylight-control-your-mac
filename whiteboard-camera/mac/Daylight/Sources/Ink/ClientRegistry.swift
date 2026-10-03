import DaylightKit
import Foundation

/// The allow-list of tablets (SPEC 9.5, D44): `clients.json` in `~/Library/Application Support/Daylight/`.
/// A loopback (USB, adb reverse) client is recorded as allowed with `seenOverUSB` so the same clientId is trusted
/// later over Wi-Fi. Thread-safe; writes go to `ioQueue`.
final class ClientRegistry {
    struct Record: Codable, Equatable {
        var id: String
        var label: String
        var roles: Set<String>
        var allowed: Bool
        var seenOverUSB: Bool
        var firstSeen: Date
        var lastSeen: Date
        var lastAddress: String
    }

    private struct File: Codable {
        var version: Int
        var clients: [Record]
    }

    let fileURL: URL
    let ioQueue: DispatchQueue
    var trustLoopback: Bool
    var onChange: (([Record]) -> Void)?
    private let lock = NSLock()
    private var records: [String: Record] = [:]
    /// "Not now" is remembered for the running session only: the next connection prompts again.
    private var deniedThisSession: Set<String> = []

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Settings.applicationSupportFolderName, isDirectory: true).appendingPathComponent(Settings.clientsFileName)
    }

    init(fileURL: URL = ClientRegistry.defaultFileURL(), ioQueue: DispatchQueue, trustLoopback: Bool = true) {
        self.fileURL = fileURL
        self.ioQueue = ioQueue
        self.trustLoopback = trustLoopback
        load()
    }

    // MARK: Queries

    func lookup(id: String) -> Record? {
        lock.lock()
        defer { lock.unlock() }
        return records[id]
    }

    func isAllowed(id: String) -> Bool {
        return lookup(id: id)?.allowed == true
    }

    func isDeniedThisSession(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return deniedThisSession.contains(id)
    }

    var all: [Record] {
        lock.lock()
        defer { lock.unlock() }
        return records.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    // MARK: Mutations

    /// A loopback connection: allowed at once, flagged `seenOverUSB`.
    func recordLoopback(id: String, label: String, role: String) {
        mutate(id: id) { record in
            record = ClientRegistry.touch(record, id: id, label: label, role: role, address: "127.0.0.1")
            record?.allowed = true
            record?.seenOverUSB = true
        }
    }

    /// The owner clicked Allow (or a known client reconnected).
    func allow(id: String, label: String, role: String, address: String) {
        mutate(id: id) { record in
            record = ClientRegistry.touch(record, id: id, label: label, role: role, address: address)
            record?.allowed = true
        }
        lock.lock()
        deniedThisSession.remove(id)
        lock.unlock()
    }

    /// Updates the bookkeeping of an already allowed client.
    func noteSeen(id: String, label: String, role: String, address: String) {
        mutate(id: id) { record in
            guard record != nil else { return }
            record = ClientRegistry.touch(record, id: id, label: label, role: role, address: address)
        }
    }

    /// "Not now": the socket is closed; nothing is written (the next connection prompts again).
    func deny(id: String) {
        lock.lock()
        deniedThisSession.insert(id)
        lock.unlock()
    }

    func forget(id: String) {
        mutate(id: id) { record in record = nil }
    }

    /// Whole seconds: `clients.json` is written with ISO 8601 dates (no fractional seconds), so a reloaded record
    /// compares equal to the one in memory.
    static func wholeSecondsNow() -> Date {
        return Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    }

    private static func touch(_ existing: Record?, id: String, label: String, role: String, address: String) -> Record {
        let now = wholeSecondsNow()
        var record = existing ?? Record(id: id, label: label, roles: [], allowed: false, seenOverUSB: false, firstSeen: now, lastSeen: now, lastAddress: address)
        if !label.isEmpty { record.label = label }
        record.roles.insert(role)
        record.lastSeen = now
        record.lastAddress = address
        return record
    }

    private func mutate(id: String, _ body: (inout Record?) -> Void) {
        lock.lock()
        var record = records[id]
        body(&record)
        if let updated = record { records[id] = updated } else { records[id] = nil }
        let snapshot = Array(records.values)
        lock.unlock()
        persist(snapshot)
        onChange?(snapshot.sorted { $0.lastSeen > $1.lastSeen })
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data) else { return }
        lock.lock()
        for record in file.clients { records[record.id] = record }
        lock.unlock()
    }

    private func persist(_ snapshot: [Record]) {
        let url = fileURL
        ioQueue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(File(version: 1, clients: snapshot.sorted { $0.id < $1.id })) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic])
        }
    }

    /// Blocks until queued writes finished (tests).
    func flush() {
        ioQueue.sync {}
    }
}
