import Foundation

/// Mirror crop as pixel insets of the NATIVE tablet picture (portrait 1200x1600, landscape 1600x1200; SPEC D40).
/// At render time the insets become fractions of the current session size, so a 960x1280 encoder fallback or a
/// rotation crops the same screen region.
public struct CropInsets: Equatable, Codable {
    public static let nativePortrait = (width: 1200, height: 1600)
    public static let nativeLandscape = (width: 1600, height: 1200)
    /// A crop never leaves fewer than this many native pixels in either direction.
    public static let minimumRemaining = 100

    public var top: Int
    public var left: Int
    public var right: Int
    public var bottom: Int

    public init(top: Int = 0, left: Int = 0, right: Int = 0, bottom: Int = 0) {
        self.top = top
        self.left = left
        self.right = right
        self.bottom = bottom
    }

    public static let zero = CropInsets()

    /// UV fractions of the current session frame that show the cropped native region.
    public func uv(sessionWidth: Int, sessionHeight: Int, nativeWidth: Int, nativeHeight: Int) -> UVRect {
        guard nativeWidth > 0, nativeHeight > 0 else { return .full }
        let c = clamped(nativeWidth: nativeWidth, nativeHeight: nativeHeight)
        return UVRect(
            u0: Double(c.left) / Double(nativeWidth),
            v0: Double(c.top) / Double(nativeHeight),
            u1: 1 - Double(c.right) / Double(nativeWidth),
            v1: 1 - Double(c.bottom) / Double(nativeHeight))
    }

    /// The crop rectangle in pixels of a session frame of the given size.
    public func pixelRect(sessionWidth: Int, sessionHeight: Int, nativeWidth: Int, nativeHeight: Int) -> PixelRect {
        let r = uv(sessionWidth: sessionWidth, sessionHeight: sessionHeight, nativeWidth: nativeWidth, nativeHeight: nativeHeight)
        let w = Double(sessionWidth), h = Double(sessionHeight)
        return PixelRect(x: r.u0 * w, y: r.v0 * h, w: (r.u1 - r.u0) * w, h: (r.v1 - r.v0) * h)
    }

    /// Width over height of the cropped native picture (feeds `StudioLayout.fit`).
    public func croppedAspect(nativeWidth: Int, nativeHeight: Int) -> Double {
        let c = clamped(nativeWidth: nativeWidth, nativeHeight: nativeHeight)
        let w = Double(nativeWidth - c.left - c.right)
        let h = Double(nativeHeight - c.top - c.bottom)
        return h > 0 && w > 0 ? w / h : StudioLayout.portraitAspect
    }

    /// Negative insets become 0; opposite insets shrink until `minimumRemaining` native pixels stay visible.
    public func clamped(nativeWidth: Int, nativeHeight: Int) -> CropInsets {
        var c = CropInsets(top: max(0, top), left: max(0, left), right: max(0, right), bottom: max(0, bottom))
        let minKeep = CropInsets.minimumRemaining
        if c.left + c.right > nativeWidth - minKeep {
            c.right = max(0, nativeWidth - minKeep - c.left)
            if c.left + c.right > nativeWidth - minKeep { c.left = max(0, nativeWidth - minKeep) }
        }
        if c.top + c.bottom > nativeHeight - minKeep {
            c.bottom = max(0, nativeHeight - minKeep - c.top)
            if c.top + c.bottom > nativeHeight - minKeep { c.top = max(0, nativeHeight - minKeep) }
        }
        return c
    }

    /// SPEC D40 and section 11: the top inset is 0 when the pills are disabled (nothing hides in the strip then).
    public func effective(pillsEnabled: Bool) -> CropInsets {
        if pillsEnabled { return self }
        var c = self
        c.top = 0
        return c
    }

    /// The native size for a session orientation (a 1600x1200 session is landscape).
    public static func nativeSize(for orientation: StudioLayout.CanvasOrientation) -> (width: Int, height: Int) {
        switch orientation {
        case .portrait: return nativePortrait
        case .landscape: return nativeLandscape
        }
    }
}
