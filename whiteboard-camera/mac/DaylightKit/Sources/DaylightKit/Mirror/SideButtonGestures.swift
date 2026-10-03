import Foundation

public enum SideButtonGesture: Equatable {
    case doublePress
    case longPress
}

/// What a gesture does (SPEC D10, section 7): double press = Pin, long press = Clear, swappable in Settings.
public enum SideButtonAction: Equatable {
    case pin
    case clear
}

/// Pen side-button gesture detector (SPEC section 7: `sideButtonDoublePressMs` 400, `sideButtonLongPressMs` 700).
/// Timestamps are microseconds on the device's monotonic clock (the `getevent -t` stamps). A double press is two
/// downs whose starts are at most `doublePressWindowMs` apart; a long press is a hold of at least `longPressMs`,
/// reported either by `timerFired` (the watcher arms a one-shot timer at `pendingDeadline()`) or by `up`.
/// A long press never counts as the first half of a double press, and the second press of a double is never a long press.
public struct SideButtonGestures: Equatable {
    public let doublePressWindowUs: UInt64
    public let longPressUs: UInt64
    private var downTs: UInt64?
    private var lastShortPressDownTs: UInt64?
    private var longPressReported = false
    private var ignoreUntilUp = false

    public init(doublePressWindowMs: Int = 400, longPressMs: Int = 700) {
        doublePressWindowUs = UInt64(max(1, doublePressWindowMs)) * 1000
        longPressUs = UInt64(max(1, longPressMs)) * 1000
    }

    public var isDown: Bool { return downTs != nil }

    public mutating func down(tsUs: UInt64) -> SideButtonGesture? {
        if downTs != nil { return nil }   // duplicate down without an up: keep the first
        downTs = tsUs
        longPressReported = false
        ignoreUntilUp = false
        if let first = lastShortPressDownTs, tsUs >= first, tsUs - first <= doublePressWindowUs {
            lastShortPressDownTs = nil
            ignoreUntilUp = true   // the second press of a double is consumed whole
            return .doublePress
        }
        return nil
    }

    public mutating func up(tsUs: UInt64) -> SideButtonGesture? {
        guard let start = downTs else { return nil }
        downTs = nil
        defer { ignoreUntilUp = false }
        if ignoreUntilUp { return nil }
        if longPressReported {
            longPressReported = false
            lastShortPressDownTs = nil
            return nil
        }
        if tsUs >= start && tsUs - start >= longPressUs {
            lastShortPressDownTs = nil
            return .longPress
        }
        lastShortPressDownTs = start
        return nil
    }

    /// Called when the one-shot timer armed at `pendingDeadline()` fires while the button is still held.
    public mutating func timerFired(tsUs: UInt64) -> SideButtonGesture? {
        guard let start = downTs, !longPressReported, !ignoreUntilUp else { return nil }
        guard tsUs >= start && tsUs - start >= longPressUs else { return nil }
        longPressReported = true
        lastShortPressDownTs = nil
        return .longPress
    }

    /// The device timestamp at which a held button becomes a long press; nil when no press is pending.
    public func pendingDeadline() -> UInt64? {
        guard let start = downTs, !longPressReported, !ignoreUntilUp else { return nil }
        return start + longPressUs
    }

    /// Maps a gesture to its action; `swap` exchanges the two (SPEC `sideButtonSwap`).
    public static func action(for gesture: SideButtonGesture, swap: Bool) -> SideButtonAction {
        switch gesture {
        case .doublePress: return swap ? .clear : .pin
        case .longPress: return swap ? .pin : .clear
        }
    }
}

public extension Settings {
    /// The side-button detector configured from `sideButtonDoublePressMs` and `sideButtonLongPressMs` (SPEC section 7).
    var sideButtonGestures: SideButtonGestures {
        return SideButtonGestures(doublePressWindowMs: sideButtonDoublePressMs, longPressMs: sideButtonLongPressMs)
    }
}
