import Foundation

/// A fresh page for a new call (DRAWING-DEEP-DIVE D6): when Daylight Camera's viewer count goes from 0 to 1 or more
/// (SPEC C3) and the current page holds ink whose newest stroke is older than `idleSeconds`, the app saves the page
/// and starts a blank one before any pen-down can engage, so the last call's drawing never shows in the next call.
///
/// The age is wall-clock time: the monotonic clock stops while the Mac sleeps, and a page drawn before a night's
/// sleep must count as old the next morning. A wall clock that moved backwards gives a negative age: no fresh page.
public enum FreshPage {
    /// Ten minutes, the same span as the SPEC 12 session gap. A constant, not a Settings control.
    public static let idleSeconds: Double = 600

    /// True when this viewer-count change starts a new call on a stale page. `penOnGlass` is true while any stroke is
    /// still open (a pen on the glass is never wiped from under it).
    public static func shouldStart(previousViewers: Int, viewers: Int, hasInk: Bool, newestInkAt: Date?, now: Date, penOnGlass: Bool = false) -> Bool {
        guard previousViewers <= 0, viewers >= 1, hasInk, !penOnGlass, let newest = newestInkAt else { return false }
        return now.timeIntervalSince(newest) > idleSeconds
    }
}
