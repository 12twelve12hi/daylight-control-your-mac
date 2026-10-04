import XCTest

// Helpers for the DaylightUITests suite (docs/handoff/vp-mac-ui.md, "Design contract"). Every XCUI type is
// @MainActor since the Xcode 16.3 headers (Apple's XCUIAutomation documentation), so everything that touches one is
// @MainActor too; the test methods carry @MainActor as Xcode 16's UI test template does.

/// Where the suite finds the app, the screenshot folder and the docs expectations. The script exports
/// TEST_RUNNER_DAYLIGHT_APP, TEST_RUNNER_DAYLIGHT_SCREENSHOTS and TEST_RUNNER_DAYLIGHT_UI_EXPECTATIONS; xcodebuild
/// forwarding them to the runner without the prefix is UNVERIFIED, so each falls back to the repository root found
/// from this file's own path (<root>/mac/DaylightUITests/UITestSupport.swift, three levels up).
enum UITestEnvironment {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func location(_ variable: String, _ relative: String) -> URL {
        if let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty {
            return URL(fileURLWithPath: value)
        }
        return root.appendingPathComponent(relative)
    }

    static var app: URL { return location("DAYLIGHT_APP", "build/DerivedData/Build/Products/Release/Daylight.app") }
    static var screenshots: URL { return location("DAYLIGHT_SCREENSHOTS", "build/ui-screenshots") }
    static var expectations: URL { return location("DAYLIGHT_UI_EXPECTATIONS", "build/ui-expectations.json") }

    /// Info.plist `DaylightBundlesAdb` of the app under test ("0" when built without the bundled adb).
    static var appBundlesAdb: Bool {
        let value = Bundle(url: app)?.object(forInfoDictionaryKey: "DaylightBundlesAdb")
        if let text = value as? String { return text != "0" }
        if let flag = value as? Bool { return flag }
        return true
    }
}

/// One element of an accessibility snapshot, flattened.
struct UINode {
    let type: XCUIElement.ElementType
    let identifier: String
    let title: String
    let label: String
    let value: String
    let placeholder: String
    let frame: CGRect
    let enabled: Bool
    /// True when an ancestor is a scroll view (its content may lie below or above the window by design).
    let inScroll: Bool

    /// Every non-empty string the element shows (title, label, value, placeholder).
    var texts: [String] {
        return [title, label, value, placeholder].filter { !$0.isEmpty }
    }

    /// The name a menu item or button shows: its title, else its label.
    var name: String {
        return title.isEmpty ? label : title
    }

    func shows(_ text: String) -> Bool {
        return texts.contains(text)
    }
}

/// Flattens the element's accessibility tree with one snapshot (one round trip instead of a query per element).
@MainActor
func flatten(_ element: XCUIElement) -> [UINode] {
    guard let snapshot = try? element.snapshot() else { return [] }
    var nodes: [UINode] = []
    collect(snapshot, inScroll: false, into: &nodes)
    return nodes
}

@MainActor
private func collect(_ snapshot: any XCUIElementSnapshot, inScroll: Bool, into nodes: inout [UINode]) {
    nodes.append(UINode(
        type: snapshot.elementType,
        identifier: snapshot.identifier,
        title: snapshot.title,
        label: snapshot.label,
        value: (snapshot.value as? String) ?? "",
        placeholder: snapshot.placeholderValue ?? "",
        frame: snapshot.frame,
        enabled: snapshot.isEnabled,
        inScroll: inScroll))
    let childrenInScroll = inScroll || snapshot.elementType == .scrollView
    for child in snapshot.children {
        collect(child, inScroll: childrenInScroll, into: &nodes)
    }
}

/// The element types whose frame must lie inside their window (the generic overflow check) and that the AX dump lists.
let boundedTypes: Set<XCUIElement.ElementType> = [
    .staticText, .button, .checkBox, .popUpButton, .slider, .stepper, .textField, .radioButton, .toggle, .switch,
    .segmentedControl, .menuButton, .link,
]

/// Short names for the AX dump; imported NS_ENUM values print no case name.
func typeName(_ type: XCUIElement.ElementType) -> String {
    switch type {
    case .window: return "window"
    case .sheet: return "sheet"
    case .group: return "group"
    case .scrollView: return "scrollView"
    case .tabGroup: return "tabGroup"
    case .staticText: return "text"
    case .textField: return "textField"
    case .textView: return "textView"
    case .button: return "button"
    case .checkBox: return "checkBox"
    case .radioButton: return "radio"
    case .popUpButton: return "popup"
    case .slider: return "slider"
    case .stepper: return "stepper"
    case .toggle: return "toggle"
    case .switch: return "switch"
    case .segmentedControl: return "segmented"
    case .menuButton: return "menuButton"
    case .link: return "link"
    case .image: return "image"
    case .menu: return "menu"
    case .menuItem: return "menuItem"
    case .incrementArrow: return "increment"
    case .decrementArrow: return "decrement"
    case .other: return "other"
    default: return "type\(type.rawValue)"
    }
}

/// "(x, y, w, h)" in whole points.
func rect(_ frame: CGRect) -> String {
    guard !frame.isNull, !frame.isInfinite, frame.minX.isFinite, frame.minY.isFinite else { return "(no frame)" }
    return "(\(Int(frame.minX.rounded())), \(Int(frame.minY.rounded())), \(Int(frame.width.rounded())), \(Int(frame.height.rounded())))"
}

/// The first `limit` characters of a text, on one line.
func clip(_ text: String, _ limit: Int = 60) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    return flat.count <= limit ? flat : String(flat.prefix(limit)) + "..."
}

/// "General" -> "general", "Ink source" -> "ink-source": file name parts.
func slug(_ text: String) -> String {
    let lowered = text.lowercased()
    let mapped = lowered.map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
    return String(mapped).split(separator: "-").joined(separator: "-")
}

/// A screenshot at every step: attached to the result (kept always) as "<appearance>-NN-<step>" and written as
/// <screenshots>/<appearance>/NN-<step>.png. With `window`, the window alone is saved too as NN-<step>-window.png.
@MainActor
final class Shots {
    private let testCase: XCTestCase
    let appearance: String
    let directory: URL
    private var index = 0
    private var writeFailureReported = false

    init(testCase: XCTestCase, appearance: String) {
        self.testCase = testCase
        self.appearance = appearance
        directory = UITestEnvironment.screenshots.appendingPathComponent(appearance, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func take(_ step: String, window: XCUIElement? = nil) {
        index += 1
        let file = String(format: "%02d", index) + "-" + step
        store(XCUIScreen.main.screenshot(), file: file)
        if let window = window, window.exists {
            store(window.screenshot(), file: file + "-window")
        }
    }

    private func store(_ shot: XCUIScreenshot, file: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = appearance + "-" + file
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
        do {
            try shot.pngRepresentation.write(to: directory.appendingPathComponent(file + ".png"))
        } catch {
            // The runner may be sandboxed (UNVERIFIED either way); the attachments in the xcresult still hold every
            // screenshot and scripts/mac-ui-test.sh exports them when this folder stays empty.
            if !writeFailureReported {
                writeFailureReported = true
                print("DaylightUITests: cannot write screenshots to \(directory.path): \(error)")
            }
        }
    }
}

/// One entry of build/ui-expectations.json (scripts/ui_expectations.py).
struct DocExpectation: Decodable {
    let text: String
    let kind: String
    let tab: String?
    let parent: String?
    let source: String
}

/// A popup button of a Settings tab with the options its menu offered.
struct PopupInfo {
    let label: String
    let value: String
    let options: [String]
}
