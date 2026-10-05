import AppKit
import XCTest

/// The Mac UI suite of docs/handoff/vp-mac-ui.md ("What the suite proves" 1 to 6), once in light and once in dark
/// appearance. It drives the prebuilt unsigned Release app by URL (no target dependency, see mac/project.yml) and
/// launches as few times as it can: the first launch shows Welcome and the status item menu, then one launch each for
/// Settings (all nine tabs, overlay enabled), the preview, Diagnostics and the Allow panel; `--ui-test-open menu` and
/// `--ui-test-settings-tab` relaunches happen only as fallbacks. Failures never stop the run (continueAfterFailure).
final class DaylightUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    @MainActor
    func testLightAppearance() throws {
        run("light")
    }

    @MainActor
    func testDarkAppearance() throws {
        run("dark")
    }

    @MainActor
    private func run(_ appearance: String) {
        let session = DaylightUISession(testCase: self, appearance: appearance)
        // The app is terminated here rather than in tearDown, which is not main-actor isolated in the XCTest headers.
        defer { session.terminate() }
        session.runAll()
    }
}

/// One appearance's pass over every surface, plus the inventory of strings the Docs to UI check reads.
@MainActor
final class DaylightUISession {
    static let tabs = ["General", "Hotkeys", "Network", "Mirror", "Overlay", "Share", "Saving", "Advanced", "Diagnostics"]
    /// FailureText row 2 (`unsignedBuild`), as docs/OWNER-NEXT-STEPS.md quotes it.
    static let unsignedSentence = "This is an unsigned test build. The virtual camera cannot be installed on this Mac. Use Daylight > Preview window to see the output."
    static let welcomeTexts = [
        "Welcome to Daylight",
        "Set up once; after this Daylight Camera is just there.",
        "0. Location",
        "1. Camera",
        "2. Install Daylight Camera",
        "3. Your Daylight",
        "4. Allow this Daylight?",
        "5. Finish",
        unsignedSentence,
        "Not available on an unsigned test build. The preview window shows the output.",
    ]
    /// MenuBar.menuNeedsUpdate, in order, with overlay enabled. Items with a hotkey carry "  (<chord>)" after the title.
    static let menuOrder = [
        "Ink source", "Hold", "Keep whiteboard", "Clear", "Camera",
        "Whiteboard now (Studio Split)", "Whiteboard now (Whiteboard Only)", "Whiteboard now (Overlay)",
        "Copy last page", "Send today's board...",
        "Preview window", "Share the whiteboard", "Settings...", "Diagnostics...", "Export diagnostics...", "Setup again", "Quit Daylight",
    ]
    static let inkSourceItems = ["Web whiteboard", "Daylight Ink app", "Mirror the tablet"]
    static let holdItems = ["Auto", "Camera", "Studio Split", "Whiteboard Only"]
    static let shareItems = ["Show share window", "How to share it in a call...", "Share settings..."]
    static let transportOptions = ["USB (adb)", "Wi-Fi (Daylight Ink screen stream)"]
    /// AdbSource.label in DaylightKit (Settings.swift); "Bundled (default)" is hidden on a build without the bundled adb.
    static let adbOptionsAll = ["Bundled (default)", "Download on first use", "Use installed adb"]
    static let layoutOptions = ["Studio Split", "Whiteboard Only", "Overlay"]
    /// The Overlay tab's popups and their options (SettingsWindow.swift overlayForm). A SwiftUI Picker in a Form shows
    /// its label as a separate text, so the popup itself is recognised by its label or by its value.
    static let overlayPopups: [(label: String, options: [String])] = [
        ("Segmentation quality", ["Fast", "Balanced", "Accurate"]),
        ("Position", ["Bottom right", "Bottom left", "Top right", "Top left"]),
    ]
    /// HotkeyAction raw values and the row labels of Settings > Hotkeys (SettingsWindow.swift title(_:)), overlay enabled.
    static let hotkeyRows: [(action: String, label: String)] = [
        ("whiteboardOnly", "Whiteboard Only"), ("studioSplit", "Studio Split"), ("keep", "Keep whiteboard (Pin)"),
        ("clear", "Clear"), ("camera", "Camera"), ("overlay", "Overlay"), ("copyLastPage", "Copy last page"),
    ]
    static let allowPrompt = "Allow 'UI test tablet' to draw on Daylight Camera? It connected from 192.168.1.40."
    /// Settings > Advanced, "Follow the pen on camera" (SettingsView.followPenID and followPenExplanation), off by default.
    static let followPenID = "daylight.settings.advanced.followpen"
    static let followPenLabel = "Follow the pen on camera"
    static let followPenExplanation = "On camera, the board zooms in on the area you are writing in, up to 2.5 times, and returns to the full page after 30 s without ink, on Clear and on a new page."

    let testCase: XCTestCase
    let appearance: String
    let shots: Shots
    private var app: XCUIApplication?
    private var notes: [String] = []

    // Inventory for the Docs to UI check.
    private var menuTitles: [String] = []
    private var submenus: [String: [String]] = [:]
    private var tabsShown: Set<String> = []
    private var settingsTexts: [String: [String]] = [:]
    private var welcomeShown: [String] = []

    init(testCase: XCTestCase, appearance: String) {
        self.testCase = testCase
        self.appearance = appearance
        shots = Shots(testCase: testCase, appearance: appearance)
    }

    // MARK: Run

