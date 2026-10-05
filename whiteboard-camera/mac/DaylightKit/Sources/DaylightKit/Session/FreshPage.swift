import Foundation

/// A fresh page for a new call (DRAWING-DEEP-DIVE D6): when Daylight Camera's viewer count goes from 0 to 1 or more
/// (SPEC C3) and the current page holds ink whose newest stroke is older than `idleSeconds`, the app saves the page
/// and starts a blank one before any pen-down can engage, so the last call's drawing never shows in the next call.
///
/// The age is wall-clock time: the monotonic clock stops while the Mac sleeps, and a page drawn before a night's
/// sleep must count as old the next morning. A wall clock that moved backwards gives a negative age: no fresh page.
///
/// Review of the fresh page (F1): the host itself reports a short 0 inside a running call (the sink's 2 s revalidate
/// reconnect, a failed locate, Zoom's video toggled off and on), so only a settled zero counts (a 0 that lasted
/// `settledZeroSeconds`), and only while the board is off the air: PASSTHROUGH, not pinned, no hold that forces the
/// board. A board being shown or kept is never wiped.
public enum FreshPage {
    /// Ten minutes, the same span as the SPEC 12 session gap. A constant, not a Settings control.
    public static let idleSeconds: Double = 600
    /// A 0 must last this long (wall clock) before the next 1 or more is a new call. A constant, not a setting.
    public static let settledZeroSeconds: Double = 3

    /// What the rule needs to know of the board when it is evaluated (ink.queue reads it from the governor snapshot
    /// and the stroke store).
    public struct Board: Equatable {
        public var state: GovernorState
        public var pinned: Bool
        public var hold: HoldMode
        public var hasInk: Bool
        /// A stroke is still open (a pen on the glass is never wiped from under it).
        public var penOnGlass: Bool
        /// Wall-clock time of the page's newest ink.
        public var newestInkAt: Date?

        public init(state: GovernorState = .passthrough, pinned: Bool = false, hold: HoldMode = .auto, hasInk: Bool, penOnGlass: Bool = false, newestInkAt: Date?) {
            self.state = state
            self.pinned = pinned
            self.hold = hold
            self.hasInk = hasInk
            self.penOnGlass = penOnGlass
            self.newestInkAt = newestInkAt
        }
    }

    public enum Decision: Equatable {
        /// Keep the page.
        case keep
        /// Save the page and start a blank one now.
        case start
        /// Everything holds but a stroke is open: decide again when the last open stroke lifts (review F6).
        case waitForLift
    }

    /// The board is off the air: PASSTHROUGH (camera only), not pinned, and no hold that forces the board (Hold
    /// Split or Hold Whiteboard). Hold Camera shows the camera only, so it does not keep the page.
    public static func boardIsOffAir(state: GovernorState, pinned: Bool, hold: HoldMode) -> Bool {
        return state == .passthrough && !pinned && hold.forcedLayout == nil
    }

    /// True when a 0 that began at `zeroSince` has lasted at least `settledZeroSeconds` at `now`. `zeroSince` nil
    /// means the count has been 0 since before anything was observed (launch): settled. A wall clock that moved
    /// backwards gives a negative span: not settled.
    public static func zeroIsSettled(zeroSince: Date?, now: Date) -> Bool {
        guard let since = zeroSince else { return true }
        return now.timeIntervalSince(since) >= settledZeroSeconds
    }

    /// The whole rule for a new call (`newCall` from `Viewers.update`) or a deferred one at the last lift.
    public static func decide(newCall: Bool, board: Board, now: Date) -> Decision {
        guard newCall, boardIsOffAir(state: board.state, pinned: board.pinned, hold: board.hold),
              board.hasInk, let newest = board.newestInkAt, now.timeIntervalSince(newest) > idleSeconds else { return .keep }
        return board.penOnGlass ? .waitForLift : .start
    }

    /// The age and transition part of the rule alone, for a board that is off the air: true when this viewer-count
    /// change from 0 starts a new call on a stale page. `penOnGlass` is true while any stroke is still open.
    public static func shouldStart(previousViewers: Int, viewers: Int, hasInk: Bool, newestInkAt: Date?, now: Date, penOnGlass: Bool = false) -> Bool {
        guard previousViewers <= 0, viewers >= 1 else { return false }
        return decide(newCall: true, board: Board(hasInk: hasInk, penOnGlass: penOnGlass, newestInkAt: newestInkAt), now: now) == .start
    }

    /// Daylight Camera's viewer count as the watcher reports it (changes only), with the time the current 0 began.
    /// ink.queue state of the router; a value type so the Kit tests drive it on Linux.
    public struct Viewers: Equatable {
        public private(set) var count: Int
        /// When the current run of 0 began (wall clock); nil while the count is 1 or more, and nil at launch (0 since
        /// before anything was observed, which counts as settled).
        public private(set) var zeroSince: Date?

        public init() {
            count = 0
            zeroSince = nil
        }

        /// A reported count at `now`. Returns true when it starts a new call: from 0 to 1 or more after a settled
        /// zero. A repeated count changes nothing (a 0 keeps the time it began).
        public mutating func update(_ newCount: Int, at now: Date) -> Bool {
            let next = max(newCount, 0)
            let previous = count
            count = next
            if next == 0 {
                if previous != 0 { zeroSince = now }
                return false
            }
            guard previous == 0 else { return false }
            let settled = FreshPage.zeroIsSettled(zeroSince: zeroSince, now: now)
            zeroSince = nil
            return settled
        }

        /// The Mac woke and the watcher's count at the wake is `currentCount`. If it is 0, the zero started at the
        /// wake time at the latest (a 0 already known keeps its earlier start); otherwise the wake does nothing by
        /// itself, so a call that holds the camera across a sleep keeps its page. The watcher's own report of any
        /// later change still arrives through `update`.
        public mutating func noteWake(currentCount: Int, at now: Date) {
            guard currentCount <= 0, count != 0 else { return }
            count = 0
            zeroSince = now
        }
    }
}
