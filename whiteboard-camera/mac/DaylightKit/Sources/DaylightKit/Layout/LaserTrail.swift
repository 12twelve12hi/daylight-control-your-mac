import Foundation

/// The laser pointer on the camera board (LOOSE_ENDS F3, PROTOCOL 6.9): LASER_POINT samples become a fading dot with
/// a short trail, drawn over the canvas quad and never into the page (nothing reaches the stroke store, the canvas
/// surfaces or a saved file). Each sample fades linearly from its intensity to zero over its decay (0.5 s when the
/// message carries none) and shrinks to half its radius as it fades. Pure value type; the pipeline guards it.
public struct LaserTrail {
    public struct Sample: Equatable {
        public var x: Double
        public var y: Double
        public var intensity: Double
        public var decay: Double
        public var time: Double

        public init(x: Double, y: Double, intensity: Double, decay: Double, time: Double) {
            self.x = x
            self.y = y
            self.intensity = intensity
            self.decay = decay
            self.time = time
        }
    }

    /// One dot to draw: centre and radius in canvas pixels, alpha 0...1.
    public struct Dot: Equatable {
        public var x: Double
        public var y: Double
        public var radius: Double
        public var alpha: Double

        public init(x: Double, y: Double, radius: Double, alpha: Double) {
            self.x = x
            self.y = y
            self.radius = radius
            self.alpha = alpha
        }
    }

    /// Decay used when the message carries 0, a negative or a non-finite value.
    public static let defaultDecay: Double = 0.5
    /// Decays are capped so a hostile message cannot pin a dot on the board.
    public static let maxDecay: Double = 3
    /// Dot radius in canvas pixels at full intensity (12 output px across at 1080p, 0.675 output px per canvas px).
    public static let radius: Double = 9
    /// The trail keeps at most this many samples (newest kept).
    public static let capacity = 48
    /// The colour of the dot.
    public static let color = RGBA(hex: 0xE5372A)

    public private(set) var samples: [Sample] = []

    public init() {}

    /// A LASER_POINT arrived at `now`. Coordinates outside the canvas or not finite are dropped.
    public mutating func add(x: Double, y: Double, intensity: Double, decay: Double, now: Double, canvasWidth: Double = Double(SolStream.canvasWidth), canvasHeight: Double = Double(SolStream.canvasHeight)) {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, x <= canvasWidth, y <= canvasHeight else { return }
        let i = intensity.isFinite ? min(max(intensity, 0), 1) : 1
        guard i > 0 else { return }
        let d = (decay.isFinite && decay > 0) ? min(decay, LaserTrail.maxDecay) : LaserTrail.defaultDecay
        samples.append(Sample(x: x, y: y, intensity: i, decay: d, time: now))
        if samples.count > LaserTrail.capacity { samples.removeFirst(samples.count - LaserTrail.capacity) }
    }

    /// Forgets faded samples and returns the visible dots at `now`, oldest first (the newest is drawn on top).
    public mutating func dots(at now: Double) -> [Dot] {
        samples.removeAll { now - $0.time >= $0.decay }
        return samples.compactMap { s in
            let age = max(now - s.time, 0)
            let life = 1 - age / s.decay
            guard life > 0 else { return nil }
            return Dot(x: s.x, y: s.y, radius: LaserTrail.radius * (0.5 + 0.5 * life), alpha: s.intensity * life)
        }
    }

    public var isEmpty: Bool { return samples.isEmpty }

    /// The output rectangle of a dot drawn through a canvas quad (`dest` in output pixels, `uv` the canvas part it
    /// shows); nil when no part of the dot can show: its centre more than one radius outside the visible part of the
    /// canvas. A dot whose centre lies just outside (a followed view's edge) is kept; the compositor clips it to the
    /// canvas quad, so it slides out of the frame instead of vanishing whole.
    public static func place(_ dot: Dot, through quad: QuadSpec, canvasWidth: Double = Double(SolStream.canvasWidth), canvasHeight: Double = Double(SolStream.canvasHeight)) -> PixelRect? {
        let u0 = quad.uv.u0 * canvasWidth, u1 = quad.uv.u1 * canvasWidth
        let v0 = quad.uv.v0 * canvasHeight, v1 = quad.uv.v1 * canvasHeight
        let r0 = max(dot.radius, 0)
        guard u1 > u0, v1 > v0, dot.x >= u0 - r0, dot.x <= u1 + r0, dot.y >= v0 - r0, dot.y <= v1 + r0 else { return nil }
        let sx = quad.dest.w / (u1 - u0)
        let sy = quad.dest.h / (v1 - v0)
        let cx = quad.dest.x + (dot.x - u0) * sx
        let cy = quad.dest.y + (dot.y - v0) * sy
        let r = dot.radius * sx
        return PixelRect(x: cx - r, y: cy - r, w: 2 * r, h: 2 * r)
    }
}
