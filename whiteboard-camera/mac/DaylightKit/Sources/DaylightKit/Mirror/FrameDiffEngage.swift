import Foundation

/// A small luma grid sampled from a decoded mirror frame, the input of `FrameDiffEngage`.
public enum LumaGrid {
    /// Portrait canvas grid; landscape uses `landscapeSize` (64 x 48).
    public static let portraitSize = (width: 48, height: 64)
    public static let landscapeSize = (width: 64, height: 48)

    /// Samples a BGRA image (byte order B, G, R, A; kCVPixelFormatType_32BGRA) inside `crop` (UV fractions of the
    /// image) into a `gridWidth` x `gridHeight` luma grid: each cell is the luma of the pixel at the cell centre,
    /// Y = (54 R + 183 G + 19 B) >> 8 (BT.709 integer weights). Returns row-major bytes. An image that is empty or
    /// smaller than its `bytesPerRow` and `height` say returns a grid of zeros.
    public static func sample(bgra: UnsafeRawBufferPointer, bytesPerRow: Int, width: Int, height: Int, crop: UVRect, gridWidth: Int, gridHeight: Int) -> [UInt8] {
        guard gridWidth > 0, gridHeight > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        guard width > 0, height > 0, bytesPerRow >= width * 4, bgra.count >= (height - 1) * bytesPerRow + width * 4 else { return out }
        let du = (crop.u1 - crop.u0) / Double(gridWidth)
        let dv = (crop.v1 - crop.v0) / Double(gridHeight)
        for gy in 0..<gridHeight {
            let v = crop.v0 + (Double(gy) + 0.5) * dv
            let y = clampIndex(v * Double(height), height)
            let rowStart = y * bytesPerRow
            for gx in 0..<gridWidth {
                let u = crop.u0 + (Double(gx) + 0.5) * du
                let x = clampIndex(u * Double(width), width)
                let i = rowStart + x * 4
                out[gy * gridWidth + gx] = luma(b: bgra[i], g: bgra[i + 1], r: bgra[i + 2])
            }
        }
        return out
    }

    /// Y = (54 R + 183 G + 19 B) >> 8.
    public static func luma(b: UInt8, g: UInt8, r: UInt8) -> UInt8 {
        let sum = 54 * Int(r) + 183 * Int(g) + 19 * Int(b)
        return UInt8(sum >> 8)
    }

    /// floor(position), with a tolerance of 1e-6 px so a cell centre that lands exactly on a pixel edge (for example
    /// 3 cells over 6 px: 0.5 x (1/3) x 6) picks the pixel after the edge on every platform.
    static func clampIndex(_ position: Double, _ count: Int) -> Int {
        guard position.isFinite else { return 0 }
        let bounded = min(max(position + 1e-6, 0), Double(count - 1))
        let i = Int(bounded.rounded(.down))
        return min(max(i, 0), count - 1)
    }
}

/// Engage by frame differencing inside the canvas crop: the Mirror over Wi-Fi engage source when no USB pen watcher
/// exists (SPEC 13.3 row 37). Pure; time injected in seconds.
///
/// A frame "changed" when count(|cell - previousCell| >= cellDelta) >= max(minChangedCells, ceil(changedFraction x
/// cellCount)). The first grid, or a grid of a different size, only primes. `.down` after `consecutiveFrames` changed
/// frames, each within `maxGapSeconds` of the previous changed frame, so one status-bar clock tick (a single changed
/// frame followed by identical repeats) never engages. While down, every changed frame refreshes; `.up` from `tick` or
/// `feed` once `releaseSeconds` pass without a changed frame.
public struct FrameDiffEngage {
    public struct Config: Equatable {
        public var cellDelta: Int = 24
        public var changedFraction: Double = 0.002
        public var minChangedCells: Int = 4
        public var consecutiveFrames: Int = 2
        public var maxGapSeconds: Double = 0.25
        public var releaseSeconds: Double = 1.0

        public init(cellDelta: Int = 24, changedFraction: Double = 0.002, minChangedCells: Int = 4, consecutiveFrames: Int = 2, maxGapSeconds: Double = 0.25, releaseSeconds: Double = 1.0) {
            self.cellDelta = cellDelta
            self.changedFraction = changedFraction
            self.minChangedCells = minChangedCells
            self.consecutiveFrames = consecutiveFrames
            self.maxGapSeconds = maxGapSeconds
            self.releaseSeconds = releaseSeconds
        }

        /// max(minChangedCells, ceil(changedFraction x cellCount)); a hair of tolerance keeps an exact product such as
        /// 0.0025 x 1600 = 4 from rounding up to 5 through binary floating point.
        public func changedCellThreshold(cellCount: Int) -> Int {
            let product = changedFraction * Double(cellCount)
            let fractional = product.isFinite ? Int((product - 1e-9).rounded(.up)) : cellCount
            return max(minChangedCells, fractional)
        }
    }

    public enum Edge: Equatable {
        case down
        case up
    }

    public let config: Config
    public private(set) var isDown: Bool = false

    private var previous: [UInt8]?
    private var previousWidth = 0
    private var previousHeight = 0
    private var lastChangedAt: Double?
    private var streak = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    /// The number of cells whose luma moved by at least `cellDelta`; nil when the grids differ in size.
    public static func changedCells(_ a: [UInt8], _ b: [UInt8], cellDelta: Int) -> Int? {
        guard a.count == b.count else { return nil }
        var n = 0
        for i in 0..<a.count {
            let d = Int(a[i]) - Int(b[i])
            if d >= cellDelta || -d >= cellDelta { n += 1 }
        }
        return n
    }

    public mutating func feed(grid: [UInt8], width: Int, height: Int, now: Double) -> Edge? {
        let cellCount = width * height
        guard let prev = previous, previousWidth == width, previousHeight == height, prev.count == grid.count, grid.count == cellCount else {
            previous = grid
            previousWidth = width
            previousHeight = height
            return releaseIfQuiet(now: now)
        }
        previous = grid
        let changed = (FrameDiffEngage.changedCells(prev, grid, cellDelta: config.cellDelta) ?? 0) >= config.changedCellThreshold(cellCount: cellCount)
        guard changed else { return releaseIfQuiet(now: now) }
        if isDown {
            lastChangedAt = now
            return nil
        }
        if let last = lastChangedAt, now - last <= config.maxGapSeconds {
            streak += 1
        } else {
            streak = 1
        }
        lastChangedAt = now
        if streak >= config.consecutiveFrames {
            isDown = true
            streak = 0
            return .down
        }
        return nil
    }

    public mutating func tick(now: Double) -> Edge? {
        return releaseIfQuiet(now: now)
    }

    /// Forgets the previous grid and the engage state; when `isDown` it does NOT emit `.up` (the caller posts the
    /// contact-up edge itself if needed).
    public mutating func reset() {
        previous = nil
        previousWidth = 0
        previousHeight = 0
        lastChangedAt = nil
        streak = 0
        isDown = false
    }

    private mutating func releaseIfQuiet(now: Double) -> Edge? {
        guard isDown, let last = lastChangedAt, now - last >= config.releaseSeconds else { return nil }
        isDown = false
        streak = 0
        return .up
    }
}
