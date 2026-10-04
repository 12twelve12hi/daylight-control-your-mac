import AppKit
import CoreGraphics
import DaylightKit
import Foundation
import QuartzCore

/// The "Daylight Whiteboard" share window (docs/product/TOO-SMALL.md section 8): the page alone, at the canvas aspect,
/// for sharing as a window in Zoom, Meet, Teams, Slack or Webex. A shared window fills the viewers' main stage, which a
/// camera tile never does. It reads the canvas directly (the two ink layers, or the mirror picture), so it shows the
/// page at the canvas's full 1200 x 1600 whether or not the camera pipeline is composing, and it keeps updating while it
/// is covered by other windows (ScreenCaptureKit captures a covered window; a minimised one pauses, WWDC22 10155).
final class ShareWindowController: NSObject, NSWindowDelegate {
    static let title = "Daylight Whiteboard"
    /// SH1: the window redraws at most 30 times a second, and only when the canvas changed.
    static let refreshHz: Double = 30
    /// SH2: the first size is 85 % of the screen's visible height (or width, whichever binds) at the canvas aspect.
    static let screenFraction: Double = 0.85
    static let windowID = "daylight.window.share"

    /// What to draw; read on main at every tick (the ink source can change while the window is open).
    var source: () -> ShareCanvasSource = { .none }
    var onVisibility: ((Bool) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var window: NSWindow?
    private let canvasView = ShareCanvasView()
    private var timer: DispatchSourceTimer?
    private let renderQueue = DispatchQueue(label: "com.twelve.daylight.share", qos: .userInitiated)
    private var rendering = false
    private var lastKey: RenderKey?
    private var aspect: Double = StudioLayout.portraitAspect
    private var settings = ShareSettings.defaults
    private(set) var framesDrawn = 0

    var isVisible: Bool { return window?.isVisible ?? false }

    enum RenderKey: Equatable {
        case layers(UInt32)
        case mirror(UInt64)
        case none
    }

    // MARK: Geometry (pure)

    /// The content size for a canvas aspect (width / height) on a screen's visible frame (SH2).
    static func contentSize(aspect: Double, visible: CGSize) -> CGSize {
        guard aspect > 0, visible.width > 0, visible.height > 0 else { return CGSize(width: 600, height: 800) }
        var h = Double(visible.height) * screenFraction
        var w = h * aspect
        let maxW = Double(visible.width) * screenFraction
        if w > maxW {
            w = maxW
            h = w / aspect
        }
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    static func styleMask(hideTitleBar: Bool) -> NSWindow.StyleMask {
        return hideTitleBar ? [.borderless, .resizable, .miniaturizable] : [.titled, .closable, .miniaturizable, .resizable]
    }

    // MARK: Show and hide

    /// `activate` false orders the window in without taking focus from the call (the "open with the board" path).
    func show(activate: Bool) {
        if window == nil { makeWindow() }
        guard let window = window else { return }
        if activate {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            window.orderFront(nil)
        }
        startTimer()
        onVisibility?(true)
        onLog?("share window shown (\(Int(window.frame.width))x\(Int(window.frame.height)) pt, floats=\(settings.floats), titleBar=\(!settings.hideTitleBar))")
    }

    func hide() {
        window?.orderOut(nil)
        stopTimer()
        onVisibility?(false)
    }

    func toggle() {
        if isVisible { hide() } else { show(activate: true) }
    }

    func apply(_ s: ShareSettings) {
        settings = s
        guard let window = window else { return }
        window.level = s.floats ? .floating : .normal
        let mask = ShareWindowController.styleMask(hideTitleBar: s.hideTitleBar)
        if window.styleMask != mask {
            let content = window.contentRect(forFrameRect: window.frame)
            window.styleMask = mask
            window.setFrame(window.frameRect(forContentRect: content), display: true)
        }
        window.isMovableByWindowBackground = s.hideTitleBar
        window.contentAspectRatio = NSSize(width: aspect, height: 1)
    }

    private func makeWindow() {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let size = ShareWindowController.contentSize(aspect: aspect, visible: visible)
        let w = ShareWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: ShareWindowController.styleMask(hideTitleBar: settings.hideTitleBar), backing: .buffered, defer: false)
        w.title = ShareWindowController.title
        w.setAccessibilityIdentifier(ShareWindowController.windowID)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentAspectRatio = NSSize(width: aspect, height: 1)
        // Shared by the call app: never exclude it from capture.
        w.sharingType = .readOnly
        w.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
        w.contentView = canvasView
        w.center()
        window = w
        apply(settings)
        lastKey = nil
    }

    func windowWillClose(_ notification: Notification) {
        stopTimer()
        onVisibility?(false)
    }

    // MARK: Refresh

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / ShareWindowController.refreshHz, leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    static func key(for source: ShareCanvasSource) -> RenderKey {
        switch source {
        case let .layers(surfaces): return .layers(surfaces.seed)
        case let .mirror(mirror): return .mirror(mirror.frameSeed)
        case .none: return .none
        }
    }

    /// Main queue: renders off main when the canvas changed and no render is in flight (SH1).
    func tick() {
        guard !rendering else { return }
        let current = source()
        let key = ShareWindowController.key(for: current)
        guard key != lastKey else { return }
        rendering = true
        renderQueue.async { [weak self] in
            let result = ShareWindowController.render(current)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.rendering = false
                self.lastKey = key
                guard let rendered = result else {
                    self.canvasView.show(nil)
                    return
                }
                let aspect = rendered.1
                self.canvasView.show(rendered.0)
                self.framesDrawn += 1
                if abs(aspect - self.aspect) > 0.001 {
                    self.aspect = aspect
                    self.window?.contentAspectRatio = NSSize(width: aspect, height: 1)
                    self.refit()
                }
            }
        }
    }

