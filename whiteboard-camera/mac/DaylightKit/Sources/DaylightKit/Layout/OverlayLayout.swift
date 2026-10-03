import Foundation

/// Settings > Overlay > Segmentation quality (SPEC 11 `overlayQuality`). Raw values are the SPEC 11 values; the Mac app
/// maps them to the Vision person segmentation quality levels. Fast is the default because it costs least per frame.
public enum OverlayQuality: String, Codable, CaseIterable {
    case fast
    case balanced
    case accurate
}

/// The corner the presenter cutout sits in (SPEC 11 `overlayPosition`, SPEC 6.7).
public enum OverlayPosition: String, Codable, CaseIterable {
    case bottomRight
    case bottomLeft
    case topRight
    case topLeft
}

/// Presenter Overlay geometry (SPEC 6.7, all in 1920x1080 output pixels): the Whiteboard Only panel with the presenter
/// drawn as a person cutout in one corner. The cutout morphs from the full camera picture at s = 0 to a square of side
/// `heightFraction * 1080` at s = 1 without distortion, so frame 0 of the slide is pixel-identical to passthrough.
public enum OverlayLayout {
    public static let defaultHeightFraction: Double = 0.28
    /// Inset of the cutout square from the chosen corner.
    public static let margin: Double = 32
    /// The central square of the 1920x1080 camera frame that the cutout shows at s = 1.
    public static let sourceSquare: Double = 1080
    /// Mask mean below this shows the camera rectangle instead of the matte (SPEC 13.3 row 49).
    public static let minimumCoverage: Double = 0.01
    /// Consecutive failed segmentations before Overlay falls back to Studio Split (SPEC 13.3 row 48).
    public static let failureLimit = 15
    /// The newest mask older than this shows the camera rectangle.
    public static let staleMaskSeconds: Double = 0.5

    public struct Config: Equatable {
        /// Side of the cutout square as a fraction of the output height.
        public var heightFraction: Double
        public var position: OverlayPosition
        /// Cutout opacity at s = 1.
        public var opacity: Double
        /// Amber outline around the person.
        public var halo: Bool

        public init(heightFraction: Double = OverlayLayout.defaultHeightFraction, position: OverlayPosition = .bottomRight, opacity: Double = 1, halo: Bool = false) {
            self.heightFraction = heightFraction
            self.position = position
            self.opacity = opacity
            self.halo = halo
        }

        /// The Overlay settings of SPEC section 11 (`overlayScale`, `overlayPosition`, `overlayOpacity`, `overlayHalo`),
        /// after `validated()`.
        public init(settings: Settings) {
            let s = settings.validated()
            self.init(heightFraction: s.overlayScale, position: s.overlayPosition, opacity: s.overlayOpacity, halo: s.overlayHalo)
        }

        public static let `default` = Config()
    }

    /// The presenter cutout quad: `dest` in output pixels, `uv` into the camera frame (the mask covers the whole camera
    /// frame and is sampled at the same uv). `maskStrength` 0 draws the plain rectangle, 1 the full matte.
    public struct Cutout: Equatable {
        public var dest: PixelRect
        public var uv: UVRect
        public var maskStrength: Double
        public var opacity: Double
        public var halo: Bool

        public init(dest: PixelRect, uv: UVRect, maskStrength: Double, opacity: Double, halo: Bool) {
            self.dest = dest
            self.uv = uv
            self.maskStrength = maskStrength
            self.opacity = opacity
            self.halo = halo
        }
    }

    /// The cutout square at s = 1: side `L = heightFraction * 1080`, inset `margin` from the chosen corner.
    public static func targetRect(config: Config) -> PixelRect {
        let side = config.heightFraction * StudioLayout.outputHeight
        let left = margin
        let right = StudioLayout.outputWidth - margin - side
        let top = margin
        let bottom = StudioLayout.outputHeight - margin - side
        switch config.position {
        case .bottomRight: return PixelRect(x: right, y: bottom, w: side, h: side)
        case .bottomLeft: return PixelRect(x: left, y: bottom, w: side, h: side)
        case .topRight: return PixelRect(x: right, y: top, w: side, h: side)
        case .topLeft: return PixelRect(x: left, y: top, w: side, h: side)
        }
    }

    /// The cutout at slide progress `s` (clamped to 0...1). Source crop width `cw = 1920 + (1080 - 1920) s` (centred, full
    /// height), uniform scale `k = 1 + (L / 1080 - 1) s`, dest `(tx s, ty s, cw k, 1080 k)`, uv `u0 = (1920 - cw) / 3840`.
    public static func cutout(progress: Double, config: Config) -> Cutout {
        let s = min(max(progress, 0), 1)
        let target = targetRect(config: config)
        let width = StudioLayout.outputWidth
        let height = StudioLayout.outputHeight
        let cw = width + (sourceSquare - width) * s
        let k = 1 + (target.w / height - 1) * s
        let u0 = (width - cw) / (2 * width)
        return Cutout(
            dest: PixelRect(x: target.x * s, y: target.y * s, w: cw * k, h: height * k),
            uv: UVRect(u0: u0, v0: 0, u1: 1 - u0, v1: 1),
            maskStrength: s,
            opacity: 1 + (config.opacity - 1) * s,
            halo: config.halo)
    }

