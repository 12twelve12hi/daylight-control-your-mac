import DaylightKit
import Foundation
import XCTest
@testable import Daylight

/// SPEC 9.2 step 1, 9.3 step 1 and 9.4 step 2 command lists, and D42's helpers.
final class UsbOnboardingTests: XCTestCase {
    func testOpenWebCommands() {
        XCTAssertEqual(UsbOnboarding.openWebCommands(serial: "JP0001", port: 7788), [
            ["-s", "JP0001", "reverse", "tcp:7788", "tcp:7788"],
            ["-s", "JP0001", "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", "http://localhost:7788"],
        ])
        XCTAssertEqual(UsbOnboarding.openWebCommands(serial: "S", port: 7789)[1].last, "http://localhost:7789", "the bound port, not always 7788")
    }

    func testInstallInkCommands() {
        let commands = UsbOnboarding.installInkCommands(serial: "JP0001", apkPath: "/App/Contents/Resources/DaylightInk.apk", port: 7788, host: "100.64.0.7", pills: true, pillsPosition: .top)
        XCTAssertEqual(commands, [
            ["-s", "JP0001", "install", "-r", "/App/Contents/Resources/DaylightInk.apk"],
            ["-s", "JP0001", "shell", "appops", "set", "com.twelve.daylight.ink", "SYSTEM_ALERT_WINDOW", "allow"],
            ["-s", "JP0001", "shell", "pm", "grant", "com.twelve.daylight.ink", "android.permission.POST_NOTIFICATIONS"],
            ["-s", "JP0001", "reverse", "tcp:7788", "tcp:7788"],
            ["-s", "JP0001", "shell", "am", "start", "-n", "com.twelve.daylight.ink/.ui.MainActivity", "--es", "host", "100.64.0.7"],
            ["-s", "JP0001", "shell", "am", "start-foreground-service", "-n", "com.twelve.daylight.ink/.overlay.OverlayService", "--es", "pills", "top", "--es", "host", "100.64.0.7"],
        ])
        let noHost = UsbOnboarding.installInkCommands(serial: "S", apkPath: "/a.apk", port: 7788, host: nil, pills: false, pillsPosition: .bottom)
        XCTAssertEqual(noHost.count, 5)
        XCTAssertEqual(noHost[4], ["-s", "S", "shell", "am", "start", "-n", "com.twelve.daylight.ink/.ui.MainActivity"])
        XCTAssertEqual(UsbOnboarding.startPillsCommand(serial: "S", position: .bottom, host: nil), ["-s", "S", "shell", "am", "start-foreground-service", "-n", "com.twelve.daylight.ink/.overlay.OverlayService", "--es", "pills", "bottom"])
    }

    func testMirrorPillsCommands() {
        let commands = UsbOnboarding.mirrorPillsCommands(serial: "S", apkPath: "/a.apk", port: 7788, pillsPosition: .top)
        XCTAssertEqual(commands.count, 5)
        XCTAssertEqual(commands[0], ["-s", "S", "install", "-r", "/a.apk"])
        XCTAssertEqual(commands[3], ["-s", "S", "reverse", "tcp:7788", "tcp:7788"])
        XCTAssertEqual(commands[4], ["-s", "S", "shell", "am", "start-foreground-service", "-n", "com.twelve.daylight.ink/.overlay.OverlayService", "--es", "pills", "top"])
        XCTAssertFalse(commands.contains { $0.contains("-a") && $0.contains("MainActivity") }, "mirror mode never opens the note app's rival")
    }

