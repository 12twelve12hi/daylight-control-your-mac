import Foundation

/// A pooled luma grid of a decoded mirror frame, the input of `FrameDiffEngage`.
///
/// Every cell summarizes its whole area, so a thin pen line anywhere inside a cell moves the cell's value: the value is
/// the rounded mean luma of a `stride` x `stride` sub-sample of the cell's pixels (every 2nd pixel of every 2nd row by
/// default, about 450 000 reads for a 1200 x 1504 canvas crop). A 3 px line crossing an 8 px cell moves it by several
/// times `FrameDiffEngage.Config.cellDelta`; one sample per cell (the earlier design) missed almost every stroke (SPEC F10).
public enum LumaGrid {
    /// Portrait canvas grid; landscape uses `landscapeSize` (192 x 144). On the default 1200 x 1600 stream a cell is
    /// about 8 x 8 px inside the canvas crop.
    public static let portraitSize = (width: 144, height: 192)
    public static let landscapeSize = (width: 192, height: 144)
    /// Sub-sampling step inside a cell, in pixels, in both directions.
    public static let defaultStride = 2

    /// Pools a BGRA image (byte order B, G, R, A; kCVPixelFormatType_32BGRA) inside `crop` (UV fractions of the image)
    /// into a `gridWidth` x `gridHeight` grid. Cell (gx, gy) covers the pixel columns [floor(u_gx x width),
    /// floor(u_gx+1 x width)) and the rows likewise (at least one pixel, clamped to the image); its value is the rounded
    /// mean of Y = (54 R + 183 G + 19 B) >> 8 (BT.709 integer weights) over the pixels at the cell's first column and row
    /// plus multiples of `stride`. Returns row-major bytes. An image that is empty or smaller than its `bytesPerRow` and
    /// `height` say returns a grid of zeros. A `stride` below 1 counts as 1.
    public static func sample(bgra: UnsafeRawBufferPointer, bytesPerRow: Int, width: Int, height: Int, crop: UVRect, gridWidth: Int, gridHeight: Int, stride: Int = LumaGrid.defaultStride) -> [UInt8] {
        guard gridWidth > 0, gridHeight > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        guard width > 0, height > 0, bytesPerRow >= width * 4, bgra.count >= (height - 1) * bytesPerRow + width * 4 else { return out }
        let step = max(1, stride)
        let columns = cellRanges(from: crop.u0, to: crop.u1, cells: gridWidth, pixels: width)
        let rows = cellRanges(from: crop.v0, to: crop.v1, cells: gridHeight, pixels: height)
        for gy in 0..<gridHeight {
            let rowRange = rows[gy]
            for gx in 0..<gridWidth {
                let columnRange = columns[gx]
                var sum = 0
                var count = 0
                var y = rowRange.start
                while y < rowRange.end {
                    let rowStart = y * bytesPerRow
                    var x = columnRange.start
                    while x < columnRange.end {
                        let i = rowStart + x * 4
                        sum += (54 * Int(bgra[i + 2]) + 183 * Int(bgra[i + 1]) + 19 * Int(bgra[i])) >> 8
                        count += 1
                        x += step
                    }
                    y += step
                }
                out[gy * gridWidth + gx] = count > 0 ? UInt8(min((sum + count / 2) / count, 255)) : 0
            }
        }
        return out
    }

    /// Y = (54 R + 183 G + 19 B) >> 8.
    public static func luma(b: UInt8, g: UInt8, r: UInt8) -> UInt8 {
        let sum = 54 * Int(r) + 183 * Int(g) + 19 * Int(b)
        return UInt8(sum >> 8)
    }

    /// The pixel range [start, end) of each of `cells` cells spanning the fractions [from, to) of `pixels`: start =
    /// floor(position) clamped to the last pixel, end = floor(next position) clamped to [start + 1, pixels], so every
    /// cell has at least one pixel even when the grid is finer than the image.
    static func cellRanges(from: Double, to: Double, cells: Int, pixels: Int) -> [(start: Int, end: Int)] {
        let d = (to - from) / Double(cells)
        var out: [(start: Int, end: Int)] = []
        out.reserveCapacity(cells)
        for c in 0..<cells {
            let start = clampIndex((from + Double(c) * d) * Double(pixels), pixels)
            let next = edgeIndex((from + Double(c + 1) * d) * Double(pixels), pixels)
            out.append((start: start, end: min(max(next, start + 1), pixels)))
        }
        return out
    }