    /// The picture and its aspect (width / height) for a source; nil when there is nothing to show.
    static func render(_ source: ShareCanvasSource) -> (CGImage, Double)? {
        switch source {
        case let .layers(surfaces):
            guard let image = ShareCanvasRenderer.compose(ink: surfaces.ink, highlight: surfaces.highlight) else { return nil }
            return (image, Double(surfaces.width) / Double(surfaces.height))
        case let .mirror(mirror):
            guard let latest = mirror.latest(), let image = ShareCanvasRenderer.mirrorImage(latest.buffer, uv: latest.uv) else { return nil }
            return (image, latest.aspect)
        case .none:
            return nil
        }
    }

    /// Keeps the window's height and recomputes its width for a new aspect (a mirror session turned landscape).
    private func refit() {
        guard let window = window else { return }
        var content = window.contentRect(forFrameRect: window.frame)
        let visible = window.screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let size = ShareWindowController.contentSize(aspect: aspect, visible: visible)
        content.size = size
        window.setFrame(window.frameRect(forContentRect: content), display: true)
    }
}

/// A borderless window can still become key (to move it, to close it with Command-W from the menu).
private final class ShareWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

/// The page on the paper colour, aspect-fit, with the cream of the camera's margins behind it.
final class ShareCanvasView: NSView {
    private let pageLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        let cream = Tokens.surfaceCream
        layer?.backgroundColor = CGColor(srgbRed: CGFloat(cream.r), green: CGFloat(cream.g), blue: CGFloat(cream.b), alpha: 1)
        let paper = Tokens.paperBg
        pageLayer.backgroundColor = CGColor(srgbRed: CGFloat(paper.r), green: CGFloat(paper.g), blue: CGFloat(paper.b), alpha: 1)
        pageLayer.contentsGravity = .resizeAspect
        pageLayer.magnificationFilter = .linear
        pageLayer.minificationFilter = .trilinear
        pageLayer.frame = bounds
        pageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(pageLayer)
    }

    override var mouseDownCanMoveWindow: Bool { return true }

    func show(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.contents = image
        CATransaction.commit()
    }

    var currentImage: CGImage? {
        guard let contents = pageLayer.contents else { return nil }
        let object = contents as CFTypeRef
        guard CFGetTypeID(object) == CGImage.typeID else { return nil }
        return (object as! CGImage)
    }
}
