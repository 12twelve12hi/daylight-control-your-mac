import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import DaylightKit
import Foundation

/// The day-one fallback (SPEC D19): a window showing exactly what the camera extension receives, through an
/// `AVSampleBufferDisplayLayer`. Frames are consumed only while the window is visible; visibility feeds the idle rule.
final class PreviewWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let feeder = FrameFeeder(sink: PreviewLayerSink())
    private let coalescer = LatestSampleCoalescer(queue: .main)
    private let label = NSTextField(labelWithString: "")
    var onVisibility: ((Bool) -> Void)?
    var floats = true
    private var visible = false

    var isVisible: Bool { return visible }

    func show() {
        if window == nil { makeWindow() }
        window?.level = floats ? .floating : .normal
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        setVisible(true)
    }

    func hide() {
        window?.orderOut(nil)
        setVisible(false)
    }

    /// Text drawn over the picture (the "No camera found" cream card, failure row 4); empty hides it.
    func setOverlayText(_ text: String) {
        label.stringValue = text
        label.isHidden = text.isEmpty
    }

    /// Called from the pipeline on any queue; drops when the window is hidden. Frames are coalesced: at most one
    /// main-queue hop is in flight and it enqueues only the newest sample, so a stalled main thread never piles up
    /// retained camera buffers and starves the capture pool (research-mac-pipeline 1.9).
    func display(_ pixelBuffer: CVPixelBuffer) {
        guard visible else { return }
        guard let sample = feeder.makeSampleBuffer(pixelBuffer, hostTimeNs: nil) else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        coalescer.offer(sample) { [weak self] latest in
            guard let self = self, self.visible else { return }
            if self.displayLayer.status == .failed { self.displayLayer.flush() }
            self.displayLayer.enqueue(latest)
        }
    }

    private func setVisible(_ v: Bool) {
        guard visible != v else { return }
        visible = v
        if !v { coalescer.clear() }
        onVisibility?(v)
    }

    private func makeWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        w.title = "Daylight Camera preview"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentAspectRatio = NSSize(width: 16, height: 9)
        let view = NSView(frame: w.contentLayoutRect)
        view.wantsLayer = true
        let cream = Tokens.surfaceCream
        view.layer?.backgroundColor = CGColor(srgbRed: CGFloat(cream.r), green: CGFloat(cream.g), blue: CGFloat(cream.b), alpha: 1)
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = view.bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(displayLayer)
        label.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        let ink = Tokens.inkBlack
        label.textColor = NSColor(srgbRed: CGFloat(ink.r), green: CGFloat(ink.g), blue: CGFloat(ink.b), alpha: 1)
        label.alignment = .center
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        w.contentView = view
        w.center()
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        setVisible(false)
    }
}

/// Hands the newest sample to `deliver` on `queue` with at most one dispatch in flight; older samples are released
/// when they are replaced, so the preview holds at most one capture buffer however long the target queue stalls.
final class LatestSampleCoalescer {
    private struct State {
        var sample: CMSampleBuffer?
        var scheduled = false
    }

    private let state = Locked(State())
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func offer(_ sample: CMSampleBuffer, deliver: @escaping (CMSampleBuffer) -> Void) {
        let dispatch = state.withLock { s -> Bool in
            s.sample = sample
            if s.scheduled { return false }
            s.scheduled = true
            return true
        }
        guard dispatch else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let latest = self.state.withLock { s -> CMSampleBuffer? in
                let taken = s.sample
                s.sample = nil
                s.scheduled = false
                return taken
            }
            if let latest = latest { deliver(latest) }
        }
    }

    /// Drops a held sample (the window went away).
    func clear() {
        state.withLock { $0.sample = nil }
    }
}

/// The preview's own "sink": `FrameFeeder` only needs something to hand sample buffers to; the layer enqueue happens
/// in `PreviewWindow.display`, so this sink just reports success.
private final class PreviewLayerSink: VirtualCameraSink {
    var status: SinkStatus = .installed
    var onStatusChange: ((SinkStatus) -> Void)?
    var onQueueAltered: (() -> Void)?
    var viewerCount: Int = 0
    var onViewerCount: ((Int) -> Void)?
    func start() {}
    func stop() {}
    func push(_ sampleBuffer: CMSampleBuffer) -> Bool { return true }
}
