import Foundation

/// Output geometry (SPEC section 6). Skeleton: passthrough and aspect fitting are real; the split layout lands in M2.
public enum StudioLayout {
    public static let outputWidth: Double = 1920
    public static let outputHeight: Double = 1080

    public struct Frame: Equatable {
        public var presenter: QuadSpec?
        public var canvas: QuadSpec?
        public var canvasClip: PixelRect?
        public var borders: [PixelRect]
        public var divider: PixelRect?
        public var dividerColor: RGBA
        public var dividerAlpha: Double

        public init(presenter: QuadSpec?, canvas: QuadSpec?, canvasClip: PixelRect?, borders: [PixelRect], divider: PixelRect?, dividerColor: RGBA, dividerAlpha: Double) {
            self.presenter = presenter
            self.canvas = canvas
            self.canvasClip = canvasClip
            self.borders = borders
            self.divider = divider
            self.dividerColor = dividerColor
            self.dividerAlpha = dividerAlpha
        }
    }

    public enum CanvasOrientation {
        case portrait
        case landscape
    }

    public static func passthrough() -> Frame {
        let full = PixelRect(x: 0, y: 0, w: outputWidth, h: outputHeight)
        return Frame(presenter: QuadSpec(dest: full, uv: .full), canvas: nil, canvasClip: nil, borders: [], divider: nil, dividerColor: Tokens.borderSubtle, dividerAlpha: 0)
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

    /// Divider colour during the pre-warning: BorderSubtle blended toward Amber by `weight` (0...1).
    public static func amberBreath(weight: Double) -> RGBA {
        let w = min(max(weight, 0), 1)
        let a = Tokens.borderSubtle
        let b = Tokens.amber
        return RGBA(r: a.r + (b.r - a.r) * w, g: a.g + (b.g - a.g) * w, b: a.b + (b.b - a.b) * w, a: 1)
    }
}