    /// floor(position), with a tolerance of 1e-6 px so a cell edge that lands exactly on a pixel edge (for example
    /// 3 cells over 6 px) picks the same pixel on every platform; clamped to [0, count - 1].
    static func clampIndex(_ position: Double, _ count: Int) -> Int {
        guard position.isFinite else { return 0 }
        let bounded = min(max(position + 1e-6, 0), Double(count - 1))
        let i = Int(bounded.rounded(.down))
        return min(max(i, 0), count - 1)
    }

    /// floor(position) with the same tolerance, clamped to [0, count] (an exclusive end).
    static func edgeIndex(_ position: Double, _ count: Int) -> Int {
        guard position.isFinite else { return position > 0 ? count : 0 }
        let bounded = min(max(position + 1e-6, 0), Double(count))
        let i = Int(bounded.rounded(.down))
        return min(max(i, 0), count)
    }
}

/// Engage by frame differencing inside the canvas crop: the Mirror over Wi-Fi engage source when no USB pen watcher
/// exists (SPEC 13.3 row 37, SPEC F10). Pure; time injected in seconds.
///
/// A cell "moved" when its pooled luma differs by at least `cellDelta`. A frame is active when at least one cell moved
/// against the previous grid. Active frames whose media times (the stream PTS) are each less than `maxGapSeconds`
/// after the previous active frame form a run; the run's baseline is the grid just before its first active frame.
/// `.down` when a run has at least `consecutiveFrames` active frames AND at least `changedCellThreshold` cells moved
/// against the baseline. So ink that grows a few cells per frame adds up, while one status-bar clock tick or a cursor
/// blink (one active frame, then repeats 250 ms later) never forms a run, and a lossy frame followed by its clean
/// repeat moves nothing against the baseline. While down, every active frame refreshes; `.up` from `tick` or `feed`
/// once `releaseSeconds` pass on the host clock without an active frame.
///
/// The first grid after `init` or `reset()` primes and opens a settle window: for `settleSeconds` of media time every
/// grid only re-primes (a rotation animation or the first frames of a new session never engage). `reprime()` (crop
/// changed) primes the next grid without a settle window and keeps a held contact. A grid of a different size primes.
/// Media time that goes backwards (a new stream) ends the run.
public struct FrameDiffEngage {
    public struct Config: Equatable {
        /// Pooled luma levels a cell must move by.
        public var cellDelta: Int = 12
        /// The `mirrorDiffThreshold` setting: cells to move against the run's baseline = ceil(changedFraction x
        /// `referenceCellCount`), at least `minChangedCells`. Every 0.0005 step of the setting adds 1.5 cells, so every
        /// stepper value is a distinct count (0.0005 is 2 cells, 0.002 is 7, 0.05 is 154).
        public var changedFraction: Double = 0.002
        public var minChangedCells: Int = 1
        public var consecutiveFrames: Int = 2
        /// Strict: an active frame exactly this far (media time) after the previous one starts a new run. Shorter than
        /// the encoder's 250 ms repeat, so a repeat (and its lossy refinement) never continues a run.
        public var maxGapSeconds: Double = 0.2
        public var releaseSeconds: Double = 1.0
        /// Media time after the first grid of a session (after `init` or `reset()`) during which grids only re-prime.
        public var settleSeconds: Double = 0.5
        /// The scale of `changedFraction`: 3072, the cell count of the earlier 48 x 64 grid, so a stored setting keeps
        /// its cell count.
        public var referenceCellCount: Int = 3072

        public init(cellDelta: Int = 12, changedFraction: Double = 0.002, minChangedCells: Int = 1, consecutiveFrames: Int = 2, maxGapSeconds: Double = 0.2, releaseSeconds: Double = 1.0, settleSeconds: Double = 0.5, referenceCellCount: Int = 3072) {
            self.cellDelta = cellDelta
            self.changedFraction = changedFraction
            self.minChangedCells = minChangedCells
            self.consecutiveFrames = consecutiveFrames
            self.maxGapSeconds = maxGapSeconds
            self.releaseSeconds = releaseSeconds
            self.settleSeconds = settleSeconds
            self.referenceCellCount = referenceCellCount
        }

