import CoreVideo
import DaylightKit
import Foundation
@testable import Daylight

/// A mirror stand-in: one static BGRA buffer with a fixed crop (the default portrait 96 px top inset).
final class FakeMirrorSource: MirrorFrameSource {
    let buffer: CVPixelBuffer
    var uv: UVRect
    var aspect: Double
    var orientation: StudioLayout.CanvasOrientation
    private(set) var frameSeed: UInt64 = 1
    var onGovernorEvent: ((GovernorEvent) -> Void)?
    private(set) var started = false

    init(width: Int = 1200, height: Int = 1600) {
        buffer = SelfTest.gradientBuffer(width: width, height: height)!
        let insets = CropInsets(top: 96, left: 0, right: 0, bottom: 0)
        uv = insets.uv(sessionWidth: width, sessionHeight: height, nativeWidth: width, nativeHeight: height)
        aspect = insets.croppedAspect(nativeWidth: width, nativeHeight: height)
        orientation = StudioLayout.CanvasOrientation(width: width, height: height)
    }

    func latest() -> (buffer: CVPixelBuffer, uv: UVRect, aspect: Double, orientation: StudioLayout.CanvasOrientation)? {
        return (buffer, uv, aspect, orientation)
    }

    func bumpSeed() {
        frameSeed += 1
    }

    func start() { started = true }
    func stop() { started = false }
}