    func runAll() {
        let started = Date()
        let appURL = UITestEnvironment.app
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            XCTFail("[\(appearance)] \(appURL.path) not found; run make mac-debug first (scripts/mac-ui-test.sh checks this too)")
            return
        }
        note("app: \(appURL.path)")
        if let screen = NSScreen.screens.first?.frame { note("screen: \(Int(screen.width)) by \(Int(screen.height))") }
        let first = launch(["--ui-test-overlay-enabled"])
        step("welcome") { checkWelcome(first) }
        step("menu") { checkMenu(first) }
        step("settings") { checkSettings() }
        step("preview") { checkPreview() }
        step("diagnostics") { checkDiagnostics() }
        step("allow") { checkAllow() }
        step("docs") { checkDocs() }
        terminate()
        note(String(format: "total %.1f s", Date().timeIntervalSince(started)))
        attach("notes", notes.joined(separator: "\n"))
    }

    private func step(_ name: String, _ body: () -> Void) {
        let started = Date()
        body()
        note(String(format: "%@ %.1f s", name, Date().timeIntervalSince(started)))
    }

    private func note(_ text: String) {
        notes.append(text)
        print("DaylightUITests [\(appearance)] \(text)")
    }

    private func attach(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = appearance + "-" + name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    // MARK: Launch

    @discardableResult
    func launch(_ options: [String]) -> XCUIApplication {
        terminate()
        let launched = XCUIApplication(url: UITestEnvironment.app)
        launched.launchArguments = ["--ui-test", "--ui-test-appearance", appearance] + options
        launched.launch()
        app = launched
        return launched
    }

    func terminate() {
        if let running = app, running.state != .notRunning {
            running.terminate()
        }
        app = nil
    }

    private func window(_ app: XCUIApplication, id: String, title: String) -> XCUIElement {
        return app.windows.matching(NSPredicate(format: "identifier == %@ OR title == %@", id, title)).firstMatch
    }

    private func titled(_ text: String) -> NSPredicate {
        return NSPredicate(format: "title == %@ OR label == %@", text, text)
    }

    // MARK: 1. Welcome

    private func checkWelcome(_ app: XCUIApplication) {
        let w = window(app, id: "daylight.window.welcome", title: "Welcome to Daylight")
        guard w.waitForExistence(timeout: 10) else {
            shots.take("welcome-missing")
            XCTFail("[\(appearance)] Welcome: the window \"Welcome to Daylight\" (daylight.window.welcome) did not appear within 10 s of the first launch")
            return
        }
        shots.take("welcome", window: w)
        let nodes = flatten(w)
        survey(nodes, surface: "welcome")
        welcomeShown = nodes.flatMap { $0.texts }
        for text in DaylightUISession.welcomeTexts where !nodes.contains(where: { $0.shows(text) }) {
            XCTFail("[\(appearance)] Welcome: no element shows \"\(text)\"")
        }
        expectControl(nodes, types: [.button], text: "Open the preview window", surface: "Welcome")
        expectControl(nodes, types: [.button], text: "Done", surface: "Welcome")
        expectControl(nodes, types: [.checkBox, .toggle], text: "Launch Daylight at login", surface: "Welcome")
    }

    private func expectControl(_ nodes: [UINode], types: [XCUIElement.ElementType], text: String, surface: String) {
        if nodes.contains(where: { types.contains($0.type) && $0.shows(text) }) { return }
        if nodes.contains(where: { $0.shows(text) }) {
            note("\(surface): \"\(text)\" found, but not as \(types.map { String(describing: $0) })")
            return
        }
        XCTFail("[\(appearance)] \(surface): no control \"\(text)\"")
    }

    // MARK: AX dump and the generic overflow check

    /// Prints the surface's elements and asserts each one lies inside its window.
    private func survey(_ nodes: [UINode], surface: String) {
        dump(nodes, surface: surface)
        checkBounds(nodes, surface: surface)
        checkOverlap(nodes, surface: surface)
    }

    /// The leaves the overlap check compares: texts and controls, plus images and groups that carry an identifier
    /// (the Mirror crop view). Unlabeled buttons without an identifier are scroller parts and are skipped.
    private func isOverlapLeaf(_ node: UINode) -> Bool {
        if node.type == .button && node.texts.isEmpty && node.identifier.isEmpty { return false }
        if boundedTypes.contains(node.type) { return true }
        return (node.type == .image || node.type == .group) && !node.identifier.isEmpty
    }

    /// No two visible leaves may intersect by more than 2 pt in both axes, unless one contains the other in the
    /// accessibility tree or one is the other's label text (same parent, same text). Frames inside a scroll view are
    /// cut to its visible area first. Every pair is reported with texts and frames.
    private func checkOverlap(_ nodes: [UINode], surface: String) {
        let leaves = nodes.indices.filter { index in
            let frame = nodes[index].visibleFrame
            return index > 0 && isOverlapLeaf(nodes[index]) && !frame.isNull && frame.width > 0 && frame.height > 0
        }
        var pairs: [String] = []
        for (position, a) in leaves.enumerated() {
            for b in leaves[(position + 1)...] {
                let first = nodes[a], second = nodes[b]
                let overlap = first.visibleFrame.intersection(second.visibleFrame)
                guard !overlap.isNull, overlap.width > 2, overlap.height > 2 else { continue }
                if isAncestor(a, of: b, in: nodes) || isAncestor(b, of: a, in: nodes) { continue }
                if first.parent == second.parent, labels(first, second) || labels(second, first) { continue }
                pairs.append("\(describe(first)) and \(describe(second)) overlap by \(rect(overlap))")
            }
        }
        if !pairs.isEmpty {
            XCTFail("[\(appearance)] \(surface): \(pairs.count) overlapping pair(s): " + pairs.joined(separator: "; "))
        }
    }

    /// True when `text` is a static text naming `control` (its label shown next to it).
    private func labels(_ text: UINode, _ control: UINode) -> Bool {
        return text.type == .staticText && control.type != .staticText && !text.texts.isEmpty
            && text.texts.contains { control.shows($0) }
    }

    private func describe(_ node: UINode) -> String {
        let text = node.texts.first ?? node.identifier
        return "\(typeName(node.type)) \"\(clip(text, 50))\" \(rect(node.frame))"
    }

    /// The first element under the tab bar must sit within 40 pt of it (content top-aligned, no empty band).
    private func checkTopAligned(_ nodes: [UINode], tab: String) {
        let tabTypes: Set<XCUIElement.ElementType> = [.radioButton, .tab, .button, .toggle]
        let tabButtons = nodes.filter { tabTypes.contains($0.type) && DaylightUISession.tabs.contains($0.name) }
        guard let barBottom = tabButtons.map({ $0.frame.maxY }).max() else {
            XCTFail("[\(appearance)] Settings > \(tab): no tab buttons found to measure the content's top against")
            return
        }
        let content = nodes.dropFirst().filter { node in
            isOverlapLeaf(node) && !tabButtons.contains(where: { $0.frame == node.frame }) && node.frame.minY >= barBottom - 1
                && node.frame.width > 0 && node.frame.height > 0
        }
        guard let first = content.min(by: { $0.frame.minY < $1.frame.minY }) else {
            XCTFail("[\(appearance)] Settings > \(tab): no content under the tab bar")
            return
        }
        let gap = first.frame.minY - barBottom
        XCTAssertLessThanOrEqual(gap, 40, "[\(appearance)] Settings > \(tab): the first element \(describe(first)) starts \(Int(gap)) pt below the tab bar (bottom \(Int(barBottom))); the content is not top-aligned")
    }

    /// Scrolls the tab's scroll view until the element is hittable (at most four steps toward it).
    private func scrollIntoView(_ element: XCUIElement, in w: XCUIElement) -> Bool {
        if element.isHittable { return true }
        let scrollView = w.scrollViews.firstMatch
        guard scrollView.exists else { return false }
        for _ in 0..<4 {
            // A negative deltaY scrolls down (run 37182692894: -2000 moved the Mirror rows up).
            let delta = scrollView.frame.midY - element.frame.midY
            if abs(delta) < 1 { break }
            scrollView.scroll(byDeltaX: 0, deltaY: delta)
            if element.isHittable { return true }
        }
        return element.isHittable
    }

    /// One line per element, "DaylightUITests [<appearance>] ax <surface>: <type> [id=<identifier>] "<text>" (x, y, w, h)",
    /// for controls, texts, windows, scroll views and anything with an identifier.
    private func dump(_ nodes: [UINode], surface: String) {
        let structural: Set<XCUIElement.ElementType> = [.window, .scrollView, .textView, .tabGroup, .tab, .image]
        for node in nodes where boundedTypes.contains(node.type) || structural.contains(node.type) || !node.identifier.isEmpty {
            var line = "ax \(surface): \(typeName(node.type))"
            if !node.identifier.isEmpty { line += " id=\(node.identifier)" }
            let name = node.name
            if !name.isEmpty { line += " \"\(clip(name))\"" }
            if !node.value.isEmpty, node.value != name { line += " =\"\(clip(node.value, name.isEmpty ? 60 : 30))\"" }
            if !node.enabled { line += " disabled" }
            line += " " + rect(node.frame)
            print("DaylightUITests [\(appearance)] \(line)")
        }
    }

    /// The window must lie on the screen, and every visible control or text (boundedTypes, non-empty frame) must lie
    /// horizontally inside the window frame, and vertically too unless it sits in a scroll view (1 pt tolerance).
    /// Every offender is reported with its text.
    private func checkBounds(_ nodes: [UINode], surface: String) {
        guard let root = nodes.first, root.type == .window || root.type == .sheet, root.frame.width > 0 else {
            XCTFail("[\(appearance)] \(surface): no window frame to check the elements against")
            return
        }
        // The window itself must lie on the main screen (NSScreen frames are bottom-left based, but the primary screen
        // starts at 0, 0 in both systems, so its size is all that is needed).
        if let screen = NSScreen.screens.first?.frame, screen.width > 0 {
            let display = CGRect(x: 0, y: 0, width: screen.width, height: screen.height).insetBy(dx: -1, dy: -1)
            XCTAssertTrue(display.contains(root.frame), "[\(appearance)] \(surface): the window frame \(rect(root.frame)) is not inside the screen (0, 0, \(Int(screen.width)), \(Int(screen.height)))")
        }
        let bounds = root.frame.insetBy(dx: -1, dy: -1)
        var offenders: [String] = []
        for node in nodes.dropFirst() where boundedTypes.contains(node.type) {
            let frame = node.frame
            guard !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0 else { continue }
            var sides: [String] = []
            if frame.minX < bounds.minX { sides.append("left") }
            if frame.maxX > bounds.maxX { sides.append("right") }
            if !node.inScroll {
                if frame.minY < bounds.minY { sides.append("top") }
                if frame.maxY > bounds.maxY { sides.append("bottom") }
            }
            guard !sides.isEmpty else { continue }
            let text = node.texts.first ?? node.identifier
            offenders.append("\(typeName(node.type)) \"\(clip(text, 80))\" \(rect(frame)) past the \(sides.joined(separator: "/")) edge")
        }
        // One line, so the log filter of scripts/mac-ui-test.sh (": error: -[") shows every offender.
        if !offenders.isEmpty {
            XCTFail("[\(appearance)] \(surface): \(offenders.count) element(s) outside the window frame \(rect(root.frame)): " + offenders.joined(separator: "; "))
        }
    }

    // MARK: 4. Menu

    private func checkMenu(_ app: XCUIApplication) {
        var path = "status item"
        var menu: XCUIElement?
        if let item = statusItem(app) {
            item.click()
            menu = openMenu(app, timeout: 5)
            if menu == nil { app.typeKey(.escape, modifierFlags: []) }
        }
        if menu == nil {
            path = "fallback: --ui-test-open menu (the status item was not reachable within 5 s or its click opened no menu)"
            let relaunched = launch(["--ui-test-overlay-enabled", "--ui-test-open", "menu"])
            menu = openMenu(relaunched, timeout: 10)
        }
        note("menu path: \(path)")
        attach("menu-path", path)
        guard let opened = menu, let current = self.app else {
            shots.take("menu-missing")
            XCTFail("[\(appearance)] Menu: the status item menu did not open by the status item nor by --ui-test-open menu")
            return
        }
        shots.take("menu")
        let nodes = flatten(opened)
        // Direct items of the top menu: the snapshot's own children of type menuItem, in order.
        let items: [String]
        if let snapshot = try? opened.snapshot() {
            items = snapshot.children.filter { $0.elementType == .menuItem }.map { $0.title.isEmpty ? $0.label : $0.title }.filter { !$0.isEmpty }
        } else {
            items = nodes.filter { $0.type == .menuItem }.map { $0.name }.filter { !$0.isEmpty }
        }
        menuTitles = items
        attach("menu-items", items.joined(separator: "\n"))
        var cursor = 0
        for expected in DaylightUISession.menuOrder {
            let rest = Array(items[min(cursor, items.count)...])
            if let offset = rest.firstIndex(where: { $0 == expected || $0.hasPrefix(expected + "  (") }) {
                cursor += offset + 1
            } else {
                XCTFail("[\(appearance)] Menu: \"\(expected)\" missing or out of order; the menu read: \(items)")
            }
        }
        let ink = readSubmenu(opened, parent: "Ink source", first: DaylightUISession.inkSourceItems[0])
        XCTAssertEqual(ink, DaylightUISession.inkSourceItems, "[\(appearance)] Menu: Ink source submenu")
        let hold = readSubmenu(opened, parent: "Hold", first: DaylightUISession.holdItems[0])
        XCTAssertEqual(hold, DaylightUISession.holdItems, "[\(appearance)] Menu: Hold submenu")
        let share = readSubmenu(opened, parent: "Share the whiteboard", first: DaylightUISession.shareItems[0])
        XCTAssertEqual(share, DaylightUISession.shareItems, "[\(appearance)] Menu: Share the whiteboard submenu")
        current.typeKey(.escape, modifierFlags: [])
        current.typeKey(.escape, modifierFlags: [])
    }

    private func statusItem(_ app: XCUIApplication) -> XCUIElement? {
        let byIdentifier = app.descendants(matching: .any).matching(identifier: "daylight.statusitem").firstMatch
        if app.statusItems.firstMatch.waitForExistence(timeout: 3) { return app.statusItems.firstMatch }
        if app.menuBars.statusItems.firstMatch.exists { return app.menuBars.statusItems.firstMatch }
        if byIdentifier.waitForExistence(timeout: 2) { return byIdentifier }
        return nil
    }

    private func openMenu(_ app: XCUIApplication, timeout: TimeInterval) -> XCUIElement? {
        let quit = app.menuItems.matching(titled("Quit Daylight")).firstMatch
        guard quit.waitForExistence(timeout: timeout) else { return nil }
        let menu = app.menus.containing(titled("Quit Daylight")).firstMatch
        return menu.exists ? menu : nil
    }

    private func readSubmenu(_ menu: XCUIElement, parent: String, first: String) -> [String] {
        let item = menu.menuItems.matching(titled(parent)).firstMatch
        guard item.exists else { return [] }
        item.hover()
        let child = item.menuItems.matching(titled(first)).firstMatch
        if !child.waitForExistence(timeout: 3) {
            item.click()
            _ = child.waitForExistence(timeout: 3)
        }
        shots.take("menu-" + slug(parent))
        let titles = flatten(item).dropFirst().filter { $0.type == .menuItem }.map { $0.name }.filter { !$0.isEmpty }
        submenus[parent] = titles
        return titles
    }

    // MARK: 2. Settings

    private func checkSettings() {
        var current = launch(["--ui-test-overlay-enabled", "--ui-test-open", "settings"])
        var w = window(current, id: "daylight.window.settings", title: "Daylight Settings")
        guard w.waitForExistence(timeout: 10) else {
            shots.take("settings-missing")
            XCTFail("[\(appearance)] Settings: the window \"Daylight Settings\" (daylight.window.settings) did not appear within 10 s")
            return
        }
        let names = Set(flatten(w).flatMap { $0.texts })
        tabsShown = Set(DaylightUISession.tabs.filter { names.contains($0) })
        for tab in DaylightUISession.tabs {
            if !selectTab(w, tab) {
                // Every tab must be one click away (a tab row wider than the window hides its last tabs). The relaunch
                // only lets the rest of the tab's checks run; the tab still fails.
                XCTFail("[\(appearance)] Settings > \(tab): tab not reachable: no hittable tab button \"\(tab)\" in the window (tab row clipped?); its checks ran after a relaunch with --ui-test-settings-tab \(tab)")
                note("Settings: clicking the tab \(tab) failed; relaunched with --ui-test-settings-tab \(tab)")
                current = launch(["--ui-test-overlay-enabled", "--ui-test-open", "settings", "--ui-test-settings-tab", tab])
                w = window(current, id: "daylight.window.settings", title: "Daylight Settings")
                guard w.waitForExistence(timeout: 10) else {
                    XCTFail("[\(appearance)] Settings > \(tab): neither a tab click nor --ui-test-settings-tab opened it")
                    continue
                }
            }
            inspectTab(w, tab: tab, app: current)
        }
    }

    private func selectTab(_ w: XCUIElement, _ tab: String) -> Bool {
        let predicate = titled(tab)
        let candidates = [
            w.tabGroups.firstMatch.radioButtons.matching(predicate).firstMatch,
            w.radioButtons.matching(predicate).firstMatch,
            w.tabs.matching(predicate).firstMatch,
            w.buttons.matching(predicate).firstMatch,
        ]
        for candidate in candidates where candidate.exists && candidate.isHittable {
            candidate.click()
            return true
        }
        return false
    }

    private func inspectTab(_ w: XCUIElement, tab: String, app: XCUIApplication) {
        let name = "settings-" + slug(tab)
        shots.take(name + "-top", window: w)
        let topNodes = flatten(w)
        survey(topNodes, surface: name + "-top")
        checkTopAligned(topNodes, tab: tab)
        var texts = topNodes.flatMap { $0.texts }
        var seen = Set<String>()
        var popups = gatherPopups(w, app: app, surface: "Settings > \(tab)", seen: &seen)
        switch tab {
        case "General":
            if let layout = popups.first(where: { $0.label == "Layout when engaging" || $0.value == "Studio Split" }) {
                for option in DaylightUISession.layoutOptions where !layout.options.contains(option) {
                    XCTFail("[\(appearance)] Settings > General > \"Layout when engaging\" lacks \"\(option)\" with overlay enabled; offered \(layout.options)")
                }
            } else {
                XCTFail("[\(appearance)] Settings > General: no \"Layout when engaging\" popup found")
            }
        case "Mirror":
            checkMirror(popups, texts: texts)
            selectWiFiTransport(w, app: app)
            shots.take(name + "-wifi", window: w)
            texts += flatten(w).flatMap { $0.texts }
        case "Hotkeys":
            checkHotkeyRows(flatten(w))
        case "Advanced":
            checkFollowPen(w, step: name)
        case "Overlay":
            let nodes = flatten(w)
            for (label, expected) in DaylightUISession.overlayPopups {
                let matches: (String, String) -> Bool = { name, value in name == label || expected.contains(value) }
                if let popup = popups.first(where: { matches($0.label, $0.value) }) {
                    XCTAssertEqual(popup.options, expected, "[\(appearance)] Settings > Overlay > \"\(label)\" options")
                } else if let node = nodes.first(where: { $0.type == .popUpButton && (matches($0.label, $0.value) || $0.title == label) }) {
                    XCTFail("[\(appearance)] Settings > Overlay: the \"\(label)\" popup \(rect(node.frame)) is " + (node.enabled ? "enabled but not hittable" : "disabled with --ui-test-overlay-enabled"))
                } else {
                    XCTFail("[\(appearance)] Settings > Overlay: no \"\(label)\" popup (by label, or by a value among \(expected))")
                }
            }
        default:
            break
        }
        checkLast(w, tab: tab, step: name)
        texts += flatten(w).flatMap { $0.texts }
        popups += gatherPopups(w, app: app, surface: "Settings > \(tab)", seen: &seen)
        texts += popups.flatMap { [$0.label] + $0.options }
        settingsTexts[tab] = texts
    }

    /// The "Follow the pen on camera" switch (`daylight.settings.advanced.followpen`) exists, is visible inside the
    /// window, is off with the throwaway defaults suite (UITestMode.freshDefaults), turns on with a click and off again
    /// with a second one. Screenshots NN-settings-advanced-followpen and NN-settings-advanced-followpen-on.
    private func checkFollowPen(_ w: XCUIElement, step: String) {
        let identifier = DaylightUISession.followPenID
        let toggle = w.descendants(matching: .any).matching(identifier: identifier).firstMatch
        guard toggle.waitForExistence(timeout: 3) else {
            shots.take(step + "-followpen-missing", window: w)
            XCTFail("[\(appearance)] Settings > Advanced: no element with identifier \(identifier) (\"\(DaylightUISession.followPenLabel)\")")
            return
        }
        shots.take(step + "-followpen", window: w)
        let nodes = flatten(w)
        let windowFrame = nodes.first?.frame ?? w.frame
        if let node = nodes.first(where: { $0.identifier == identifier }) {
            let switchTypes: Set<XCUIElement.ElementType> = [.checkBox, .toggle, .switch]
            if !switchTypes.contains(node.type) {
                note("Settings > Advanced: \(identifier) is a \(typeName(node.type)), not a checkBox, toggle or switch")
            }
            XCTAssertTrue(node.texts.contains { $0.hasPrefix(DaylightUISession.followPenLabel) } || nodes.contains { $0.type == .staticText && $0.shows(DaylightUISession.followPenLabel) },
                          "[\(appearance)] Settings > Advanced: no text \"\(DaylightUISession.followPenLabel)\" on or next to \(identifier) \(rect(node.frame))")
            XCTAssertTrue(windowFrame.insetBy(dx: -1, dy: -1).contains(node.frame), "[\(appearance)] Settings > Advanced: \(identifier) frame \(rect(node.frame)) is not inside the window frame \(rect(windowFrame))")
        } else {
            XCTFail("[\(appearance)] Settings > Advanced: \(identifier) exists but is not in the window's snapshot")
        }
        if !nodes.contains(where: { $0.shows(DaylightUISession.followPenExplanation) }) {
            XCTFail("[\(appearance)] Settings > Advanced: no text \"\(DaylightUISession.followPenExplanation)\" under the switch")
        }
        guard scrollIntoView(toggle, in: w) else {
            XCTFail("[\(appearance)] Settings > Advanced: \(identifier) \(rect(toggle.frame)) is not hittable (covered or scrolled out of sight)")
            return
        }
        let initial = switchState(toggle)
        XCTAssertEqual(initial, "0", "[\(appearance)] Settings > Advanced: \"\(DaylightUISession.followPenLabel)\" should be off with fresh defaults; its value reads \(initial)")
        toggle.click()
        let on = waitForSwitch(toggle, toLeave: initial)
        shots.take(step + "-followpen-on", window: w)
        XCTAssertEqual(on, "1", "[\(appearance)] Settings > Advanced: one click on \"\(DaylightUISession.followPenLabel)\" should turn it on; its value went from \(initial) to \(on)")
        toggle.click()
        let off = waitForSwitch(toggle, toLeave: on)
        XCTAssertEqual(off, "0", "[\(appearance)] Settings > Advanced: a second click on \"\(DaylightUISession.followPenLabel)\" should turn it off again; its value went from \(on) to \(off)")
    }

    /// A switch's accessibility value as "0" or "1" (macOS reports a checkbox value as a number; a String is passed
    /// through), or "(none)" when it has none.
    private func switchState(_ element: XCUIElement) -> String {
        guard let value = element.value else { return "(none)" }
        if let number = value as? NSNumber { return number.intValue == 0 ? "0" : "1" }
        if let text = value as? String { return text }
        return String(describing: value)
    }

    /// Waits up to 2 s for the switch's value to differ from `previous`, and returns the value it reads then.
    private func waitForSwitch(_ element: XCUIElement, toLeave previous: String) -> String {
        let deadline = Date().addingTimeInterval(2)
        var current = switchState(element)
        while current == previous && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            current = switchState(element)
        }
        return current
    }

    /// Every hotkey field (`daylight.settings.hotkeys.recorder.<action>`) is 20 to 30 pt tall and vertically centred
    /// on its row label within 4 pt (run 37183673841: fields about 40 pt tall, chord drawn at the bottom).
    private func checkHotkeyRows(_ nodes: [UINode]) {
        for row in DaylightUISession.hotkeyRows {
            let identifier = "daylight.settings.hotkeys.recorder." + row.action
            guard let field = nodes.first(where: { $0.identifier == identifier }) else {
                XCTFail("[\(appearance)] Settings > Hotkeys: no field \(identifier)")
                continue
            }
            XCTAssertTrue(field.enabled, "[\(appearance)] Settings > Hotkeys: \(identifier) reads as disabled to accessibility")
            XCTAssertTrue(field.frame.height >= 20 && field.frame.height <= 30, "[\(appearance)] Settings > Hotkeys: \(identifier) is \(Int(field.frame.height)) pt tall \(rect(field.frame)); expected 20 to 30")
            guard let label = nodes.first(where: { $0.type == .staticText && $0.shows(row.label) && abs($0.frame.midY - field.frame.midY) < 60 }) else {
                XCTFail("[\(appearance)] Settings > Hotkeys: no label \"\(row.label)\" near \(identifier) \(rect(field.frame))")
                continue
            }
            let offset = abs(label.frame.midY - field.frame.midY)
            XCTAssertLessThanOrEqual(offset, 4, "[\(appearance)] Settings > Hotkeys: the label \"\(row.label)\" \(rect(label.frame)) is \(Int(offset)) pt off the vertical centre of its field \(rect(field.frame))")
        }
    }

    /// Opens every enabled popup button of the window (scrolled into view first; one that stays unhittable fails),
    /// reads its menu items, and closes it with Escape.
    private func gatherPopups(_ w: XCUIElement, app: XCUIApplication, surface: String, seen: inout Set<String>) -> [PopupInfo] {
        var result: [PopupInfo] = []
        let query = w.popUpButtons
        let count = query.count
        for index in 0..<count {
            let popup = query.element(boundBy: index)
            guard popup.exists, popup.isEnabled else { continue }
            let label = popup.label.isEmpty ? popup.title : popup.label
            let value = (popup.value as? String) ?? ""
            let key = label + "|" + value
            if seen.contains(key) { continue }
            seen.insert(key)
            // Every enabled popup must take a click once scrolled to; one that stays unhittable is covered.
            guard scrollIntoView(popup, in: w) else {
                XCTFail("[\(appearance)] \(surface): the popup \"\(label.isEmpty ? value : label)\" \(rect(popup.frame)) is not hittable after scrolling to it (covered by another view?)")
                continue
            }
            popup.click()
            _ = popup.menuItems.firstMatch.waitForExistence(timeout: 3)
            let options = flatten(popup).filter { $0.type == .menuItem }.map { $0.name }.filter { !$0.isEmpty }
            app.typeKey(.escape, modifierFlags: [])
            _ = popup.menuItems.firstMatch.waitForNonExistence(timeout: 2)
            result.append(PopupInfo(label: label, value: value, options: options))
        }
        return result
    }

    private func checkMirror(_ popups: [PopupInfo], texts: [String]) {
        for label in ["Transport", "adb source"] where !texts.contains(label) && !popups.contains(where: { $0.label == label }) {
            XCTFail("[\(appearance)] Settings > Mirror: no \"\(label)\" picker label")
        }
        if let transport = popups.first(where: { $0.label == "Transport" || DaylightUISession.transportOptions.contains($0.value) }) {
            XCTAssertEqual(transport.options, DaylightUISession.transportOptions, "[\(appearance)] Settings > Mirror > \"Transport\" options")
        } else {
            XCTFail("[\(appearance)] Settings > Mirror: the \"Transport\" popup was not found or not hittable at the top of the tab")
        }
        let adbExpected = UITestEnvironment.appBundlesAdb ? DaylightUISession.adbOptionsAll : Array(DaylightUISession.adbOptionsAll.dropFirst())
        if let adb = popups.first(where: { $0.label == "adb source" || DaylightUISession.adbOptionsAll.contains($0.value) }) {
            XCTAssertEqual(adb.options, adbExpected, "[\(appearance)] Settings > Mirror > \"adb source\" options")
        } else {
            XCTFail("[\(appearance)] Settings > Mirror: the \"adb source\" popup was not found or not hittable at the top of the tab")
        }
    }

    /// Picks "Wi-Fi (Daylight Ink screen stream)" so the Wi-Fi rows ("Change threshold: N canvas cells" and the other
    /// stream steppers) are on screen for the screenshots and the Docs to UI check (the defaults suite is throwaway).
    private func selectWiFiTransport(_ w: XCUIElement, app: XCUIApplication) {
        let popup = w.popUpButtons.matching(NSPredicate(format: "value == %@", DaylightUISession.transportOptions[0])).firstMatch
        guard popup.exists, scrollIntoView(popup, in: w) else {
            XCTFail("[\(appearance)] Settings > Mirror: the Transport popup was not hittable; the Wi-Fi rows were not shown")
            return
        }
        popup.click()
        let item = popup.menuItems.matching(titled(DaylightUISession.transportOptions[1])).firstMatch
        if item.waitForExistence(timeout: 3) {
            item.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    /// Scrolls to the bottom where the tab scrolls, then asserts `daylight.settings.<tab>.last` lies inside the window.
    private func checkLast(_ w: XCUIElement, tab: String, step: String) {
        let identifier = "daylight.settings.\(tab.lowercased()).last"
        let scrollView = w.scrollViews.firstMatch
        let scrolls = scrollView.exists
        if scrolls {
            scrollView.scroll(byDeltaX: 0, deltaY: -2000)
            shots.take(step + "-bottom", window: w)
        }
        var verdict = lastElement(w, identifier: identifier)
        if scrolls, verdict.node != nil, !verdict.inside {
            // The sign of deltaY that reaches the bottom is not documented; try the other direction once.
            scrollView.scroll(byDeltaX: 0, deltaY: 4000)
            shots.take(step + "-bottom-reverse", window: w)
            verdict = lastElement(w, identifier: identifier)
            if verdict.inside { note("Settings > \(tab): a positive deltaY scrolled to the bottom") }
        }
        if scrolls { survey(flatten(w), surface: step + "-bottom") }
        guard let node = verdict.node else {
            XCTFail("[\(appearance)] Settings > \(tab): no element with identifier \(identifier)")
            return
        }
        XCTAssertTrue(verdict.inside, "[\(appearance)] Settings > \(tab): \(identifier) frame \(node.frame) is not inside the window frame \(verdict.window) (cut off)")
    }

    private func lastElement(_ w: XCUIElement, identifier: String) -> (node: UINode?, inside: Bool, window: CGRect) {
        let nodes = flatten(w)
        let windowFrame = nodes.first?.frame ?? w.frame
        guard let node = nodes.first(where: { $0.identifier.lowercased() == identifier }) else {
            return (nil, false, windowFrame)
        }
        return (node, windowFrame.insetBy(dx: -1, dy: -1).contains(node.frame), windowFrame)
    }

    // MARK: 3. Preview, Diagnostics, Allow

    private func checkPreview() {
        let current = launch(["--ui-test-open", "preview"])
        let w = window(current, id: "daylight.window.preview", title: "Daylight Camera preview")
        guard w.waitForExistence(timeout: 10) else {
            shots.take("preview-missing")
            XCTFail("[\(appearance)] Preview: the window \"Daylight Camera preview\" did not appear within 10 s")
            return
        }
        shots.take("preview", window: w)
        XCTAssertGreaterThan(w.frame.width, 100, "[\(appearance)] Preview: window frame \(w.frame)")
    }

    private func checkDiagnostics() {
        let current = launch(["--ui-test-open", "diagnostics"])
        let w = window(current, id: "daylight.window.diagnostics", title: "Daylight Diagnostics")
        guard w.waitForExistence(timeout: 10) else {
            shots.take("diagnostics-missing")
            XCTFail("[\(appearance)] Diagnostics: the window \"Daylight Diagnostics\" did not appear within 10 s")
            return
        }
        shots.take("diagnostics", window: w)
        let nodes = flatten(w)
        survey(nodes, surface: "diagnostics")
        expectControl(nodes, types: [.button], text: "Copy diagnostics", surface: "Diagnostics")
        let shown = nodes.flatMap { $0.texts }.joined(separator: "\n")
        // The window shows the head of the report; its first lines must be on screen.
        for fact in ["signed=false", "bundle: "] where !shown.contains(fact) {
            XCTFail("[\(appearance)] Diagnostics: the window does not show \"\(fact)\"")
        }
        // The whole report is what "Copy diagnostics" puts on the pasteboard (the same provider as the text view). The
        // text view's accessibility value is not used for the tail: run 37180339019 showed every early fact in it but
        // not the "log (last N lines):" line, which the report always ends with (DiagnosticsReport.text).
        let report = copiedDiagnostics(w)
        let tail = String(shown.suffix(120)).replacingOccurrences(of: "\n", with: " | ")
        note("Diagnostics: accessibility text \(shown.count) chars (log line \(shown.contains("log (last ") ? "present" : "absent"), ends \"\(tail)\"); copied report \(report.count) chars")
        guard !report.isEmpty else {
            XCTFail("[\(appearance)] Diagnostics: \"Copy diagnostics\" put no text on the pasteboard within 3 s")
            return
        }
        for fact in ["signed=false", "bundle: ", "extension: ", "sink: ", "listener: ", "log (last "] where !report.contains(fact) {
            XCTFail("[\(appearance)] Diagnostics: the copied report lacks \"\(fact)\"")
        }
    }

    /// Clicks "Copy diagnostics" and returns the pasteboard string ("" when the button is missing or nothing arrived).
    private func copiedDiagnostics(_ w: XCUIElement) -> String {
        let button = w.buttons.matching(titled("Copy diagnostics")).firstMatch
        guard button.exists else { return "" }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let before = pasteboard.changeCount
        button.click()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if pasteboard.changeCount != before, let text = pasteboard.string(forType: .string), !text.isEmpty {
                return text
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return ""
    }

    private func checkAllow() {
        let current = launch(["--ui-test-open", "allow"])
        let panelWindow = current.windows.matching(identifier: "daylight.panel.allow").firstMatch
        let panelListed = panelWindow.waitForExistence(timeout: 10)
        if !panelListed {
            // A non-activating panel may not be listed as a window; fall back to the prompt text anywhere in the app.
            note("Allow panel: daylight.panel.allow is not listed among the windows; searched the whole app")
        }
        let scope: XCUIElement = panelListed ? panelWindow : current
        let prompt = scope.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", DaylightUISession.allowPrompt, DaylightUISession.allowPrompt)).firstMatch
        let shown = prompt.waitForExistence(timeout: panelListed ? 3 : 10)
        shots.take("allow", window: panelListed ? panelWindow : nil)
        if panelListed {
            survey(flatten(panelWindow), surface: "allow")
        } else {
            note("Allow panel: no window element, so no AX dump and no frame check")
        }
        XCTAssertTrue(shown, "[\(appearance)] Allow panel: no text \"\(DaylightUISession.allowPrompt)\"")
        for title in ["Allow", "Not now"] {
            XCTAssertTrue(scope.buttons.matching(titled(title)).firstMatch.exists, "[\(appearance)] Allow panel: no button \"\(title)\"")
        }
    }

    // MARK: 5. Docs to UI

    private func checkDocs() {
        let url = UITestEnvironment.expectations
        guard let data = try? Data(contentsOf: url) else {
            XCTFail("[\(appearance)] Docs to UI: cannot read \(url.path); scripts/ui-expectations.sh writes it (make mac-ui-test runs it first)")
            return
        }
        guard let items = try? JSONDecoder().decode([DocExpectation].self, from: data) else {
            XCTFail("[\(appearance)] Docs to UI: \(url.path) is not the expected JSON array")
            return
        }
        note("docs: inventory menu \(menuTitles.count), submenus \(submenus.count), tabs \(tabsShown.count), settings tabs read \(settingsTexts.count), welcome texts \(welcomeShown.count)")
        var misses: [String] = []
        var checked = 0
        for item in items {
            checked += 1
            if found(item) { continue }
            var place = item.kind
            if let tab = item.tab { place += " in Settings > \(tab)" }
            if let parent = item.parent { place += " under \"\(parent)\"" }
            misses.append("\(item.source): \"\(item.text)\" (\(place))")
        }
        note("docs: checked \(checked) of \(items.count), misses \(misses.count) (\(url.lastPathComponent))")
        attach("docs-to-ui", "\(items.count) doc strings, \(misses.count) not found\n" + misses.joined(separator: "\n"))
        if items.isEmpty {
            XCTFail("[\(appearance)] Docs to UI: \(url.path) holds no strings; scripts/ui-expectations.sh found nothing to check")
        }
        if checked != items.count {
            XCTFail("[\(appearance)] Docs to UI: checked \(checked) of \(items.count) strings")
        }
        if !misses.isEmpty {
            XCTFail("[\(appearance)] Docs to UI: \(misses.count) of \(items.count) strings the docs quote are not in the UI: " + misses.joined(separator: "; "))
        }
    }

    private func found(_ item: DocExpectation) -> Bool {
        let text = item.text
        switch item.kind {
        case "menu":
            return menuTitles.contains { $0 == text || $0.hasPrefix(text) }
        case "submenu":
            let pool = item.parent.flatMap { submenus[$0] } ?? submenus.values.flatMap { $0 }
            return pool.contains { $0 == text || $0.hasPrefix(text) }
        case "tab":
            return tabsShown.contains(text)
        case "setting", "option":
            let pool = item.tab.flatMap { settingsTexts[$0] } ?? settingsTexts.values.flatMap { $0 }
            return pool.contains { $0 == text || $0.hasPrefix(text) }
        case "welcome":
            return welcomeShown.contains { $0.contains(text) }
        default:
            return false
        }
    }
}
