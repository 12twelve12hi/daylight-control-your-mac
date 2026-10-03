import AppKit
import DaylightKit
import SwiftUI

/// Observable inputs of the onboarding state machine plus the buttons' actions, filled by the app.
final class OnboardingModel: ObservableObject {
    struct Actions {
        var requestCamera: () -> Void = {}
        var installExtension: () -> Void = {}
        var openApprovalPane: () -> Void = {}
        var checkAgain: () -> Void = {}
        var revealInFinder: () -> Void = {}
        var openPreview: () -> Void = {}
        var setUpOverUSB: (InkSource) -> Void = { _ in }
        var selectSource: (InkSource) -> Void = { _ in }
        var copyURL: () -> Void = {}
        var setLaunchAtLogin: (Bool) -> Void = { _ in }
        var finish: () -> Void = {}
    }

    @Published var inputs: OnboardingSteps.Inputs
    @Published var inkSource: InkSource = .web
    @Published var launchAtLogin = false
    var actions = Actions()

    init(inputs: OnboardingSteps.Inputs) {
        self.inputs = inputs
    }

    var rows: [OnboardingSteps.Row] { return OnboardingSteps.rows(inputs) }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to Daylight").font(.title)
            Text("Set up once; after this Daylight Camera is just there.").foregroundColor(.secondary)
            ForEach(model.rows, id: \.index) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(badge(row.status)).font(.system(.body, design: .monospaced))
                        Text("\(row.index). \(row.title)").font(.headline)
                    }
                    Text(row.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                    buttons(for: row)
                }
                .padding(.vertical, 4)
            }
            Divider()
            HStack {
                Toggle("Launch Daylight at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.actions.setLaunchAtLogin($0) }))
                Spacer()
                Button("Done") { model.actions.finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!OnboardingSteps.canFinish(model.rows))
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func badge(_ status: OnboardingSteps.Status) -> String {
        switch status {
        case .pending: return "[ ]"
        case .active: return "[>]"
        case .done: return "[x]"
        case .blocked: return "[!]"
        }
    }

    @ViewBuilder
    private func buttons(for row: OnboardingSteps.Row) -> some View {
        switch row.index {
        case 0:
            HStack {
                if row.failure == .notInApplications { Button("Reveal in Finder") { model.actions.revealInFinder() } }
                if row.failure == .unsignedBuild { Button("Open the preview window") { model.actions.openPreview() } }
            }
        case 1:
            if row.status == .active && model.inputs.camera == .notDetermined { Button("Allow camera access") { model.actions.requestCamera() } }
            if row.failure == .cameraAccessDenied { Button("Open System Settings") { model.actions.openApprovalPane() } }
        case 2:
            HStack {
                if model.inputs.extensionState == .notInstalled && model.inputs.signed && !OnboardingSteps.locationProblem(bundlePath: model.inputs.bundlePath) {
                    Button("Install") { model.actions.installExtension() }
                }
                if model.inputs.extensionState == .awaitingApproval {
                    Button("Open System Settings") { model.actions.openApprovalPane() }
                    Button("Check again") { model.actions.checkAgain() }
                }
            }
        case 3:
            VStack(alignment: .leading, spacing: 6) {
                Picker("Ink source", selection: Binding(get: { model.inkSource }, set: { model.actions.selectSource($0) })) {
                    Text("Web whiteboard").tag(InkSource.web)
                    Text("Daylight Ink app").tag(InkSource.native)
                    Text("Mirror the tablet").tag(InkSource.mirror)
                }
                .pickerStyle(.segmented)
                HStack {
                    if model.inputs.usbDevice != nil { Button("Set up over USB") { model.actions.setUpOverUSB(model.inkSource) } }
                    if model.inputs.webURL != nil { Button("Copy the address") { model.actions.copyURL() } }
                }
            }
        default:
            EmptyView()
        }
    }
}

/// The "Welcome to Daylight" window (SPEC 13.1), shown while `onboardingDone` is false or from "Setup again".
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let model: OnboardingModel
    private var window: NSWindow?
    private var pollTimer: Timer?
    var onClose: (() -> Void)?

    init(model: OnboardingModel) {
        self.model = model
        super.init()
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: OnboardingView(model: model))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Welcome to Daylight"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Runs `poll` every `interval` seconds while the window is open (the inputs the rows follow); closing the window
    /// by Done or by its close button stops it.
    func startPolling(every interval: TimeInterval, _ poll: @escaping () -> Void) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in poll() }
    }

    var isPolling: Bool { return pollTimer?.isValid ?? false }

    /// `close` (not `orderOut`) so `windowWillClose` runs and the poll stops after Done too.
    func close() {
        stopPolling()
        window?.close()
    }

    var isVisible: Bool { return window?.isVisible ?? false }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
        onClose?()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
