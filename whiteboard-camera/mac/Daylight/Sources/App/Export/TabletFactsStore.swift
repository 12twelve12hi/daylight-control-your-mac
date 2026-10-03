import Foundation

/// One `facts` value of PROTOCOL 15.1: flat, so a string, a number, a boolean or null.
enum FactValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    /// The value for `JSONSerialization` (whole numbers stay integers on disk).
    var jsonObject: Any {
        switch self {
        case let .string(s): return s
        case let .number(n):
            if n == n.rounded(), abs(n) < 9_007_199_254_740_992 { return NSNumber(value: Int64(n)) }
            return NSNumber(value: n)
        case let .bool(b): return NSNumber(value: b)
        case .null: return NSNull()
        }
    }
}

/// The tablet facts the Mac holds in memory (PROTOCOL 15.3, never on disk): the latest POST per key
/// `<source>:<clientId or remote address>`, at most 16 keys, the oldest by receive time evicted.
///
/// Thread-safe through its own serial queue `com.twelve.daylight.facts`: the listener writes on net.queue, the export
/// queue and the main thread (Diagnostics) read. The queue never calls out, so a `sync` from any of them cannot
/// deadlock.
final class TabletFactsStore {
    struct Entry: Equatable {
        let key: String
        let source: String
        let clientId: String?
        let sentAt: String
        let facts: [String: FactValue]
        let receivedAt: Date
        /// As the TCP peer reported it; the export redacts it to the last octet.
        let remoteAddress: String
        /// `clientId` is an allowed tablet in `clients.json`.
        let allowed: Bool
    }

    static let maxEntries = 16
    /// The app's store (AppDelegate hands it to the listener; Diagnostics and the export read it).
    static let shared = TabletFactsStore()

    private let queue = DispatchQueue(label: "com.twelve.daylight.facts")
    private var entries: [String: Entry] = [:]

    /// `<source>:<clientId>` when the sender gave one, else `<source>:<remote address>`.
    static func key(source: String, clientId: String?, remoteAddress: String) -> String {
        if let id = clientId, !id.isEmpty { return "\(source):\(id)" }
        return "\(source):\(remoteAddress)"
    }

    /// Stores `entry` (replacing the same key) and returns how many senders are held now.
    @discardableResult
    func put(_ entry: Entry) -> Int {
        return queue.sync {
            entries[entry.key] = entry
            while entries.count > TabletFactsStore.maxEntries {
                guard let oldest = entries.values.min(by: { $0.receivedAt < $1.receivedAt }) else { break }
                entries[oldest.key] = nil
            }
            return entries.count
        }
    }

    /// Every entry, oldest first.
    var all: [Entry] {
        return queue.sync { entries.values.sorted { ($0.receivedAt, $0.key) < ($1.receivedAt, $1.key) } }
    }

    var count: Int {
        return queue.sync { entries.count }
    }

    func removeAll() {
        queue.sync { entries.removeAll() }
    }

    /// `tablet facts: <key> received <receivedAt> (<n> facts)`, one per key (PROTOCOL 15.3, SPEC 13.2).
    func diagnosticsLines() -> [String] {
        return all.map(TabletFactsStore.diagnosticsLine)
    }

    static func diagnosticsLine(_ e: Entry) -> String {
        return "tablet facts: \(e.key) received \(iso8601(e.receivedAt)) (\(e.facts.count) facts)"
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// The export's `tablet-facts.json` object for one entry; `remoteAddress` already redacted to the last octet.
    static func exportObject(_ e: Entry) -> [String: Any] {
        var facts: [String: Any] = [:]
        for (key, value) in e.facts { facts[key] = value.jsonObject }
        return [
            "key": e.key,
            "source": e.source,
            "clientId": e.clientId.map { $0 as Any } ?? NSNull(),
            "sentAt": e.sentAt,
            "receivedAt": iso8601(e.receivedAt),
            "remoteAddress": Redactor.redactAddress(e.remoteAddress),
            "allowed": e.allowed,
            "facts": facts,
        ]
    }
}