    func testSequenceRunsInOrderAndStopsAtTheFirstFailure() {
        let adb = FakeAdb()
        adb.respond(containing: ["pm", "grant"], with: FakeAdb.fail(255, "Unknown permission"))
        let done = expectation(description: "done")
        UsbOnboarding.installInk(adb: adb, serial: "S", apk: URL(fileURLWithPath: "/a.apk"), host: nil, pills: true) { result in
            guard case let .failure(error) = result, case let .failed(status, detail, command)? = error as? AdbError else { return XCTFail("\(result)") }
            XCTAssertEqual(status, 255)
            XCTAssertEqual(detail, "Unknown permission")
            XCTAssertTrue(command.contains("pm grant"))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(adb.calls.count, 3, "install, appops, pm grant; nothing after the failure")
        XCTAssertEqual(adb.calls[0][2], "install")
        let ok = expectation(description: "ok")
        let adb2 = FakeAdb()
        UsbOnboarding.openWeb(adb: adb2, serial: "S", port: 7788) { result in
            if case .failure = result { XCTFail("\(result)") }
            ok.fulfill()
        }
        wait(for: [ok], timeout: 5)
        XCTAssertEqual(adb2.calls.count, 2)
    }

    func testIdentityConstants() {
        XCTAssertEqual(UsbOnboarding.inkPackage, "com.twelve.daylight.ink")
        XCTAssertEqual(UsbOnboarding.mainActivity, "com.twelve.daylight.ink/.ui.MainActivity")
        XCTAssertEqual(UsbOnboarding.overlayService, "com.twelve.daylight.ink/.overlay.OverlayService")
    }
}

/// D42: `ip route` parsing, the `adb connect` verdict, remember and connect through the fake adb.
final class WifiMirrorTests: XCTestCase {
    static let suite = "com.twelve.daylight.tests.wifi"

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: WifiMirrorTests.suite)?.removePersistentDomain(forName: WifiMirrorTests.suite)
    }

    func testParseRouteSourceIP() {
        let route = """
        default via 192.168.1.1 dev wlan0 proto static
        192.168.1.0/24 dev wlan0 proto kernel scope link src 192.168.1.40
        10.0.0.0/8 dev rmnet0 scope link src 10.4.5.6
        """
        XCTAssertEqual(WifiMirror.parseRouteSourceIP(route), "192.168.1.40")
        XCTAssertEqual(WifiMirror.parseRouteSourceIP("10.0.0.0/8 dev rmnet0 scope link src 10.4.5.6\n"), "10.4.5.6", "any src when no wlan line")
        XCTAssertNil(WifiMirror.parseRouteSourceIP(""))
        XCTAssertNil(WifiMirror.parseRouteSourceIP("default via 192.168.1.1 dev wlan0\n"))
        XCTAssertTrue(WifiMirror.isIPv4("192.168.1.40"))
        XCTAssertFalse(WifiMirror.isIPv4("fe80::1"))
        XCTAssertFalse(WifiMirror.isIPv4("300.1.1.1"))
    }

    func testConnectVerdict() {
        XCTAssertTrue(WifiMirror.connectSucceeded("connected to 192.168.1.40:5555\n"))
        XCTAssertTrue(WifiMirror.connectSucceeded("already connected to 192.168.1.40:5555\n"))
        XCTAssertFalse(WifiMirror.connectSucceeded("failed to connect to '192.168.1.40:5555': Connection refused\n"))
        XCTAssertFalse(WifiMirror.connectSucceeded("unable to connect to 192.168.1.40:5555\n"))
        XCTAssertFalse(WifiMirror.connectSucceeded(""))
        XCTAssertEqual(WifiMirror.port, 5555)
    }

    func testRememberThenConnect() {
        let adb = FakeAdb()
        adb.respond(containing: ["ip", "route"], with: FakeAdb.ok("192.168.1.0/24 dev wlan0 proto kernel scope link src 192.168.1.40\n"))
        adb.respond(containing: ["connect"], with: FakeAdb.ok("connected to 192.168.1.40:5555\n"))
        let defaults = UserDefaults(suiteName: WifiMirrorTests.suite)
        let wifi = WifiMirror(adb: adb, queue: DispatchQueue(label: "wifi"), defaults: defaults)
        XCTAssertNil(wifi.rememberedIP)
        let remembered = expectation(description: "remembered")
        wifi.rememberAfterUSBSession(serial: "JP0001") { ip in
            XCTAssertEqual(ip, "192.168.1.40")
            remembered.fulfill()
        }
        wait(for: [remembered], timeout: 5)
        XCTAssertEqual(adb.calls[0], ["-s", "JP0001", "shell", "ip", "route"])
        XCTAssertEqual(adb.calls[1], ["-s", "JP0001", "tcpip", "5555"])
        XCTAssertEqual(wifi.rememberedIP, "192.168.1.40")
        XCTAssertEqual(WifiMirror(adb: adb, queue: DispatchQueue(label: "wifi2"), defaults: defaults).rememberedIP, "192.168.1.40", "persisted across launches")
        let connected = expectation(description: "connected")
        wifi.tryConnect { ok in
            XCTAssertTrue(ok)
            connected.fulfill()
        }
        wait(for: [connected], timeout: 5)
        XCTAssertEqual(adb.calls[2], ["connect", "192.168.1.40:5555"])
        adb.respond(containing: ["connect"], with: FakeAdb.ok("failed to connect to '192.168.1.40:5555': Connection refused\n"))
        let refused = expectation(description: "refused")
        wifi.tryConnect { ok in
            XCTAssertFalse(ok, "row 32: adb connect exits 0 but says failed")
            refused.fulfill()
        }
        wait(for: [refused], timeout: 5)
        wifi.forget()
        XCTAssertNil(wifi.rememberedIP)
        let nothing = expectation(description: "nothing remembered")
        wifi.tryConnect { ok in
            XCTAssertFalse(ok)
            nothing.fulfill()
        }
        wait(for: [nothing], timeout: 5)
        XCTAssertEqual(FailureText.sentence(.wifiMirrorFailed), "Plug in once to re-enable Wi-Fi mirroring.")
    }
}
