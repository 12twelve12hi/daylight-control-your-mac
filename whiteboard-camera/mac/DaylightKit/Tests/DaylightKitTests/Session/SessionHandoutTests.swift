import Foundation
import XCTest
import DaylightKit

/// D39 and D41: page order in session.pdf, its name, the session-over rule and which PDF "Send today's board..." picks.
final class SessionHandoutTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testPageFilesAreOrderedByPageThenSuffixThenMirrors() {
        let listing = [
            "page-10.png", "page-02.json", "mirror-14-05-09.png", "page-02.png", "page-01-2.png", "session.pdf",
            "page-01.png", "page-01-10.png", "page-01-3.png", "mirror-09-00-00-2.png", "mirror-09-00-00.png",
            "page-01.json", ".DS_Store", "notes.png", "page-xx.png", "page-01-1.png", "page-01-.png",
        ]
        XCTAssertEqual(SessionHandout.pageFiles(listing), [
            "page-01.png", "page-01-2.png", "page-01-3.png", "page-01-10.png", "page-02.png", "page-10.png",
            "mirror-09-00-00.png", "mirror-09-00-00-2.png", "mirror-14-05-09.png",
        ])
        XCTAssertEqual(SessionHandout.pageFiles([]), [])
    }

    func testPDFSuffixes() {
        XCTAssertEqual(SessionHandout.pdfSuffix("session.pdf"), 1)
        XCTAssertEqual(SessionHandout.pdfSuffix("session-2.pdf"), 2)
        XCTAssertEqual(SessionHandout.pdfSuffix("session-12.pdf"), 12)
        XCTAssertNil(SessionHandout.pdfSuffix("session-.pdf"))
        XCTAssertNil(SessionHandout.pdfSuffix("session-1.pdf"))
        XCTAssertNil(SessionHandout.pdfSuffix("session.png"))
        XCTAssertNil(SessionHandout.pdfSuffix("other.pdf"))
    }

    func testPDFURLKeepsItsOwnFileAndNeverTakesAnothers() {
        let dir = URL(fileURLWithPath: "/r/Daylight Camera/2026-10-04/09-00-00")
        XCTAssertEqual(SessionHandout.pdfURL(directory: dir, bound: nil, exists: { _ in false }).path, "/r/Daylight Camera/2026-10-04/09-00-00/session.pdf")
        let taken = SessionHandout.pdfURL(directory: dir, bound: nil, exists: { $0.lastPathComponent == "session.pdf" })
        XCTAssertEqual(taken.lastPathComponent, "session-2.pdf", "a PDF this app did not write for this session is never overwritten")
        let own = dir.appendingPathComponent("session.pdf")
        XCTAssertEqual(SessionHandout.pdfURL(directory: dir, bound: own, exists: { _ in true }), own, "the session's own PDF is rewritten")
    }

    func testSessionIsOverByEitherClock() {
        let t0 = Date(timeIntervalSince1970: 1_791_100_000)
        XCTAssertTrue(SessionHandout.sessionIsOver(lastInkWall: nil, lastInkMonotonic: nil, nowWall: t0, nowMonotonic: 0))
        XCTAssertFalse(SessionHandout.sessionIsOver(lastInkWall: t0, lastInkMonotonic: 100, nowWall: t0.addingTimeInterval(600), nowMonotonic: 700))
        XCTAssertTrue(SessionHandout.sessionIsOver(lastInkWall: t0, lastInkMonotonic: 100, nowWall: t0.addingTimeInterval(601), nowMonotonic: 101), "the Mac slept: the monotonic clock stopped, the wall clock did not")
        XCTAssertTrue(SessionHandout.sessionIsOver(lastInkWall: t0, lastInkMonotonic: 100, nowWall: t0.addingTimeInterval(-3600), nowMonotonic: 701), "the wall clock went back")
    }

    func testTrackerWritesAnIdleSessionOnce() {
        var tracker = HandoutTracker()
        let start = Date(timeIntervalSince1970: 1_791_100_000)
        XCTAssertNil(tracker.takeIfIdle(nowWall: start.addingTimeInterval(9999), nowMonotonic: 9999), "nothing saved, nothing to write")
        tracker.noteInk(wall: start, monotonic: 10)
        XCTAssertNil(tracker.noteSaveQueued(sessionStart: start))
        XCTAssertNil(tracker.takeIfIdle(nowWall: start.addingTimeInterval(300), nowMonotonic: 310), "still drawing")
        XCTAssertEqual(tracker.takeIfIdle(nowWall: start.addingTimeInterval(601), nowMonotonic: 611), start)
        XCTAssertNil(tracker.takeIfIdle(nowWall: start.addingTimeInterval(1200), nowMonotonic: 1210), "written once")
        XCTAssertEqual(tracker.lastSavedStart, start)
    }

    func testTrackerHandsBackTheOldSessionWhenANewOneSaves() {
        var tracker = HandoutTracker()
        let first = Date(timeIntervalSince1970: 1_791_100_000)
        let second = first.addingTimeInterval(4000)
        XCTAssertNil(tracker.noteSaveQueued(sessionStart: first))
        XCTAssertNil(tracker.noteSaveQueued(sessionStart: first), "the same session saving again is not a hand-off")
        XCTAssertEqual(tracker.noteSaveQueued(sessionStart: second), first)
        XCTAssertEqual(tracker.takePending(), second)
        XCTAssertNil(tracker.takePending())
    }

    private func sentPath(_ choice: SessionHandout.SendChoice) -> String? {
        if case let .send(url) = choice { return url.path }
        return nil
    }

    private func fakeTree(_ files: [String]) -> (URL) -> [String]? {
        // files are paths under /r; every prefix directory is listed.
        var tree: [String: Set<String>] = [:]
        for file in files {
            var path = "/r"
            for part in file.split(separator: Character("/")).map(String.init) {
                tree[path, default: []].insert(part)
                path += "/" + part
            }
        }
        return { url in
            guard let names = tree[url.path] else { return nil }
            return Array(names)
        }
    }

    func testSendPicksTodaysNewestSessionPDF() {
        let today = Date(timeIntervalSince1970: 1_791_120_000)   // 2026-10-04T13:20:00Z
        let list = fakeTree([
            "Daylight Camera/2026-10-04/09-00-00/session.pdf",
            "Daylight Camera/2026-10-04/09-00-00/page-01.png",
            "Daylight Camera/2026-10-04/11-30-00/session.pdf",
            "Daylight Camera/2026-10-04/11-30-00/session-2.pdf",
            "Daylight Camera/2026-10-04/11-59-00/page-01.png",
            "Daylight Camera/2026-10-03/18-00-00/session.pdf",
        ])
        let choice = SessionHandout.boardToSend(root: URL(fileURLWithPath: "/r"), today: today, calendar: utc, list: list)
        XCTAssertEqual(sentPath(choice), "/r/Daylight Camera/2026-10-04/11-30-00/session-2.pdf", "the newest folder with a PDF; a folder without one is skipped")
    }

    func testSendFallsBackToTheLastSessionOfAnEarlierDay() {
        let today = Date(timeIntervalSince1970: 1_791_120_000)
        let list = fakeTree([
            "Daylight Camera/2026-10-01/10-00-00/session.pdf",
            "Daylight Camera/2026-10-03/18-00-00/session.pdf",
            "Daylight Camera/2026-10-03/08-00-00/session.pdf",
            "Daylight Camera/Diagnostics/x.zip",
        ])
        let choice = SessionHandout.boardToSend(root: URL(fileURLWithPath: "/r"), today: today, calendar: utc, list: list)
        XCTAssertEqual(sentPath(choice), "/r/Daylight Camera/2026-10-03/18-00-00/session.pdf")
    }

    func testSendWithNothingSavedSaysSo() {
        let today = Date(timeIntervalSince1970: 1_791_120_000)
        let empty = SessionHandout.boardToSend(root: URL(fileURLWithPath: "/r"), today: today, calendar: utc, list: { _ in nil })
        XCTAssertEqual(empty, .nothing("No saved board to send yet."))
        let pagesOnly = fakeTree(["Daylight Camera/2026-10-04/09-00-00/page-01.png"])
        XCTAssertEqual(SessionHandout.boardToSend(root: URL(fileURLWithPath: "/r"), today: today, calendar: utc, list: pagesOnly), .nothing(SessionHandout.nothingToSend))
    }

    func testFolderNamePatterns() {
        XCTAssertTrue(SessionHandout.isDayName("2026-10-04"))
        XCTAssertFalse(SessionHandout.isDayName("2026-1-04"))
        XCTAssertFalse(SessionHandout.isDayName("Diagnostics"))
        XCTAssertTrue(SessionHandout.isTimeName("09-00-00"))
        XCTAssertFalse(SessionHandout.isTimeName("09:00:00"))
    }

    /// Review F8: a failed write of the current session is said out loud, never a silent older PDF.
    func testAFailedWriteOfTodaysBoardIsSaid() {
        let older = URL(fileURLWithPath: "/r/Daylight Camera/2026-10-03/18-00-00/session.pdf")
        XCTAssertEqual(SessionHandout.afterWriteFailure(.send(older)), .sendAfterNotice(older, "Could not write today's board; sending the last saved one."))
        XCTAssertEqual(SessionHandout.afterWriteFailure(.nothing(SessionHandout.nothingToSend)), .nothing("Could not write today's board."))
        XCTAssertEqual(SessionHandout.afterWriteFailure(.sendAfterNotice(older, "x")), .sendAfterNotice(older, "x"))
    }
}
