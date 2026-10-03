import Foundation
import XCTest
import DaylightKit

/// Acceptance A8: SPEC 12 folder names and collision suffixes.
final class SessionFilesTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testSessionDirectoryHasDayAndTimeFolders() {
        let root = URL(fileURLWithPath: "/Users/mike/Documents")
        let start = Date(timeIntervalSince1970: 1_791_036_309)   // 2026-10-03T14:05:09Z
        let dir = SessionFiles.sessionDirectory(root: root, sessionStart: start, calendar: utc)
        XCTAssertEqual(dir.path, "/Users/mike/Documents/Daylight Camera/2026-10-03/14-05-09")
        XCTAssertTrue(dir.hasDirectoryPath)
        let midnight = SessionFiles.sessionDirectory(root: root, sessionStart: Date(timeIntervalSince1970: 0), calendar: utc)
        XCTAssertEqual(midnight.path, "/Users/mike/Documents/Daylight Camera/1970-01-01/00-00-00", "zero padded")
    }

    func testSessionDirectoryFollowsTheCalendarTimeZone() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let start = Date(timeIntervalSince1970: 1_791_036_309)   // 23:05:09 in Tokyo
        let dir = SessionFiles.sessionDirectory(root: URL(fileURLWithPath: "/r"), sessionStart: start, calendar: tokyo)
        XCTAssertEqual(dir.path, "/r/Daylight Camera/2026-10-03/23-05-09")
    }

    func testPageBaseNamesAreOneBased() {
        XCTAssertEqual(SessionFiles.pageBaseName(index: 0), "page-01")
        XCTAssertEqual(SessionFiles.pageBaseName(index: 1), "page-02")
        XCTAssertEqual(SessionFiles.pageBaseName(index: 9), "page-10")
        XCTAssertEqual(SessionFiles.pageBaseName(index: 99), "page-100")
        XCTAssertEqual(SessionFiles.pageBaseName(index: -1), "page-01", "never below one")
    }

    func testMirrorName() {
        XCTAssertEqual(SessionFiles.mirrorName(sessionStart: Date(timeIntervalSince1970: 1_791_036_309), calendar: utc), "mirror-14-05-09")
    }

    func testUniqueURLAppendsSuffixesBeforeTheExtension() {
        let base = URL(fileURLWithPath: "/tmp/s/page-01.png")
        XCTAssertEqual(SessionFiles.uniqueURL(base, exists: { _ in false }), base)
        var taken: Set<String> = ["/tmp/s/page-01.png"]
        XCTAssertEqual(SessionFiles.uniqueURL(base, exists: { taken.contains($0.path) }).path, "/tmp/s/page-01-2.png")
        taken.insert("/tmp/s/page-01-2.png")
        taken.insert("/tmp/s/page-01-3.png")
        XCTAssertEqual(SessionFiles.uniqueURL(base, exists: { taken.contains($0.path) }).path, "/tmp/s/page-01-4.png")
        let json = URL(fileURLWithPath: "/tmp/s/page-01.json")
        XCTAssertEqual(SessionFiles.uniqueURL(json, exists: { $0.path == "/tmp/s/page-01.json" }).path, "/tmp/s/page-01-2.json")
        let noExtension = URL(fileURLWithPath: "/tmp/s/notes")
        XCTAssertEqual(SessionFiles.uniqueURL(noExtension, exists: { $0.path == "/tmp/s/notes" }).path, "/tmp/s/notes-2")
    }

    func testSessionGapRule() {
        XCTAssertTrue(SessionFiles.startsNewSession(lastInkAt: nil, now: 5))
        XCTAssertFalse(SessionFiles.startsNewSession(lastInkAt: 100, now: 100 + 600))
        XCTAssertTrue(SessionFiles.startsNewSession(lastInkAt: 100, now: 100 + 600.5))
        XCTAssertEqual(SessionFiles.sessionGapSeconds, 600)
    }
}
