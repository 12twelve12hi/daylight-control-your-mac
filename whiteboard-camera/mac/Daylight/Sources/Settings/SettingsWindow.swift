import AppKit
import AVFoundation
import CoreVideo
import DaylightKit
import SwiftUI

struct CameraOption: Identifiable, Equatable {
    let id: String
    let name: String
}

/// The Settings tabs, by their titles. `named` reads a title in any letter case (`--ui-test-settings-tab`).
enum SettingsTab: String, CaseIterable, Equatable, Hashable {
    case general = "General"
    case hotkeys = "Hotkeys"
    case network = "Network"
    case mirror = "Mirror"
    case overlay = "Overlay"
    case share = "Share"
    case saving = "Saving"
    case advanced = "Advanced"
    case diagnostics = "Diagnostics"

    static func named(_ name: String) -> SettingsTab? {
        let wanted = name.lowercased()
        return SettingsTab.allCases.first { $0.rawValue.lowercased() == wanted }
    }

    /// The Mirror tab's crop view, so the UI suite's overlap check sees its frame.
    static let mirrorCropViewID = "daylight.settings.mirror.cropview"

    /// The accessibility identifier on the last element of the tab, `daylight.settings.<tab>.last`.
    var lastElementID: String {
        return "daylight.settings.\(rawValue.lowercased()).last"
    }
}

/// What the Settings window needs from the rest of the app, as closures (Settings/ never references App/).
final class SettingsContext: ObservableObject {
    @Published var allowedClients: [ClientRegistry.Record] = []
    /// Per action, the reason its chord did not register ("Already used by another app", "Already used by Clear").
    @Published var hotkeyConflicts: [HotkeyAction: String] = [:]
    @Published var diagnosticsText = ""
    @Published var mirrorAvailable = false
    @Published var selectedTab: SettingsTab = .general
    var cameras: () -> [CameraOption] = { [] }
    var forget: (String) -> Void = { _ in }
    var latestMirrorFrame: () -> CVPixelBuffer? = { nil }
    var tryWiFiMirror: () -> Void = {}
    var refreshDiagnostics: () -> Void = {}
    var chooseSaveDirectory: () -> Void = {}
    /// Settings > Share (Share/ShareSettingsView.swift): the share window's own store and its Show button.
    var shareStore = ShareSettingsStore()
    var showShareWindow: () -> Void = {}
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var context: SettingsContext
    @StateObject private var adbSourceModel = AdbSourceModel()

    var body: some View {
        TabView(selection: $context.selectedTab) {
            page(generalTab).tabItem { Text("General") }.tag(SettingsTab.general)
            page(hotkeysTab).tabItem { Text("Hotkeys") }.tag(SettingsTab.hotkeys)
            page(networkTab).tabItem { Text("Network") }.tag(SettingsTab.network)
            page(mirrorTab).tabItem { Text("Mirror") }.tag(SettingsTab.mirror)
            page(overlayTab).tabItem { Text("Overlay") }.tag(SettingsTab.overlay)
            page(ShareSettingsView(store: context.shareStore, showWindow: context.showShareWindow)).tabItem { Text("Share") }.tag(SettingsTab.share)
            page(savingTab).tabItem { Text("Saving") }.tag(SettingsTab.saving)
            page(advancedTab).tabItem { Text("Advanced") }.tag(SettingsTab.advanced)
            page(diagnosticsTab).tabItem { Text("Diagnostics") }.tag(SettingsTab.diagnostics)
        }
        // 720 pt: the row of nine tabs is about 620 pt wide; at 560 pt the last tab (Diagnostics) was not shown and
        // could not be clicked (UI test run 37180339019). The UI suite fails any tab that is not one click away.
        .frame(width: SettingsView.contentWidth, height: 520)
        .padding()
    }

    static let contentWidth: CGFloat = 720

    /// Settings > Advanced, "Follow the pen on camera" (TOO-SMALL section 7, off by default).
    static let followPenID = "daylight.settings.advanced.followpen"
    static let followPenExplanation = "On camera, the board zooms in on the area you are writing in, up to 2.5 times, and returns to the full page after 30 s without ink, on Clear and on a new page."

