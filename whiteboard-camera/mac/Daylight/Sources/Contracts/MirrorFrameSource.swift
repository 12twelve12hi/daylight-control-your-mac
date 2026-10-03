// MirrorFrameSource.swift
import CoreVideo
import DaylightKit

/// Implemented by MirrorSource (F); consumed by FramePipeline (B). FakeMirrorSource in DaylightTests (B).
protocol MirrorFrameSource: AnyObject {
    func latest() -> (buffer: CVPixelBuffer, uv: UVRect, aspect: Double, orientation: StudioLayout.CanvasOrientation)?
    var frameSeed: UInt64 { get }                       // increments on every new decoded frame
    var onGovernorEvent: ((GovernorEvent) -> Void)? { get set }   // penContact, eraserContact, pin, clear
    func start()
    func stop()
}
