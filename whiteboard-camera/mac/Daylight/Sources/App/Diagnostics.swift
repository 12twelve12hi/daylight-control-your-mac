import AppKit
import DaylightKit
import Foundation

/// SPEC 13.2: one text block with every runtime fact, a window showing it, and "Copy diagnostics".
enum DiagnosticsReport {
    struct Facts {
        var version = ""
        var build = ""
        var signed = false
        var bundlePath = ""
        var extensionState = ""
        var sinkStatus = ""
        var pipeline = PipelineStats()
        var governor = GovernorOutput()
        var inkSource: InkSource = .web
        var serverState = ""
        var port: UInt16 = 0
        var bonjourName: String?
        var addresses: [LocalAddresses.Entry] = []
        var clients: [String] = []
        var allowedClients: [ClientRegistry.Record] = []
        var mirror: [String: String] = [:]
        var failures: [String] = []
        var logLines: [String] = []
    }

    static func text(_ f: Facts) -> String {
        var lines: [String] = []
        lines.append("Daylight \(f.version) (\(f.build)) signed=\(f.signed)")
        lines.append("bundle: \(f.bundlePath)")
        lines.append("extension: \(f.extensionState)")
        lines.append("sink: \(f.sinkStatus)")
        let p = f.pipeline
        lines.append("capture: \(p.capturing ? "running" : "stopped") viewers=\(p.viewers) preview-or-sink rule: \(p.captureIdleReason ?? "active")")
        if let first = p.firstFrame { lines.append("first frame: \(first) zeroCopy=\(p.passthroughZeroCopy)") }
        if !p.passthroughZeroCopy, let first = p.firstFrame {
            // firstFrame reads "<w>x<h> <fourcc> iosurface=<bool>" (FramePipeline); row 5 wants the first three facts.
            let parts = first.split(separator: " ")
            let dims = parts.first.map { $0.split(separator: "x") } ?? []
            if dims.count == 2, parts.count >= 2 {
                lines.append(FailureText.sentence(.webcamFormatComposed, [String(dims[0]), String(dims[1]), String(parts[1])]))
            }
        }
        if p.captureIdleReason != nil { lines.append(FailureText.sentence(.captureIdle)) }
        lines.append("pipeline: mode=\(p.mode) fps=\(String(format: "%.1f", p.fps)) cpu_ms=\(String(format: "%.3f", p.cpuMsPerFrame)) gpu_ms=\(String(format: "%.3f", p.gpuMsPerFrame)) dropped=\(p.dropped) inFlight=\(p.inFlight) pushed=\(p.pushed)")
        lines.append("governor: \(f.governor.state) progress=\(String(format: "%.3f", f.governor.progress)) pinned=\(f.governor.pinned) hold=\(f.governor.hold) layout=\(f.governor.layout) msToReturn=\(f.governor.msToReturn)")
        lines.append("ink source: \(f.inkSource.jsonName)")
        lines.append("listener: \(f.serverState) port=\(f.port) bonjour=\(f.bonjourName ?? "off")")
        lines.append("addresses: " + (f.addresses.isEmpty ? "none" : f.addresses.map { "\($0.ip) (\($0.interface), \($0.kind == .tailscale ? "Tailscale" : "LAN"))" }.joined(separator: ", ")))
        lines.append("clients: " + (f.clients.isEmpty ? "none" : f.clients.joined(separator: "; ")))
        lines.append("allowed tablets: " + (f.allowedClients.isEmpty ? "none" : f.allowedClients.map { "\($0.label) [\($0.id.prefix(8))] usb=\($0.seenOverUSB)" }.joined(separator: "; ")))
        for key in f.mirror.keys.sorted() { lines.append("mirror.\(key): \(f.mirror[key] ?? "")") }
        if !f.failures.isEmpty {
            lines.append("failures:")
            lines.append(contentsOf: f.failures.map { "  " + $0 })
        }
        lines.append("log (last \(min(f.logLines.count, 200)) lines):")
        lines.append(contentsOf: f.logLines.suffix(200).map { "  " + $0 })
        return lines.joined(separator: "\n")
    }
}

/// The Diagnostics window: a text view refreshed on open and every 2 s, plus "Copy diagnostics".
final class DiagnosticsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let textView = NSTextView()
    private var timer: Timer?
    let provider: () -> String

    init(provider: @escaping () -> String) {
        self.provider = provider
        super.init()
    }

    func show() {
        if window == nil { makeWindow() }
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        textView.string = provider()
    }

    private func makeWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Daylight Diagnostics"
        w.isReleasedWhenClosed = false
        w.delegate = self
        let content = NSView(frame: w.contentLayoutRect)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        let copy = NSButton(title: "Copy diagnostics", target: self, action: #selector(copyDiagnostics(_:)))
        copy.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        content.addSubview(copy)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: copy.topAnchor, constant: -12),
            copy.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            copy.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        w.contentView = content
        w.center()
        window = w
    }

    @objc private func copyDiagnostics(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(provider(), forType: .string)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}
