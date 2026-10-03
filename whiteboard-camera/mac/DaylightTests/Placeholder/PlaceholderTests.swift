// The DaylightTests bundle is hosted by Daylight.app (XcodeGen sets TEST_HOST because the target depends on
// the application). This file keeps the bundle non-empty until the components add their macOS-only tests.
// It also prints which process hosts the tests, which answers LOOSE_ENDS B13 from the CI log.
import XCTest
import DaylightKit

final class PlaceholderTests: XCTestCase {
    func testKitIsLinked() {
        XCTAssertEqual(SolStream.version, 1)
        XCTAssertEqual(SolStream.headerLength, 16)
    }

    func testReportsHostProcess() {
        let bundle = Bundle.main
        print("hosted-test: Bundle.main.bundleIdentifier=\(bundle.bundleIdentifier ?? "nil") path=\(bundle.bundlePath)")
        print("hosted-test: process=\(ProcessInfo.processInfo.processName) pid=\(ProcessInfo.processInfo.processIdentifier)")
        XCTAssertFalse(bundle.bundlePath.isEmpty)
    }
}
