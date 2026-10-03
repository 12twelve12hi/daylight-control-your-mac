import AppKit
import AVFoundation
import CoreVideo
import DaylightKit
import SwiftUI

struct CameraOption: Identifiable, Equatable {
    let id: String
    let name: String
}

/// What the Settings window needs from the rest of the app, as closures (Settings/ never references App/).
final class SettingsContext: ObservableObject {
    @Published var allowedClients: [ClientRegistry.Record] = []
    /// Per action, the reason its chord did not register ("Already used by another app", "Already used by Clear").
    @Published var hotkeyConflicts: [HotkeyAction: String] = [:]
    @Published var diagnosticsText = ""
    @Published var mirrorAvailable = false
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

    var body: some View {
        TabView {
            generalTab.tabItem { Text("General") }
            hotkeysTab.tabItem { Text("Hotkeys") }
            networkTab.tabItem { Text("Network") }
            mirrorTab.tabItem { Text("Mirror") }
            savingTab.tabItem { Text("Saving") }
            advancedTab.tabItem { Text("Advanced") }
            diagnosticsTab.tabItem { Text("Diagnostics") }
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
            }
            Toggle("Engage on pen contact", isOn: $store.settings.autoEngage)
            Stepper("Return to camera after \(store.settings.idleTimeoutSeconds) s", value: $store.settings.idleTimeoutSeconds, in: Settings.idleTimeoutRange, step: 5)
            Stepper("Amber warning \(store.settings.preWarningSeconds) s before", value: $store.settings.preWarningSeconds, in: Settings.preWarningRange)
            Toggle("Open the preview window at launch", isOn: $store.settings.previewOnLaunch)
            Toggle("Preview window floats above other windows", isOn: $store.settings.previewFloats)
            Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { enabled in _ = try? store.setLaunchAtLogin(enabled) }))
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
            ForEach(HotkeyAction.allCases, id: \.self) { action in
                HStack {
                    Text(title(action)).frame(width: 160, alignment: .leading)
                    HotkeyRecorder(binding: Binding(
                        get: { store.settings.hotkeys[action] ?? Settings.defaultHotkeys[action]! },
                        set: { store.settings.hotkeys[action] = $0 }), conflict: context.hotkeyConflicts[action])
                }
            }
            Button("Reset to defaults") { store.settings.hotkeys = Settings.defaultHotkeys }
            Text("Pressing the active layout hotkey again returns to the camera (unpinning first).").font(.footnote).foregroundColor(.secondary)
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
                }
            }
        }
        .padding()
    }

    // MARK: Mirror

    private var mirrorTab: some View {
        Form {
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
                if !context.mirrorAvailable {
                    Text("Mirror mode becomes active when a Daylight with USB debugging is plugged in.").font(.footnote).foregroundColor(.secondary)
                }
            }
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
            Toggle("Perf log (one line per second in the unified log)", isOn: $store.settings.perfLog)
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
