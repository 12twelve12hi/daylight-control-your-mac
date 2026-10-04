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
    case saving = "Saving"
    case advanced = "Advanced"
    case diagnostics = "Diagnostics"

    static func named(_ name: String) -> SettingsTab? {
        let wanted = name.lowercased()
        return SettingsTab.allCases.first { $0.rawValue.lowercased() == wanted }
    }

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
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var context: SettingsContext
    @StateObject private var adbSourceModel = AdbSourceModel()

    var body: some View {
        TabView(selection: $context.selectedTab) {
            generalTab.tabItem { Text("General") }.tag(SettingsTab.general)
            hotkeysTab.tabItem { Text("Hotkeys") }.tag(SettingsTab.hotkeys)
            networkTab.tabItem { Text("Network") }.tag(SettingsTab.network)
            mirrorTab.tabItem { Text("Mirror") }.tag(SettingsTab.mirror)
            overlayTab.tabItem { Text("Overlay") }.tag(SettingsTab.overlay)
            savingTab.tabItem { Text("Saving") }.tag(SettingsTab.saving)
            advancedTab.tabItem { Text("Advanced") }.tag(SettingsTab.advanced)
            diagnosticsTab.tabItem { Text("Diagnostics") }.tag(SettingsTab.diagnostics)
        }
        .frame(width: 560, height: 520)
        .padding()
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
                HStack {
                    Text(title(action)).frame(width: 160, alignment: .leading)
                    HotkeyRecorder(binding: Binding(
                        get: { store.settings.hotkeys[action] ?? Settings.defaultHotkeys[action]! },
                        set: { store.settings.hotkeys[action] = $0 }), conflict: context.hotkeyConflicts[action])
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

    /// The Mirror tab is taller than the fixed 560 by 520 window since phase 2 (Transport, adb source and the Wi-Fi
    /// stream rows above the 260 pt crop view), so it scrolls; without the ScrollView the Form overflows and the
    /// window clips its first rows, among them "Transport".
    private var mirrorTab: some View {
        ScrollView {
            mirrorForm
        }
    }

    private var mirrorForm: some View {
        Form {
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
            Section(header: Text("Crop (portrait, tablet pixels; the top strip hides the pills)")) {
                MirrorCropView(insets: $store.settings.mirrorCropInsetsPortrait, nativeWidth: 1200, nativeHeight: 1600, latestFrame: context.latestMirrorFrame)
                    .frame(height: 260)
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
        .padding()
    }

    // MARK: Overlay

    /// Presenter Overlay (SPEC 6.7, SPEC 11 overlay keys). Scrolls inside the fixed 560 by 520 window like the Mirror tab.
    private var overlayTab: some View {
        ScrollView {
            overlayForm
        }
    }

    private var overlayForm: some View {
        Form {
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
                .accessibilityIdentifier(SettingsTab.overlay.lastElementID)
        }
        .padding()
    }

    // MARK: Saving

    private var savingTab: some View {
        Form {
            HStack {
                Text("Folder: \(store.settings.saveDirectory?.path ?? "~/Documents/Daylight Camera")")
                Spacer()
                Button("Choose...") { context.chooseSaveDirectory() }
            }
            Toggle("Save the strokes as JSON next to each PNG", isOn: $store.settings.saveStrokesJSON)
            Stepper("Autosave every \(store.settings.autosaveSeconds) s while drawing", value: $store.settings.autosaveSeconds, in: Settings.autosaveRange, step: 15)
            Text("Pages are saved when the board returns to the camera, on Clear, on New page, every autosave interval while dirty, on Hold: Camera and on quit.").font(.footnote).foregroundColor(.secondary)
                .accessibilityIdentifier(SettingsTab.saving.lastElementID)
        }
        .padding()
    }

    // MARK: Advanced

    private var advancedTab: some View {
        Form {
            Toggle("Eraser contact engages the whiteboard", isOn: $store.settings.engageOnEraser)
            Stepper("Spring stiffness \(Int(store.settings.springK)) (1200 settles in a quarter second)", value: $store.settings.springK, in: Settings.springKRange, step: 100)
            Stepper("Stop the webcam \(store.settings.viewerIdleStopSeconds) s after the last viewer", value: $store.settings.viewerIdleStopSeconds, in: Settings.viewerIdleStopRange, step: 10)
            Toggle("Frame reuse (measure first)", isOn: $store.settings.frameReuse)
            Toggle("Deadline idling (measure first)", isOn: $store.settings.deadlineIdle)
            Toggle("Perf log (one line per second, kept for Diagnostics and the export)", isOn: $store.settings.perfLog)
                .accessibilityIdentifier(SettingsTab.advanced.lastElementID)
        }
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
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