    /// The Overlay frame: the Whiteboard Only panel (SPEC 6.3) sliding in from the left, no full-frame presenter quad,
    /// no divider, and the presenter cutout.
    public static func frame(progress: Double, orientation: StudioLayout.CanvasOrientation, canvasAspect: Double, breath: Double = 0, config: Config) -> StudioLayout.Frame {
        let panel = StudioLayout.frame(progress: progress, layout: .whiteboardOnly, orientation: orientation, canvasAspect: canvasAspect, breath: breath)
        return StudioLayout.Frame(
            presenter: nil,
            canvas: panel.canvas,
            canvasClip: panel.canvasClip,
            borders: panel.borders,
            divider: nil,
            dividerColor: panel.dividerColor,
            dividerAlpha: 0,
            overlay: cutout(progress: progress, config: config))
    }

    /// IIR temporal smoothing, the formula the Metal kernel uses: out = smoothing * previous + (1 - smoothing) * new.
    public static func smoothed(previous: Double, new: Double, smoothing: Double) -> Double {
        return smoothing * previous + (1 - smoothing) * new
    }

    /// Normalised Gaussian weights for the separable feather blur: 2 * radius + 1 taps, sigma = max(radius, 1) / 2,
    /// symmetric, sum 1; radius 0 (or below) -> [1].
    public static func featherWeights(radius: Int) -> [Float] {
        let r = max(radius, 0)
        if r == 0 { return [1] }
        let sigma = Double(max(r, 1)) / 2
        var weights: [Double] = []
        weights.reserveCapacity(2 * r + 1)
        for i in -r...r {
            let x = Double(i)
            weights.append(exp(-(x * x) / (2 * sigma * sigma)))
        }
        let sum = weights.reduce(0, +)
        return weights.map { Float($0 / sum) }
    }

    /// Halo colour: SolOS amber #D97706.
    public static var haloColor: RGBA { return Tokens.amber }
}

/// The Overlay fallback state machine (SPEC 6.7, SPEC 13.3 rows 48 and 49): a pure value with injected time.
/// `failureLimit` consecutive failed segmentations latch the fallback (the pipeline then renders Studio Split) until
/// `reset()`. A missing or stale mask, or coverage below `minimumCoverage`, shows the camera rectangle instead of the matte.
public struct OverlayHealth: Equatable {
    public enum Presentation: Equatable {
        case matte
        case rectangle
        case fellBack
    }

    public enum Effect: Equatable {
        /// Emitted once, on the failure that latches the fallback (row 48).
        case fellBack(reason: String)
        /// Emitted once per transition into low coverage (row 49).
        case lowCoverage(Double)
        /// Emitted once when coverage rises back to the minimum after `.lowCoverage`.
        case matteRestored
    }

    public private(set) var consecutiveFailures: Int = 0
    /// Latched until `reset()`.
    public private(set) var fallbackReason: String? = nil
    public private(set) var lastMaskAt: Double? = nil
    public private(set) var lastCoverage: Double? = nil
    /// `.lowCoverage` was emitted and `.matteRestored` has not followed yet.
    private var lowCoverageReported = false

    public init() {}

    /// A segmentation succeeded at `now` with the given mask mean. Resets the failure counter.
    public mutating func segmented(coverage: Double, now: Double) -> [Effect] {
        consecutiveFailures = 0
        lastMaskAt = now
        lastCoverage = coverage
        if fallbackReason != nil { return [] }
        let low = !(coverage >= OverlayLayout.minimumCoverage)
        if low && !lowCoverageReported {
            lowCoverageReported = true
            return [.lowCoverage(coverage)]
        }
        if !low && lowCoverageReported {
            lowCoverageReported = false
            return [.matteRestored]
        }
        return []
    }

    /// A segmentation failed. At `failureLimit` consecutive failures the fallback latches and `.fellBack` is emitted once.
    public mutating func failed(reason: String, now: Double) -> [Effect] {
        if fallbackReason != nil { return [] }
        consecutiveFailures += 1
        if consecutiveFailures >= OverlayLayout.failureLimit {
            fallbackReason = reason
            return [.fellBack(reason: reason)]
        }
        return []
    }

    /// Settings toggled off and on, or the quality changed: forget everything.
    public mutating func reset() {
        self = OverlayHealth()
    }

    /// fellBack while latched; rectangle with no mask yet, a mask older than `staleMaskSeconds`, or coverage below
    /// `minimumCoverage`; matte otherwise.
    public func presentation(now: Double) -> Presentation {
        if fallbackReason != nil { return .fellBack }
        guard let at = lastMaskAt, let coverage = lastCoverage else { return .rectangle }
        if now - at > OverlayLayout.staleMaskSeconds { return .rectangle }
        if !(coverage >= OverlayLayout.minimumCoverage) { return .rectangle }
        return .matte
    }
}
