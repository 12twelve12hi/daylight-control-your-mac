import Foundation

/// Follow the pen in the compositor's frame (TOO-SMALL section 7): `FollowCamera` works in the zone the canvas fills
/// at rest (progress 1); `apply` swaps a layout frame's canvas quad for the follow quad, moved by the slide offset of
/// the current progress, and keeps the paper's border lines on the quad's edges while they lie inside the zone (a
/// magnified page that covers the zone has no edge to mark). At the full page it returns the frame unchanged.
/// Studio Split and Whiteboard Only only; the Overlay layout and mirror pictures are never followed.
public enum FollowFrame {
    /// The zone at rest: the studio zone (left `zoneWidth` columns) in Studio Split, the whole output in Whiteboard
    /// Only; nil for the Overlay layout.
    public static func restZone(layout: LayoutStyle, orientation: StudioLayout.CanvasOrientation = .portrait) -> PixelRect? {
        switch layout {
        case .studioSplit:
            return PixelRect(x: 0, y: 0, w: orientation.zoneWidth, h: StudioLayout.outputHeight)
        case .whiteboardOnly:
            return PixelRect(x: 0, y: 0, w: StudioLayout.outputWidth, h: StudioLayout.outputHeight)
        case .overlay:
            return nil
        }
    }

    /// The horizontal slide offset of the zone at `progress` (0 at rest, negative while the panel slides in or out).
    public static func slideOffset(layout: LayoutStyle, orientation: StudioLayout.CanvasOrientation = .portrait, progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        switch layout {
        case .studioSplit: return orientation.zoneWidth * (p - 1)
        case .whiteboardOnly: return StudioLayout.outputWidth * (p - 1)
        case .overlay: return 0
        }
    }

    /// `frame` with its canvas quad replaced by `quad` (computed in the rest zone) shifted by the slide offset.
    public static func apply(_ quad: QuadSpec, to frame: StudioLayout.Frame, layout: LayoutStyle, orientation: StudioLayout.CanvasOrientation = .portrait, progress: Double) -> StudioLayout.Frame {
        guard frame.canvas != nil, let zone = restZone(layout: layout, orientation: orientation) else { return frame }
        let dx = slideOffset(layout: layout, orientation: orientation, progress: progress)
        let dest = PixelRect(x: quad.dest.x + dx, y: quad.dest.y, w: quad.dest.w, h: quad.dest.h)
        var out = frame
        out.canvas = QuadSpec(dest: dest, uv: quad.uv)
        var borders: [PixelRect] = []
        let eps = 0.5
        if quad.dest.x > zone.x + eps {
            borders.append(PixelRect(x: dest.x, y: 0, w: StudioLayout.borderWidth, h: StudioLayout.outputHeight))
        }
        if quad.dest.x + quad.dest.w < zone.x + zone.w - eps {
            borders.append(PixelRect(x: dest.x + dest.w, y: 0, w: StudioLayout.borderWidth, h: StudioLayout.outputHeight))
        }
        out.borders = borders
        return out
    }
}
