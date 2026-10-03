import Foundation

/// Output geometry for the 1920x1080 frame (SPEC section 6). Everything here is exact arithmetic on the SPEC numbers.
public enum StudioLayout {
    public static let outputWidth: Double = 1920
    public static let outputHeight: Double = 1080
    /// Studio zone width for a portrait canvas (two thirds) and for a landscape canvas (SPEC 6.4).
    public static let portraitZoneWidth: Double = 1280
    public static let landscapeZoneWidth: Double = 1440
    public static let portraitAspect: Double = 3.0 / 4.0
    public static let landscapeAspect: Double = 4.0 / 3.0
    public static let dividerWidth: Double = 2
    public static let borderWidth: Double = 1

    public struct Frame: Equatable {
        /// The webcam quad; nil when nothing of it is visible (Whiteboard Only at progress 1).
        public var presenter: QuadSpec?
        /// The ink canvas quad (both canvas layers sample the same quad); nil in passthrough.
        public var canvas: QuadSpec?
        /// Scissor rectangle for the studio panel (cream clear, canvas, borders); nil in passthrough.
        public var canvasClip: PixelRect?
        /// 1 px BorderSubtle lines at the paper's left and right edges.
        public var borders: [PixelRect]
        /// The 2 px divider between the panel and the presenter column (Studio Split only).
        public var divider: PixelRect?
        public var dividerColor: RGBA
        public var dividerAlpha: Double
        /// The presenter person cutout (Overlay only, SPEC 6.7); nil in every other layout.
        public var overlay: OverlayLayout.Cutout?

        public init(presenter: QuadSpec?, canvas: QuadSpec?, canvasClip: PixelRect?, borders: [PixelRect], divider: PixelRect?, dividerColor: RGBA, dividerAlpha: Double, overlay: OverlayLayout.Cutout? = nil) {
            self.presenter = presenter
            self.canvas = canvas
            self.canvasClip = canvasClip
            self.borders = borders
            self.divider = divider
            self.dividerColor = dividerColor
            self.dividerAlpha = dividerAlpha
            self.overlay = overlay
        }
    }

    public enum CanvasOrientation {
        case portrait
        case landscape

        /// 3:4 or 4:3.
        public var aspect: Double {
            switch self {
            case .portrait: return StudioLayout.portraitAspect
            case .landscape: return StudioLayout.landscapeAspect
            }
        }

        /// The studio zone width in Studio Split (1280 or 1440).
        public var zoneWidth: Double {
            switch self {
            case .portrait: return StudioLayout.portraitZoneWidth
            case .landscape: return StudioLayout.landscapeZoneWidth
            }
        }

        /// Portrait when the picture is taller than wide (a 1600x1200 mirror session is landscape).
        public init(width: Int, height: Int) {
            self = width > height ? .landscape : .portrait
        }
    }

    public static func passthrough() -> Frame {
        let full = PixelRect(x: 0, y: 0, w: outputWidth, h: outputHeight)
        return Frame(presenter: QuadSpec(dest: full, uv: .full), canvas: nil, canvasClip: nil, borders: [], divider: nil, dividerColor: Tokens.inkBlack, dividerAlpha: 0)
    }

