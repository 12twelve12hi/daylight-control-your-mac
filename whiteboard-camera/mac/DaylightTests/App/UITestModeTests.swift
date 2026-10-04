import XCTest
@testable import Daylight

/// `--ui-test` and its options (docs/handoff/vp-mac-ui.md, "Design contract").
final class UITestModeTests: XCTestCase {
    private func parse(_ arguments: [String]) -> LaunchArguments {
        return LaunchArguments.parse(["Daylight"] + arguments)
    }

    func testNoArgumentsIsNotUITest() {
        let parsed = parse([])
        XCTAssertFalse(parsed.uiTest)
        XCTAssertEqual(parsed.uiTestOptions, UITestOptions())
    }

    func testUITestAlone() {
        let parsed = parse(["--ui-test"])
        XCTAssertTrue(parsed.uiTest)
        XCTAssertEqual(parsed.uiTestOptions, UITestOptions())
        XCTAssertFalse(parsed.selfTest)
        XCTAssertNil(parsed.port)
    }

    func testAppearance() {
        XCTAssertEqual(parse(["--ui-test", "--ui-test-appearance", "light"]).uiTestOptions.appearance, .light)
        XCTAssertEqual(parse(["--ui-test", "--ui-test-appearance", "dark"]).uiTestOptions.appearance, .dark)
        XCTAssertNil(parse(["--ui-test", "--ui-test-appearance", "sepia"]).uiTestOptions.appearance)
        XCTAssertNil(parse(["--ui-test", "--ui-test-appearance"]).uiTestOptions.appearance)
    }

    func testEverySurface() {
        let surfaces: [(String, UITestSurface)] = [
            ("welcome", .welcome), ("settings", .settings), ("preview", .preview),
            ("diagnostics", .diagnostics), ("allow", .allow), ("menu", .menu),
        ]
        for (name, surface) in surfaces {
            XCTAssertEqual(parse(["--ui-test", "--ui-test-open", name]).uiTestOptions.open, surface, name)
        }
        XCTAssertNil(parse(["--ui-test", "--ui-test-open", "dock"]).uiTestOptions.open)
    }

    func testOpenLastWins() {
        let parsed = parse(["--ui-test", "--ui-test-open", "settings", "--ui-test-open", "menu"])
        XCTAssertEqual(parsed.uiTestOptions.open, .menu)
        let unknownLater = parse(["--ui-test", "--ui-test-open", "settings", "--ui-test-open", "nowhere"])
        XCTAssertEqual(unknownLater.uiTestOptions.open, .settings)
    }

    func testEverySettingsTab() {
        let names = ["General", "Hotkeys", "Network", "Mirror", "Overlay", "Share", "Saving", "Advanced", "Diagnostics"]
        XCTAssertEqual(SettingsTab.allCases.map { $0.rawValue }, names)
        for tab in SettingsTab.allCases {
            XCTAssertEqual(parse(["--ui-test", "--ui-test-settings-tab", tab.rawValue]).uiTestOptions.settingsTab, tab)
            XCTAssertEqual(parse(["--ui-test", "--ui-test-settings-tab", tab.rawValue.lowercased()]).uiTestOptions.settingsTab, tab)
            XCTAssertEqual(tab.lastElementID, "daylight.settings.\(tab.rawValue.lowercased()).last")
        }
        XCTAssertNil(parse(["--ui-test", "--ui-test-settings-tab", "Printing"]).uiTestOptions.settingsTab)
    }

    func testOverlayEnabled() {
        XCTAssertTrue(parse(["--ui-test", "--ui-test-overlay-enabled"]).uiTestOptions.overlayEnabled)
        XCTAssertFalse(parse(["--ui-test"]).uiTestOptions.overlayEnabled)
    }

    func testAllOptionsTogether() {
        let parsed = parse(["--ui-test", "--ui-test-appearance", "dark", "--ui-test-open", "settings",
                            "--ui-test-settings-tab", "Mirror", "--ui-test-overlay-enabled"])
        var expected = LaunchArguments()
        expected.uiTest = true
        expected.uiTestOptions = UITestOptions(appearance: .dark, open: .settings, settingsTab: .mirror, overlayEnabled: true)
        XCTAssertEqual(parsed, expected)
    }

    func testOptionsBeforeUITestStillApply() {
        let parsed = parse(["--ui-test-open", "allow", "--ui-test"])
        XCTAssertTrue(parsed.uiTest)
        XCTAssertEqual(parsed.uiTestOptions.open, .allow)
    }

    func testOptionsWithoutUITestAreIgnored() {
        let parsed = parse(["--ui-test-appearance", "dark", "--ui-test-open", "menu", "--ui-test-settings-tab", "Saving", "--ui-test-overlay-enabled"])
        XCTAssertFalse(parsed.uiTest)
        XCTAssertEqual(parsed.uiTestOptions, UITestOptions())
        XCTAssertEqual(parsed, LaunchArguments())
    }

    func testMissingValueDoesNotSwallowTheNextOption() {
        let parsed = parse(["--ui-test-open", "--ui-test", "--ui-test-settings-tab", "--ui-test-overlay-enabled"])
        XCTAssertTrue(parsed.uiTest)
        XCTAssertNil(parsed.uiTestOptions.open)
        XCTAssertNil(parsed.uiTestOptions.settingsTab)
        XCTAssertTrue(parsed.uiTestOptions.overlayEnabled)
    }

    func testExistingFlagsUnchangedAlongsideUITest() {
        let parsed = parse(["--ui-test", "--perf-log", "--latency-probe", "--port", "7790", "--ui-test-open", "preview"])
        XCTAssertTrue(parsed.perfLog)
        XCTAssertTrue(parsed.latencyProbe)
        XCTAssertEqual(parsed.port, 7790)
        XCTAssertFalse(parsed.selfTest)
        XCTAssertEqual(parsed.uiTestOptions.open, .preview)
        XCTAssertEqual(parse(["--port=7791", "--ui-test"]).port, 7791)
        XCTAssertTrue(parse(["--self-test", "--ui-test"]).selfTest)
    }

    func testFixtures() {
        XCTAssertEqual(UITestMode.defaultsSuite, "com.twelve.daylight.uitest")
        XCTAssertEqual(UITestMode.allowLabel, "UI test tablet")
        XCTAssertEqual(UITestMode.allowAddress, "192.168.1.40")
    }
}