        /// max(minChangedCells, ceil(changedFraction x referenceCellCount)); a hair of tolerance keeps an exact product
        /// from rounding up through binary floating point.
        public var changedCellThreshold: Int {
            let product = changedFraction * Double(referenceCellCount)
            let fractional = product.isFinite ? Int((product - 1e-9).rounded(.up)) : referenceCellCount
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
    private var baseline: [UInt8] = []
    private var previousWidth = 0
    private var previousHeight = 0
    /// Host time of the last active frame while down (the release clock).
    private var lastChangedAt: Double?
    /// Media time of the last active frame (the run clock).
    private var lastActiveMedia: Double?
    private var lastMedia: Double?
    private var streak = 0
    /// True until the first grid after init or reset has primed; that prime opens the settle window.
    private var settlePending = true
    private var settleUntil: Double?

    public init(config: Config = Config()) {
        self.config = config
    }

    /// The number of cells whose value moved by at least `cellDelta`; nil when the grids differ in size.
    public static func changedCells(_ a: [UInt8], _ b: [UInt8], cellDelta: Int) -> Int? {
        guard a.count == b.count else { return nil }
        var n = 0
        for i in 0..<a.count {
            let d = Int(a[i]) - Int(b[i])
            if d >= cellDelta || -d >= cellDelta { n += 1 }
        }
        return n
    }

    /// One pooled grid. `now` is the host clock (release); `mediaTime` is the frame's presentation time in seconds
    /// (the stream PTS: the run gap and the settle window).
    public mutating func feed(grid: [UInt8], width: Int, height: Int, now: Double, mediaTime: Double) -> Edge? {
        if let last = lastMedia, mediaTime < last {
            endRun()
            if settleUntil != nil { settleUntil = mediaTime + config.settleSeconds }
        }
        lastMedia = mediaTime
        let cellCount = width * height
        guard let prev = previous, previousWidth == width, previousHeight == height, prev.count == grid.count, grid.count == cellCount else {
            prime(grid, width: width, height: height)
            if settlePending {
                settlePending = false
                settleUntil = mediaTime + config.settleSeconds
            }
            return releaseIfQuiet(now: now)
        }
        previous = grid
        if let until = settleUntil {
            if mediaTime < until {
                baseline = grid
                return releaseIfQuiet(now: now)
            }
            settleUntil = nil
        }
        let moved = FrameDiffEngage.changedCells(prev, grid, cellDelta: config.cellDelta) ?? 0
        guard moved > 0 else { return releaseIfQuiet(now: now) }
        if let lastActive = lastActiveMedia, mediaTime - lastActive < config.maxGapSeconds {
            streak += 1
        } else {
            streak = 1
            baseline = prev
        }
        lastActiveMedia = mediaTime
        if isDown {
            lastChangedAt = now
            return nil
        }
        guard streak >= config.consecutiveFrames else { return nil }
        let fromBaseline = FrameDiffEngage.changedCells(baseline, grid, cellDelta: config.cellDelta) ?? 0
        guard fromBaseline >= config.changedCellThreshold else { return nil }
        isDown = true
        lastChangedAt = now
        return .down
    }

    /// The earlier entry point: the host clock serves as media time too.
    @available(*, deprecated, message: "pass mediaTime: the frame's PTS in seconds (SPEC F10)")
    public mutating func feed(grid: [UInt8], width: Int, height: Int, now: Double) -> Edge? {
        return feed(grid: grid, width: width, height: height, now: now, mediaTime: now)
    }

    public mutating func tick(now: Double) -> Edge? {
        return releaseIfQuiet(now: now)
    }

    /// The sampling window changed (a new crop): the next grid primes without being compared and without a settle
    /// window. A held contact stays down and its release clock keeps running; nothing is emitted.
    public mutating func reprime() {
        previous = nil
        previousWidth = 0
        previousHeight = 0
        baseline = []
        endRun()
    }

    /// Forgets the previous grid and the engage state, and arms the settle window for the next session; when `isDown`
    /// it does NOT emit `.up` (the caller posts the contact-up edge itself if needed).
    public mutating func reset() {
        previous = nil
        previousWidth = 0
        previousHeight = 0
        baseline = []
        lastChangedAt = nil
        lastMedia = nil
        endRun()
        isDown = false
        settlePending = true
        settleUntil = nil
    }

    private mutating func prime(_ grid: [UInt8], width: Int, height: Int) {
        previous = grid
        baseline = grid
        previousWidth = width
        previousHeight = height
        endRun()
    }

    private mutating func endRun() {
        streak = 0
        lastActiveMedia = nil
    }

    private mutating func releaseIfQuiet(now: Double) -> Edge? {
        guard isDown, let last = lastChangedAt, now - last >= config.releaseSeconds else { return nil }
        isDown = false
        endRun()
        return .up
    }
}