    /// The frame at slide progress `s` (0 camera, 1 board). `canvasAspect` is the picture placed inside the paper slot
    /// (3/4 for the ink canvas, the cropped aspect for a mirror session); `breath` is the pre-warning weight 0...1.
    /// At s = 0 the presenter equals `passthrough()` (frame 0 of the slide is pixel-identical to passthrough).
    public static func frame(progress s: Double, layout: LayoutStyle, orientation: CanvasOrientation, canvasAspect: Double, breath: Double = 0) -> Frame {
        let progress = min(max(s, 0), 1)
        let dividerColor = amberBreath(weight: breath)
        switch layout {
        case .studioSplit:
            let zoneWidth = orientation.zoneWidth
            let d = zoneWidth * progress
            let ox = d - zoneWidth
            let presenter = QuadSpec(
                dest: PixelRect(x: d, y: 0, w: outputWidth - d, h: outputHeight),
                uv: UVRect(u0: d / (2 * outputWidth), v0: 0, u1: 1 - d / (2 * outputWidth), v1: 1))
            let zone = PixelRect(x: ox, y: 0, w: zoneWidth, h: outputHeight)
            let slot = fit(aspect: orientation.aspect, into: zone)
            let canvas = QuadSpec(dest: fit(aspect: canvasAspect, into: slot), uv: .full)
            let borders = [
                PixelRect(x: slot.x, y: 0, w: borderWidth, h: outputHeight),
                PixelRect(x: slot.x + slot.w, y: 0, w: borderWidth, h: outputHeight),
            ]
            let divider = PixelRect(x: d - 1, y: 0, w: dividerWidth, h: outputHeight)
            return Frame(
                presenter: presenter,
                canvas: canvas,
                canvasClip: PixelRect(x: 0, y: 0, w: d, h: outputHeight),
                borders: borders,
                divider: divider,
                dividerColor: dividerColor,
                dividerAlpha: progress)
        case .whiteboardOnly:
            let ox = outputWidth * (progress - 1)
            let zone = PixelRect(x: ox, y: 0, w: outputWidth, h: outputHeight)
            let slot = fit(aspect: orientation.aspect, into: zone)
            let canvas = QuadSpec(dest: fit(aspect: canvasAspect, into: slot), uv: .full)
            let borders = [
                PixelRect(x: slot.x, y: 0, w: borderWidth, h: outputHeight),
                PixelRect(x: slot.x + slot.w, y: 0, w: borderWidth, h: outputHeight),
            ]
            let presenter: QuadSpec? = progress >= 1 ? nil : passthrough().presenter
            return Frame(
                presenter: presenter,
                canvas: canvas,
                canvasClip: PixelRect(x: 0, y: 0, w: outputWidth + ox, h: outputHeight),
                borders: borders,
                divider: nil,
                dividerColor: dividerColor,
                dividerAlpha: 0)
        case .overlay:
            // SPEC 6.7 with the default cutout; the pipeline calls OverlayLayout.frame with the Settings config.
            return OverlayLayout.frame(progress: progress, orientation: orientation, canvasAspect: canvasAspect, breath: breath, config: .default)
        }
    }

    /// Largest rectangle of the given aspect (w/h) centred inside `r`.
    public static func fit(aspect: Double, into r: PixelRect) -> PixelRect {
        if r.w / r.h > aspect {
            let w = r.h * aspect
            return PixelRect(x: r.x + (r.w - w) / 2, y: r.y, w: w, h: r.h)
        } else {
            let h = r.w / aspect
            return PixelRect(x: r.x, y: r.y + (r.h - h) / 2, w: r.w, h: h)
        }
    }

    /// Normalised device coordinates (-1...1, y up) of a pixel rectangle's edges.
    public static func clip(_ r: PixelRect) -> (l: Double, t: Double, r: Double, b: Double) {
        let l = r.x / outputWidth * 2 - 1
        let right = (r.x + r.w) / outputWidth * 2 - 1
        let t = 1 - r.y / outputHeight * 2
        let b = 1 - (r.y + r.h) / outputHeight * 2
        return (l, t, right, b)
    }

    /// Divider colour during the pre-warning: `mix(InkBlack, Amber, weight)` (SPEC 6.2).
    public static func amberBreath(weight: Double) -> RGBA {
        let w = min(max(weight, 0), 1)
        let a = Tokens.inkBlack
        let b = Tokens.amber
        return RGBA(r: a.r + (b.r - a.r) * w, g: a.g + (b.g - a.g) * w, b: a.b + (b.b - a.b) * w, a: 1)
    }
}
