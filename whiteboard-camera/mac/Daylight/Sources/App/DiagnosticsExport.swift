import AppKit
import DaylightKit
import Foundation

/// Menu bar > Export diagnostics... (docs/FEEDBACK.md): a small alert with "Run self-test first", then one zip in
/// ~/Documents/Daylight Camera that Finder reveals. The main thread only reads the app's state into a snapshot; the
/// collecting and writing run on `DiagnosticsExporter.queue`, and progress and errors reach the menu as SPEC 13.3
/// rows 44 to 47 through `AppModel.noteFailure`.
///
/// Folder choice: the zip always goes to ~/Documents/Daylight Camera, the folder `SessionSaver` writes sessions into
/// by default (`SessionSaver.defaultRoot()` plus `Settings.documentsFolderName`). When the owner moved the session
/// folder in Settings the export still uses the default, because row 45 tells the owner "Documents > Daylight Camera".
final class DiagnosticsExport {
    private weak var app: AppDelegate?
    private var running = false

    init(app: AppDelegate) {
        self.app = app
    }

    static func exportFolder() -> URL {
        return SessionSaver.defaultRoot().appendingPathComponent(Settings.documentsFolderName, isDirectory: true)
    }

    /// The app's own folders, whose paths stay readable in the zip: the export folder, the owner's save folder, the
    /// Application Support folder (clients.json), ~/Library/Logs, and the bundle when it is in /Applications.
    static func keptRoots(bundlePath: String, saveDirectory: URL?, home: String) -> [String] {
        var roots = [
            exportFolder().path,
            ClientRegistry.defaultFileURL().deletingLastPathComponent().path,
            home + "/Library/Logs",
        ]
        if let save = saveDirectory { roots.append(save.path) }
        if bundlePath.hasPrefix("/Applications/") { roots.append(bundlePath) }
        return roots
    }

    static func config(saveDirectory: URL?) -> DiagnosticsExporter.Config {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bundle = Bundle.main
        return DiagnosticsExporter.Config(
            folder: exportFolder(),
            clientsFile: ClientRegistry.defaultFileURL(),
            vendorDirectory: bundle.resourceURL?.appendingPathComponent("Vendor"),
            selfTestExecutable: bundle.executableURL,
            home: home,
            keptRoots: keptRoots(bundlePath: bundle.bundlePath, saveDirectory: saveDirectory, home: home))
    }

    /// Main thread: everything the export needs from the running app.
    static func snapshot(_ app: AppDelegate) -> DiagnosticsExporter.Snapshot {
        let bundle = Bundle.main
        return DiagnosticsExporter.Snapshot(
            date: Date(),
            diagnosticsText: app.diagnosticsText(),
            settings: app.settingsStore.settings,
            perfLines: app.telemetry.recentLines.filter { $0.hasPrefix("perf ") },
            tabletFacts: TabletFactsStore.shared.all,
            adbSource: AdbSourceStatus.diagnostics(),
            version: app.model.version,
            build: app.model.build,
            signed: app.signed,
            bundlePath: bundle.bundlePath,
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown")
    }

    /// The menu item: the alert, then the export. A second click while one runs does nothing.
    func start() {
        guard !running else { return }
        let alert = NSAlert()
        alert.messageText = "Export diagnostics"
        alert.informativeText = "Daylight saves one zip file in Documents > Daylight Camera. Send it back after the test."
        let selfTest = NSButton(checkboxWithTitle: "Run self-test first", target: nil, action: nil)
        selfTest.state = .off
        alert.accessoryView = selfTest
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(selfTest: selfTest.state == .on)
    }

    func run(selfTest: Bool) {
        guard !running, let app = app else { return }
        running = true
        let snapshot = DiagnosticsExport.snapshot(app)
        let exporter = DiagnosticsExporter(config: DiagnosticsExport.config(saveDirectory: app.settingsStore.settings.saveDirectory))
        let model = app.model
        exporter.onEvent = { event in
            let failure = event.failure
            DispatchQueue.main.async { model.noteFailure(failure.0, failure.1) }
        }
        exporter.start(snapshot, runSelfTest: selfTest) { [weak self] result in
            DispatchQueue.main.async {
                self?.running = false
                if case let .success(outcome) = result {
                    NSWorkspace.shared.activateFileViewerSelecting([outcome.url])
                }
            }
        }
    }
}
