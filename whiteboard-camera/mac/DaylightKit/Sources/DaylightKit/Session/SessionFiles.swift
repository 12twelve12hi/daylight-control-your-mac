import Foundation

/// Where saved pages go: ~/Documents/Daylight Camera/<yyyy-mm-dd>/page-01.png and .json.
public enum SessionFiles {
    public static func sessionDirectory(root: URL, sessionStart: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> URL {
        let c = calendar.dateComponents([.year, .month, .day], from: sessionStart)
        let name = String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        return root.appendingPathComponent("Daylight Camera", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    public static func pageBaseName(index: Int) -> String {
        return String(format: "page-%02d", index + 1)
    }

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
            let candidate = URL(fileURLWithPath: base.path + "-\(n)").appendingPathExtension(ext)
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
}
