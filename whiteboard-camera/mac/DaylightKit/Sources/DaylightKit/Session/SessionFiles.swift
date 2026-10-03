import Foundation

/// Where saved pages go (SPEC section 12): `<root>/Daylight Camera/<yyyy-MM-dd>/<HH-mm-ss>/page-01.png` and `.json`,
/// where `HH-mm-ss` is the session start (the first stroke after launch or after a 10-minute gap since the last ink).
public enum SessionFiles {
    public static let folderName = "Daylight Camera"
    /// A new session starts when the last ink is older than this.
    public static let sessionGapSeconds: Double = 600

    /// `<root>/Daylight Camera/<yyyy-MM-dd>/<HH-mm-ss>/`. Pass a calendar with the time zone the folder names should use.
    public static func sessionDirectory(root: URL, sessionStart: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> URL {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: sessionStart)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        let time = String(format: "%02d-%02d-%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return root
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent(time, isDirectory: true)
    }

    /// "page-01" for index 0 (the name is 1-based, the index is the 0-based page index of PROTOCOL 6.11).
    public static func pageBaseName(index: Int) -> String {
        return String(format: "page-%02d", max(index, 0) + 1)
    }

    /// "mirror-HH-mm-ss" for a mirror-mode capture.
    public static func mirrorName(sessionStart: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let c = calendar.dateComponents([.hour, .minute, .second], from: sessionStart)
        return String(format: "mirror-%02d-%02d-%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Appends -2, -3, ... before the extension until `exists` says no.
    public static func uniqueURL(_ url: URL, exists: (URL) -> Bool) -> URL {
        if !exists(url) { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension()
        var n = 2
        while true {
            var candidate = URL(fileURLWithPath: base.path + "-\(n)")
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// True when a stroke at `now` starts a new session (no ink yet, or the last ink is older than the 10-minute gap).
    public static func startsNewSession(lastInkAt: Double?, now: Double) -> Bool {
        guard let last = lastInkAt else { return true }
        return now - last > sessionGapSeconds
    }
}
