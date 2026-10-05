import AppKit
import DaylightKit
import Foundation

/// D40 "Copy last page": the PNG bytes for the clipboard and the pasteboard write. The pasteboard is a parameter so a
/// test writes to a private `NSPasteboard(name:)`, never the owner's clipboard.
enum LastPage {
    /// The current page rendered from the stroke model when it has ink (1200x1600, PaperBg, like a saved page),
    /// otherwise the bytes of the last saved page PNG, otherwise nil.
    static func pngData(snapshot: StrokeStore?, fallback: URL?) -> Data? {
        if let store = snapshot, store.hasInk, let image = PNGExporter.render(store), let data = try? PNGExporter.pngData(image) {
            return data
        }
        if let url = fallback, let data = try? Data(contentsOf: url) {
            return data
        }
        return nil
    }

    /// Replaces the pasteboard's contents with `data` as PNG; false when the write did not take.
    @discardableResult
    static func put(_ data: Data, on pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: .png)
    }
}
