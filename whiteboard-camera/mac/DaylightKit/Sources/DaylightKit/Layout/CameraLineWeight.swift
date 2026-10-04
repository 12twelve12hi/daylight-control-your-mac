import Foundation

/// Camera line weight (docs/product/DRAWING-DEEP-DIVE.md D14): the live camera output draws every stroke at least
/// this wide, so handwriting survives the far side's downscale. The minimums are set in output pixels at 1080p and
/// scale with the output height; the ink canvas maps to the output at `outputHeight / canvasHeight` at rest (the
/// page fills the frame height in Studio Split and Whiteboard Only), so the clamp is one canvas-space width that holds
/// for every output height: 2.5 px at 1080p is 3.7 canvas px, and the same line is 1.7 px when a call app shows 720p.
/// The stroke JSON, the PNG export and the tablet keep the true width; eraser geometry is untouched.
public enum CameraLineWeight {
    /// The output height the minimums are stated at.
    public static let referenceOutputHeight: Double = 1080
    /// Pen (and every tool that draws on the ink layer) minimum, output pixels at 1080p.
    public static let penMinimumOutputPixels: Double = 2.5
    /// Highlighter minimum, output pixels at 1080p: its own, larger floor (its tablet width is 6.6 to 17.4 canvas px).
    public static let highlighterMinimumOutputPixels: Double = 6.0

    /// The minimum width in canvas pixels for `tool`; 0 for the eraser, which never draws.
    public static func minimumCanvasWidth(for tool: SolStream.Tool, canvasHeight: Double = Double(SolStream.canvasHeight)) -> Double {
        let outputPixels: Double
        switch tool {
        case .eraser: return 0
        case .highlighter: outputPixels = highlighterMinimumOutputPixels
        case .pen, .lasso: outputPixels = penMinimumOutputPixels
        }
        return outputPixels * canvasHeight / referenceOutputHeight
    }

    /// The width the camera draws for a stroke segment (or dot) the tablet drew `width` canvas pixels wide.
    public static func cameraWidth(_ width: Double, tool: SolStream.Tool, canvasHeight: Double = Double(SolStream.canvasHeight)) -> Double {
        return max(width, minimumCanvasWidth(for: tool, canvasHeight: canvasHeight))
    }

    /// Output pixels a canvas-space width covers at `outputHeight` (the page at rest fills the output height).
    public static func outputWidth(canvasWidth: Double, outputHeight: Double, canvasHeight: Double = Double(SolStream.canvasHeight)) -> Double {
        return canvasWidth * outputHeight / canvasHeight
    }

    /// How far a clamped line can reach past a stroke's `dirtyBounds` (which inflate by the true maximum width): the
    /// rasterizer grows every redraw rectangle by this, so an erase or undo never leaves a bolder edge behind.
    public static func redrawMargin(canvasHeight: Double = Double(SolStream.canvasHeight)) -> Double {
        return (minimumCanvasWidth(for: .highlighter, canvasHeight: canvasHeight) / 2 + 1).rounded(.up)
    }
}
