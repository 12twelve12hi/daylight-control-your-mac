import CoreVideo
import DaylightKit
import Foundation

/// The decoded mirror picture for the compositor (`MirrorFrameSource`, ARCHITECTURE 6 item 6): a one-deep slot of the
/// latest BGRA frame, the session size from the scrcpy session packet, and the crop insets of SPEC D40 turned into UV
/// fractions of the CURRENT session size at render time. Thread-safe: the decoder publishes on mirror.queue, the
/// compositor reads on render.queue, Settings writes on main.
final class MirrorSource: MirrorFrameSource {
    private struct State {
        var buffer: CVPixelBuffer?
        var ptsUs: UInt64 = 0
        var seed: UInt64 = 0
        var sessionWidth = CropInsets.nativePortrait.width
        var sessionHeight = CropInsets.nativePortrait.height
        var portrait: CropInsets
        var landscape: CropInsets
        var pillsEnabled: Bool
        var frames: UInt64 = 0
    }

    private let state: Locked<State>
    var onGovernorEvent: ((GovernorEvent) -> Void)?
    /// The controller hooks these so `start()` and `stop()` through the `MirrorFrameSource` contract reach it.
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    init(settings: Settings) {
        state = Locked(State(portrait: settings.mirrorCropInsetsPortrait, landscape: settings.mirrorCropInsetsLandscape, pillsEnabled: settings.mirrorPinClearMode.includesPills))
    }

    func updateSettings(_ settings: Settings) {
        state.withLock { s in
            s.portrait = settings.mirrorCropInsetsPortrait
            s.landscape = settings.mirrorCropInsetsLandscape
            s.pillsEnabled = settings.mirrorPinClearMode.includesPills
        }
    }

    /// The scrcpy session packet: the encoder's output size (re-sent on rotation and encoder fallback).
    func setSessionSize(width: Int, height: Int) {
        state.withLock { s in
            s.sessionWidth = max(1, width)
            s.sessionHeight = max(1, height)
        }
    }

    var sessionSize: (w: Int, h: Int) {
        return state.withLock { ($0.sessionWidth, $0.sessionHeight) }
    }

    var insets: (portrait: CropInsets, landscape: CropInsets) {
        return state.withLock { ($0.portrait, $0.landscape) }
    }

    var frameCount: UInt64 { return state.withLock { $0.frames } }

    /// Newest wins (ARCHITECTURE 3.4): the previous buffer is released when replaced.
    func publish(_ buffer: CVPixelBuffer, ptsUs: UInt64) {
        state.withLock { s in
            s.buffer = buffer
            s.ptsUs = ptsUs
            s.seed &+= 1
            s.frames &+= 1
        }
    }

    /// Drops the picture (source switch or device gone); the seed still moves so the compositor notices.
    func clear() {
        state.withLock { s in
            s.buffer = nil
            s.seed &+= 1
        }
    }

    // MARK: MirrorFrameSource

    var frameSeed: UInt64 { return state.withLock { $0.seed } }

    func latest() -> (buffer: CVPixelBuffer, uv: UVRect, aspect: Double, orientation: StudioLayout.CanvasOrientation)? {
        return state.withLock { s -> (buffer: CVPixelBuffer, uv: UVRect, aspect: Double, orientation: StudioLayout.CanvasOrientation)? in
            guard let buffer = s.buffer else { return nil }
            let geometry = MirrorSource.geometry(sessionWidth: s.sessionWidth, sessionHeight: s.sessionHeight, portrait: s.portrait, landscape: s.landscape, pillsEnabled: s.pillsEnabled)
            return (buffer, geometry.uv, geometry.aspect, geometry.orientation)
        }
    }

    /// The last frame and its crop for `SessionSaver.saveMirror` (SPEC 12).
    func latestForSave() -> (buffer: CVPixelBuffer, uv: UVRect)? {
        guard let latest = latest() else { return nil }
        return (latest.buffer, latest.uv)
    }

    func start() { onStart?() }
    func stop() { onStop?() }

    /// The pure crop rule (tested by `CropInsetsRuntimeTests`): orientation from the session size, the matching insets
    /// (top 0 without pills), fractions of the session size, the cropped aspect.
    static func geometry(sessionWidth: Int, sessionHeight: Int, portrait: CropInsets, landscape: CropInsets, pillsEnabled: Bool) -> (uv: UVRect, aspect: Double, orientation: StudioLayout.CanvasOrientation) {
        let orientation = StudioLayout.CanvasOrientation(width: sessionWidth, height: sessionHeight)
        let native = CropInsets.nativeSize(for: orientation)
        let insets = (orientation == .portrait ? portrait : landscape).effective(pillsEnabled: pillsEnabled)
        let uv = insets.uv(sessionWidth: sessionWidth, sessionHeight: sessionHeight, nativeWidth: native.width, nativeHeight: native.height)
        let aspect = insets.croppedAspect(nativeWidth: native.width, nativeHeight: native.height)
        return (uv, aspect, orientation)
    }
}
