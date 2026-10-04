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
    static let allowPrompt = "Allow 'UI test tablet' to draw on Daylight Camera? It connected from 192.168.1.40."

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
    }

    /// One line per element, "DaylightUITests [<appearance>] ax <surface>: <type> [id=<identifier>] "<text>" (x, y, w, h)",
    /// for controls, texts, windows, scroll views and anything with an identifier.
    private func dump(_ nodes: [UINode], surface: String) {
        let structural: Set<XCUIElement.ElementType> = [.window, .scrollView, .textView, .tabGroup]
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

    /// Every visible control or text (boundedTypes, non-empty frame) must lie horizontally inside the window frame,
    /// and vertically too unless it sits in a scroll view (1 pt tolerance). Every offender is reported with its text.
    private func checkBounds(_ nodes: [UINode], surface: String) {
        guard let root = nodes.first, root.type == .window || root.type == .sheet, root.frame.width > 0 else {
            XCTFail("[\(appearance)] \(surface): no window frame to check the elements against")
            return
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
        var texts = topNodes.flatMap { $0.texts }
        var seen = Set<String>()
        var popups = gatherPopups(w, app: app, seen: &seen)
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
        popups += gatherPopups(w, app: app, seen: &seen)
        texts += popups.flatMap { [$0.label] + $0.options }
        settingsTexts[tab] = texts
    }

    /// Opens every hittable, enabled popup button of the window, reads its menu items, and closes it with Escape.
    private func gatherPopups(_ w: XCUIElement, app: XCUIApplication, seen: inout Set<String>) -> [PopupInfo] {
        var result: [PopupInfo] = []
        let query = w.popUpButtons
        let count = query.count
        for index in 0..<count {
            let popup = query.element(boundBy: index)
            guard popup.exists, popup.isEnabled, popup.isHittable else { continue }
            let label = popup.label.isEmpty ? popup.title : popup.label
            let value = (popup.value as? String) ?? ""
            let key = label + "|" + value
            if seen.contains(key) { continue }
            seen.insert(key)
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
        guard popup.exists, popup.isHittable else {
            note("Settings > Mirror: the Transport popup was not hittable; the Wi-Fi rows were not shown")
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