    /// Every tab's content starts at the top left of the tab area: a Form or a short VStack is otherwise centred
    /// vertically, leaving an empty band under the tab bar (Saving and Share in run 37182692894). The UI suite asserts
    /// the first element of each tab sits within 40 pt of the tab bar.
    private func page<Content: View>(_ content: Content) -> some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Picker("Camera", selection: Binding(get: { store.settings.cameraUniqueID ?? "" }, set: { store.settings.cameraUniqueID = $0.isEmpty ? nil : $0 })) {
                Text("System default").tag("")
                ForEach(context.cameras()) { camera in Text(camera.name).tag(camera.id) }
            }
            Picker("Ink source", selection: $store.settings.inkSource) {
                Text("Web whiteboard").tag(InkSource.web)
                Text("Daylight Ink app").tag(InkSource.native)
                Text("Mirror the tablet").tag(InkSource.mirror)
            }
            Picker("Layout when engaging", selection: $store.settings.preferredLayout) {
                Text("Studio Split").tag(LayoutStyle.studioSplit)
                Text("Whiteboard Only").tag(LayoutStyle.whiteboardOnly)
                if store.settings.overlayEnabled { Text("Overlay").tag(LayoutStyle.overlay) }
            }
            Toggle("Engage on pen contact", isOn: $store.settings.autoEngage)
            Stepper("Return to camera after \(store.settings.idleTimeoutSeconds) s", value: $store.settings.idleTimeoutSeconds, in: Settings.idleTimeoutRange, step: 5)
            Stepper("Amber warning \(store.settings.preWarningSeconds) s before", value: $store.settings.preWarningSeconds, in: Settings.preWarningRange)
            Toggle("Open the preview window at launch", isOn: $store.settings.previewOnLaunch)
            Toggle("Preview window floats above other windows", isOn: $store.settings.previewFloats)
            Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { enabled in _ = try? store.setLaunchAtLogin(enabled) }))
                .accessibilityIdentifier(SettingsTab.general.lastElementID)
            if store.launchAtLoginRequiresApproval {
                Button("Approve in System Settings") { store.openLoginItemsSettings() }
            }
        }
        .padding()
    }

    // MARK: Hotkeys

    private var hotkeysTab: some View {
        Form {
            Text("Click a field, then press the new chord (at least one modifier).").foregroundColor(.secondary)
            ForEach(HotkeyAction.allCases.filter { $0 != .overlay || store.settings.overlayEnabled }, id: \.self) { action in
                HStack(alignment: .center) {
                    Text(title(action)).frame(width: 160, alignment: .leading)
                    HotkeyRecorder(binding: Binding(
                        get: { store.settings.hotkeys[action] ?? Settings.defaultHotkeys[action]! },
                        set: { store.settings.hotkeys[action] = $0 }), conflict: context.hotkeyConflicts[action],
                        identifier: "daylight.settings.hotkeys.recorder.\(action.rawValue)")
                        .frame(width: HotkeyRecorder.size.width, height: HotkeyRecorder.size.height)
                }
            }
            Button("Reset to defaults") { store.settings.hotkeys = Settings.defaultHotkeys }
            Text("Pressing the active layout hotkey again returns to the camera (unpinning first).").font(.footnote).foregroundColor(.secondary)
                .accessibilityIdentifier(SettingsTab.hotkeys.lastElementID)
        }
        .padding()
    }

    private func title(_ action: HotkeyAction) -> String {
        switch action {
        case .whiteboardOnly: return "Whiteboard Only"
        case .studioSplit: return "Studio Split"
        case .keep: return "Keep whiteboard (Pin)"
        case .clear: return "Clear"
        case .camera: return "Camera"
        case .overlay: return "Overlay"
        }
    }

    // MARK: Network

    private var networkTab: some View {
        Form {
            TextField("Port", text: Binding(get: { String(store.settings.port) }, set: { text in
                if let value = UInt16(text), Int(value) >= Settings.portRange.lowerBound { store.settings.port = value }
            }))
            Text("Daylight tries \(WebServer.portRange.lowerBound) to \(WebServer.portRange.upperBound) when the port is busy; a restart applies a new port.").font(.footnote).foregroundColor(.secondary)
            TextField("Bonjour name", text: Binding(get: { store.settings.bonjourName ?? "" }, set: { store.settings.bonjourName = $0.isEmpty ? nil : $0 }))
            Toggle("Trust tablets connected over USB without asking", isOn: $store.settings.trustLoopback)
            Section(header: Text("Allowed tablets")) {
                if context.allowedClients.isEmpty {
                    Text("No tablet has been allowed yet.").foregroundColor(.secondary)
                        .accessibilityIdentifier(SettingsTab.network.lastElementID)
                }
                ForEach(context.allowedClients, id: \.id) { record in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(record.label)
                            Text("\(record.lastAddress)\(record.seenOverUSB ? " · seen over USB" : "") · \(record.roles.sorted().joined(separator: ", "))").font(.footnote).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Forget") { context.forget(record.id) }
                    }
                    .accessibilityIdentifier(record.id == context.allowedClients.last?.id ? SettingsTab.network.lastElementID : "daylight.settings.network.tablet")
                }
            }
        }
        .padding()
    }

    // MARK: Mirror

    /// The Mirror tab is taller than the fixed 720 by 520 window since phase 2 (Transport, adb source and the Wi-Fi
    /// stream rows above the 260 pt crop view), so it scrolls; without the ScrollView the Form overflows and the
    /// window clips its first rows, among them "Transport".
    private var mirrorTab: some View {
        ScrollView {
            mirrorForm
        }
    }

    /// A VStack, not a Form: in the Form the 260 pt crop view was laid out at its 400 pt intrinsic height and drew over
    /// the "Quality" row above it and the footnote below it (run 37182692894). The UI suite's overlap check guards it.
    private var mirrorForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Transport", selection: $store.settings.mirrorTransport) {
                Text("USB (adb)").tag(MirrorTransport.usb)
                Text("Wi-Fi (Daylight Ink screen stream)").tag(MirrorTransport.wifiStream)
            }
            AdbSourceSection(store: store, model: adbSourceModel)
            if store.settings.mirrorTransport == .wifiStream {
                Stepper("Stream size \(store.settings.mirrorStreamMaxSize) px", value: $store.settings.mirrorStreamMaxSize, in: Settings.mirrorStreamMaxSizeRange, step: 160)
                Stepper(String(format: "Bit rate %.1f Mbit/s", Double(store.settings.mirrorStreamBitRate) / 1_000_000), value: $store.settings.mirrorStreamBitRate, in: Settings.mirrorStreamBitRateRange, step: 500_000)
                Stepper("Frame rate \(store.settings.mirrorStreamMaxFps) fps", value: $store.settings.mirrorStreamMaxFps, in: Settings.mirrorStreamMaxFpsRange)
                Stepper("Key frame every \(store.settings.mirrorStreamKeyIntervalMs) ms", value: $store.settings.mirrorStreamKeyIntervalMs, in: Settings.mirrorStreamKeyIntervalRange, step: 500)
                Stepper("Change threshold: \(FrameDiffEngage.Config(changedFraction: store.settings.mirrorDiffThreshold).changedCellThreshold) canvas cells", value: $store.settings.mirrorDiffThreshold, in: Settings.mirrorDiffThresholdRange, step: 0.0005)
            }
            Picker("Pin and Clear in mirror mode", selection: $store.settings.mirrorPinClearMode) {
                Text("Floating pills").tag(MirrorPinClearMode.pills)
                Text("Pen side button").tag(MirrorPinClearMode.penButton)
                Text("Both").tag(MirrorPinClearMode.both)
            }
            Stepper("Double press window \(store.settings.sideButtonDoublePressMs) ms", value: $store.settings.sideButtonDoublePressMs, in: 100...1000, step: 50)
            Stepper("Long press \(store.settings.sideButtonLongPressMs) ms", value: $store.settings.sideButtonLongPressMs, in: 300...2000, step: 50)
            Toggle("Swap: double press = Clear, long press = Pin", isOn: $store.settings.sideButtonSwap)
            Picker("Pills position", selection: $store.settings.mirrorPillsPosition) {
                Text("Top").tag(PillsPosition.top)
                Text("Bottom").tag(PillsPosition.bottom)
            }
            Toggle("Mirror over Wi-Fi after a USB session", isOn: $store.settings.mirrorOverWiFi)
            if store.settings.mirrorOverWiFi { Button("Try Wi-Fi mirror now") { context.tryWiFiMirror() } }
            Picker("Quality", selection: Binding(get: { store.settings.mirrorMaxSize == Settings.lowBandwidthMirror.maxSize ? 1 : 0 }, set: { preset in
                if preset == 1 {
                    store.settings.mirrorMaxSize = Settings.lowBandwidthMirror.maxSize
                    store.settings.mirrorBitRate = Settings.lowBandwidthMirror.bitRate
                    store.settings.mirrorMaxFps = Settings.lowBandwidthMirror.maxFps
                } else {
                    store.settings.mirrorMaxSize = Settings.defaults.mirrorMaxSize
                    store.settings.mirrorBitRate = Settings.defaults.mirrorBitRate
                    store.settings.mirrorMaxFps = Settings.defaults.mirrorMaxFps
                }
            })) {
                Text("Standard (1600 px, 8 Mbit/s, 30 fps)").tag(0)
                Text("Low bandwidth (1200 px, 4 Mbit/s, 24 fps)").tag(1)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Crop (portrait, tablet pixels; the top strip hides the pills)").font(.headline)
                MirrorCropView(insets: $store.settings.mirrorCropInsetsPortrait, nativeWidth: 1200, nativeHeight: 1600, latestFrame: context.latestMirrorFrame)
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
                    .clipped()
                HStack {
                    Stepper("Top \(store.settings.mirrorCropInsetsPortrait.top)", value: $store.settings.mirrorCropInsetsPortrait.top, in: 0...800)
                    Stepper("Bottom \(store.settings.mirrorCropInsetsPortrait.bottom)", value: $store.settings.mirrorCropInsetsPortrait.bottom, in: 0...800)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(context.mirrorAvailable ? SettingsTab.mirror.lastElementID : "daylight.settings.mirror.crop")
                if !context.mirrorAvailable {
                    if store.settings.mirrorTransport == .wifiStream {
                        Text(FailureText.sentence(.wifiStreamNoTablet)).font(.footnote).foregroundColor(.secondary)
                            .accessibilityIdentifier(SettingsTab.mirror.lastElementID)
                    } else {
                        Text("Mirror mode becomes active when a Daylight with USB debugging is plugged in.").font(.footnote).foregroundColor(.secondary)
                            .accessibilityIdentifier(SettingsTab.mirror.lastElementID)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    // MARK: Overlay

    /// Presenter Overlay (SPEC 6.7, SPEC 11 overlay keys). Scrolls inside the fixed 720 by 520 window like the Mirror tab.
    private var overlayTab: some View {
        ScrollView {
            overlayForm
        }
    }

    /// A VStack, not a Form: inside the ScrollView the two-column Form took its ideal width, wider than the window, so
    /// the popups and sliders ran past the right edge and the row labels past the left (UI test run 37181876257). The
    /// VStack is offered the scroll view's width; the UI suite's frame check guards it.
    private var overlayForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable overlay mode", isOn: $store.settings.overlayEnabled)
            Group {
                Picker("Segmentation quality", selection: $store.settings.overlayQuality) {
                    Text("Fast").tag(OverlayQuality.fast)
                    Text("Balanced").tag(OverlayQuality.balanced)
                    Text("Accurate").tag(OverlayQuality.accurate)
                }
                HStack {
                    Text(String(format: "Smoothing %.2f", store.settings.overlaySmoothing)).frame(width: 200, alignment: .leading)
                    Slider(value: $store.settings.overlaySmoothing, in: Settings.overlaySmoothingRange)
                }
                Stepper("Edge softness \(store.settings.overlayFeather)", value: $store.settings.overlayFeather, in: Settings.overlayFeatherRange)
                Toggle("Amber outline", isOn: $store.settings.overlayHalo)
                HStack {
                    Text("Size \(Int((store.settings.overlayScale * 100).rounded())) % of picture height").frame(width: 200, alignment: .leading)
                    Slider(value: $store.settings.overlayScale, in: Settings.overlayScaleRange)
                }
                Picker("Position", selection: $store.settings.overlayPosition) {
                    Text("Bottom right").tag(OverlayPosition.bottomRight)
                    Text("Bottom left").tag(OverlayPosition.bottomLeft)
                    Text("Top right").tag(OverlayPosition.topRight)
                    Text("Top left").tag(OverlayPosition.topLeft)
                }
                HStack {
                    Text("Opacity \(Int((store.settings.overlayOpacity * 100).rounded())) %").frame(width: 200, alignment: .leading)
                    Slider(value: $store.settings.overlayOpacity, in: Settings.overlayOpacityRange)
                }
            }
            .disabled(!store.settings.overlayEnabled)
            Text("Overlay shows the whiteboard full frame with you cut out of your background in a corner; if you cannot be found it shows Studio Split.").font(.footnote).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(SettingsTab.overlay.lastElementID)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    // MARK: Saving

    /// One left-aligned column: the two-column Form split it into misaligned columns (run 37182692894).
    private var savingTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Folder: \(store.settings.saveDirectory?.path ?? "~/Documents/Daylight Camera")")
                Spacer()
                Button("Choose...") { context.chooseSaveDirectory() }
            }
            Toggle("Save the strokes as JSON next to each PNG", isOn: $store.settings.saveStrokesJSON)
            Stepper("Autosave every \(store.settings.autosaveSeconds) s while drawing", value: $store.settings.autosaveSeconds, in: Settings.autosaveRange, step: 15)
            Text("Pages are saved when the board returns to the camera, on Clear, on New page, every autosave interval while dirty, on Hold: Camera and on quit.").font(.footnote).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(SettingsTab.saving.lastElementID)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    // MARK: Advanced

    /// A VStack, not a Form: in the two-column Form the long labels were laid out at their full width and the "Perf
    /// log" toggle ran past the window's right edge (UI test run 37180339019). Here each label is offered the window's
    /// width and wraps; the UI suite's frame check (every control inside the window) guards it.
    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $store.settings.followPen) { WrappingLabel("Follow the pen on camera") }
                .accessibilityIdentifier(SettingsView.followPenID)
            Text(SettingsView.followPenExplanation).font(.footnote).foregroundColor(.secondary)
            Toggle(isOn: $store.settings.engageOnEraser) { WrappingLabel("Eraser contact engages the whiteboard") }
            Stepper(value: $store.settings.springK, in: Settings.springKRange, step: 100) {
                WrappingLabel("Spring stiffness \(Int(store.settings.springK)) (1200 settles in a quarter second)")
            }
            Stepper(value: $store.settings.viewerIdleStopSeconds, in: Settings.viewerIdleStopRange, step: 10) {
                WrappingLabel("Stop the webcam \(store.settings.viewerIdleStopSeconds) s after the last viewer")
            }
            Toggle(isOn: $store.settings.frameReuse) { WrappingLabel("Frame reuse (measure first)") }
            Toggle(isOn: $store.settings.deadlineIdle) { WrappingLabel("Deadline idling (measure first)") }
            Toggle(isOn: $store.settings.perfLog) { WrappingLabel("Perf log (one line per second, kept for Diagnostics and the export)") }
                .accessibilityIdentifier(SettingsTab.advanced.lastElementID)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    // MARK: Diagnostics

    private var diagnosticsTab: some View {
        VStack(alignment: .leading) {
            ScrollView {
                Text(context.diagnosticsText).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            HStack {
                Button("Refresh") { context.refreshDiagnostics() }
                Button("Copy diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(context.diagnosticsText, forType: .string)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(SettingsTab.diagnostics.lastElementID)
        }
        .padding()
        .onAppear { context.refreshDiagnostics() }
    }
}

/// A control label that wraps within the width it is offered instead of running past the window's edge.
struct WrappingLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).fixedSize(horizontal: false, vertical: true)
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let store: SettingsStore
    let context: SettingsContext

    init(store: SettingsStore, context: SettingsContext) {
        self.store = store
        self.context = context
        super.init()
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(store: store, context: context))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Daylight Settings"
            w.setAccessibilityIdentifier("daylight.window.settings")
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            SettingsWindowController.placeCentered(w, content: hosting.view)
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Sizes the window to its SwiftUI content before centring it, then keeps it inside the screen's visible frame.
    /// `NSWindow(contentViewController:)` alone centred a window that was still zero wide: its left edge sat at the
    /// middle of the screen and on a 1024 pt wide screen the right part (the last tabs) was off screen (UI test runs
    /// 37180339019 and 37181876257, window x = 511 at both widths). The UI suite asserts every window lies on screen.
    static func placeCentered(_ window: NSWindow, content: NSView) {
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        if size.width > 0, size.height > 0 { window.setContentSize(size) }
        window.center()
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var origin = window.frame.origin
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - window.frame.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - window.frame.height))
        window.setFrameOrigin(origin)
    }
}
