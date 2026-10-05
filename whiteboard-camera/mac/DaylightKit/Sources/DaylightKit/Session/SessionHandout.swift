import Foundation

/// The board as the follow-up (DRAWING-DEEP-DIVE D39 and D41): the pure decisions behind `session.pdf` and
/// "Send today's board...". Which page images go into the PDF and in what order, what the PDF is called, when a
/// session is over, and which saved PDF to send. Foundation only; the app does the CoreGraphics and AppKit work.
public enum SessionHandout {
    public static let pdfBaseName = "session"
    public static let pdfExtension = "pdf"
    /// The owner-facing line when "Send today's board..." finds nothing to send.
    public static let nothingToSend = "No saved board to send yet."
    /// The owner-facing line when the current session's page save or PDF write failed and there is nothing older.
    public static let couldNotWrite = "Could not write today's board."
    /// The owner-facing line when the current session's page save or PDF write failed and an older PDF is sent.
    public static let couldNotWriteSendingLast = "Could not write today's board; sending the last saved one."

    // MARK: Page order

    /// The sort key of a page image in a session folder, nil for any other file. `page-NN.png` and `page-NN-K.png`
    /// come first, by page number then collision suffix (no suffix is 1); `mirror-HH-mm-ss.png` and
    /// `mirror-HH-mm-ss-K.png` (SPEC 12 mirror mode) follow, by time then suffix. Everything else is ignored.
    public static func pageSortKey(_ name: String) -> (group: Int, number: Int, suffix: Int)? {
        let ext = ".png"
        guard name.hasSuffix(ext) else { return nil }
        let stem = String(name.dropLast(ext.count))
        if stem.hasPrefix("page-") {
            let parts = stem.dropFirst("page-".count).split(separator: Character("-"), omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 1 || parts.count == 2, let number = digits(parts[0]) else { return nil }
            var suffix = 1
            if parts.count == 2 {
                guard let s = digits(parts[1]), s >= 2 else { return nil }
                suffix = s
            }
            return (group: 0, number: number, suffix: suffix)
        }
        if stem.hasPrefix("mirror-") {
            let parts = stem.dropFirst("mirror-".count).split(separator: Character("-"), omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 || parts.count == 4 else { return nil }
            guard parts[0].count == 2, parts[1].count == 2, parts[2].count == 2,
                  let h = digits(parts[0]), let m = digits(parts[1]), let s = digits(parts[2]) else { return nil }
            var suffix = 1
            if parts.count == 4 {
                guard let k = digits(parts[3]), k >= 2 else { return nil }
                suffix = k
            }
            return (group: 1, number: h * 3600 + m * 60 + s, suffix: suffix)
        }
        return nil
    }

    /// The page images of a session folder listing in PDF order (see `pageSortKey`).
    public static func pageFiles(_ names: [String]) -> [String] {
        var keyed: [(name: String, group: Int, number: Int, suffix: Int)] = []
        for name in names {
            if let key = pageSortKey(name) {
                keyed.append((name: name, group: key.group, number: key.number, suffix: key.suffix))
            }
        }
        keyed.sort { a, b in
            if a.group != b.group { return a.group < b.group }
            if a.number != b.number { return a.number < b.number }
            if a.suffix != b.suffix { return a.suffix < b.suffix }
            return a.name < b.name
        }
        return keyed.map { $0.name }
    }

    // MARK: PDF name

    /// The collision suffix of a session PDF name (`session.pdf` is 1, `session-3.pdf` is 3), nil for other files.
    public static func pdfSuffix(_ name: String) -> Int? {
        let plain = pdfBaseName + "." + pdfExtension
        if name == plain { return 1 }
        let prefix = pdfBaseName + "-"
        let ext = "." + pdfExtension
        guard name.hasPrefix(prefix), name.hasSuffix(ext), name.count > prefix.count + ext.count else { return nil }
        let middle = String(name.dropFirst(prefix.count).dropLast(ext.count))
        guard let n = digits(middle), n >= 2 else { return nil }
        return n
    }

    /// Where this app writes a session's PDF. `bound` is the PDF it already wrote for this folder (rewriting the same
    /// session's own PDF is fine); otherwise `session.pdf`, or `session-2.pdf` and so on when a PDF this app did not
    /// write for this session is already there (a folder collision).
    public static func pdfURL(directory: URL, bound: URL?, exists: (URL) -> Bool) -> URL {
        if let bound = bound { return bound }
        let plain = directory.appendingPathComponent(pdfBaseName).appendingPathExtension(pdfExtension)
        return SessionFiles.uniqueURL(plain, exists: exists)
    }

    // MARK: Session over

    /// SPEC 12's 10-minute gap: the session is over when the last ink is older than `SessionFiles.sessionGapSeconds`
    /// by either clock. The wall clock keeps running while the Mac sleeps (the monotonic clock stops); the monotonic
    /// clock ignores a wall-clock change. Either one saying "over" is enough: writing a PDF early is harmless, a later
    /// save of the same session marks it pending again and the PDF is rewritten.
    public static func sessionIsOver(lastInkWall: Date?, lastInkMonotonic: Double?, nowWall: Date, nowMonotonic: Double) -> Bool {
        if lastInkWall == nil && lastInkMonotonic == nil { return true }
        if let wall = lastInkWall, nowWall.timeIntervalSince(wall) > SessionFiles.sessionGapSeconds { return true }
        if let mono = lastInkMonotonic, nowMonotonic - mono > SessionFiles.sessionGapSeconds { return true }
        return false
    }

    // MARK: Send today's board

    public enum SendChoice: Equatable {
        /// Open the share sheet with this PDF.
        case send(URL)
        /// Nothing to send: show this sentence.
        case nothing(String)
        /// The current session could not be written (review F8): show this sentence, then share this older PDF.
        case sendAfterNotice(URL, String)
    }

    /// The choice after the current session's save or PDF write failed: the owner is told, never silently handed the
    /// previous session's PDF.
    public static func afterWriteFailure(_ choice: SendChoice) -> SendChoice {
        switch choice {
        case let .send(url):
            return .sendAfterNotice(url, couldNotWriteSendingLast)
        case .nothing:
            return .nothing(couldNotWrite)
        case .sendAfterNotice:
            return choice
        }
    }

    /// The PDF "Send today's board..." offers: today's newest session folder that holds a session PDF (its highest
    /// suffix), else the newest such folder of an earlier day (the last session's PDF), else `.nothing`. `list` returns
    /// the names in a directory, nil when it does not exist.
    public static func boardToSend(root: URL, today: Date, calendar: Calendar = Calendar(identifier: .gregorian), list: (URL) -> [String]?) -> SendChoice {
        let top = root.appendingPathComponent(SessionFiles.folderName, isDirectory: true)
        let todayName = SessionFiles.sessionDirectory(root: root, sessionStart: today, calendar: calendar).deletingLastPathComponent().lastPathComponent
        var days = (list(top) ?? []).filter { isDayName($0) && $0 != todayName }.sorted(by: >)
        days.insert(todayName, at: 0)
        for day in days {
            let dayURL = top.appendingPathComponent(day, isDirectory: true)
            let sessions = (list(dayURL) ?? []).filter { isTimeName($0) }.sorted(by: >)
            for session in sessions {
                let sessionURL = dayURL.appendingPathComponent(session, isDirectory: true)
                var best: (name: String, suffix: Int)?
                for name in list(sessionURL) ?? [] {
                    guard let suffix = pdfSuffix(name) else { continue }
                    if best == nil || suffix > best!.suffix { best = (name: name, suffix: suffix) }
                }
                if let best = best { return .send(sessionURL.appendingPathComponent(best.name)) }
            }
        }
        return .nothing(nothingToSend)
    }

    /// `yyyy-MM-dd`.
    public static func isDayName(_ name: String) -> Bool {
        return matches(name, dashes: [4, 7], length: 10)
    }

    /// `HH-mm-ss`.
    public static func isTimeName(_ name: String) -> Bool {
        return matches(name, dashes: [2, 5], length: 8)
    }

    private static func matches(_ name: String, dashes: [Int], length: Int) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count == length else { return false }
        for (i, b) in bytes.enumerated() {
            if dashes.contains(i) {
                if b != 0x2D { return false }
            } else if b < 0x30 || b > 0x39 {
                return false
            }
        }
        return true
    }

    private static func digits(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.count <= 9, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(text)
    }
}

/// When a session's PDF is due (ink.queue state of the router). A page save marks its session pending; the PDF is
/// written when the session is idle past the gap, when a later session saves, when a new session starts, on quit, or
/// on "Send today's board...", and each write takes the pending mark so an idle board is written once.
public struct HandoutTracker: Equatable {
    /// The session with a page saved after its last PDF write.
    public private(set) var pendingStart: Date?
    /// The session of the most recent page save.
    public private(set) var lastSavedStart: Date?
    public private(set) var lastInkWall: Date?
    public private(set) var lastInkMonotonic: Double?

    public init() {}

    public mutating func noteInk(wall: Date, monotonic: Double) {
        lastInkWall = wall
        lastInkMonotonic = monotonic
    }

    /// A page save of `sessionStart` was queued. Returns the previous session when it still waits for its PDF (a new
    /// session saved before the old one was written); the caller writes that one now.
    public mutating func noteSaveQueued(sessionStart: Date) -> Date? {
        var finished: Date?
        if let pending = pendingStart, pending != sessionStart { finished = pending }
        pendingStart = sessionStart
        lastSavedStart = sessionStart
        return finished
    }

    /// The pending session, if any, and clears the mark.
    public mutating func takePending() -> Date? {
        let start = pendingStart
        pendingStart = nil
        return start
    }

    /// The pending session when it is over by `SessionHandout.sessionIsOver`, and clears the mark; nil otherwise.
    public mutating func takeIfIdle(nowWall: Date, nowMonotonic: Double) -> Date? {
        guard pendingStart != nil else { return nil }
        guard SessionHandout.sessionIsOver(lastInkWall: lastInkWall, lastInkMonotonic: lastInkMonotonic, nowWall: nowWall, nowMonotonic: nowMonotonic) else { return nil }
        return takePending()
    }
}
