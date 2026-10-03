import Foundation
import XCTest
import DaylightKit

/// `pm path`, `dumpsys package` and `getprop service.adb.tcp.port` answers: the checks that let the controller skip a
/// same-version `install -r` on plug-in and skip `tcpip 5555` when adbd already listens (both restart something).
final class AdbShellOutputTests: XCTestCase {
    func testPmPath() {
        XCTAssertTrue(AdbShellOutput.packageInstalled(pmPathOutput: "package:/data/app/~~Ab12==/com.twelve.daylight.ink-Xy==/base.apk\n"))
        XCTAssertTrue(AdbShellOutput.packageInstalled(pmPathOutput: "package:/data/app/a/base.apk\r\npackage:/data/app/a/split_config.arm64_v8a.apk\r\n"), "splits and CRLF")
        XCTAssertFalse(AdbShellOutput.packageInstalled(pmPathOutput: ""), "not installed: pm prints nothing")
        XCTAssertFalse(AdbShellOutput.packageInstalled(pmPathOutput: "\n"))
        XCTAssertFalse(AdbShellOutput.packageInstalled(pmPathOutput: "package:"), "a bare prefix is not a path")
        XCTAssertFalse(AdbShellOutput.packageInstalled(pmPathOutput: "Error: Unknown package: com.twelve.daylight.ink\n"))
        XCTAssertFalse(AdbShellOutput.packageInstalled(pmPathOutput: "error: device offline\n"))
    }

    func testDumpsysVersionCode() {
        let dump = """
        Packages:
          Package [com.twelve.daylight.ink] (3f2a1b):
            userId=10123
            pkg=Package{8d1 com.twelve.daylight.ink}
            codePath=/data/app/~~Ab12==/com.twelve.daylight.ink-Xy==
            versionCode=7 minSdk=29 targetSdk=34
            minSdk=29
            versionName=0.7
            flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ALLOW_BACKUP ]

        """
        XCTAssertEqual(AdbShellOutput.versionCode(dumpsysPackageOutput: dump), 7)
        XCTAssertEqual(AdbShellOutput.versionCode(dumpsysPackageOutput: "    versionCode=12345678 minSdk=29 targetSdk=34\r\n"), 12345678)
        XCTAssertNil(AdbShellOutput.versionCode(dumpsysPackageOutput: "Unable to find package: com.twelve.daylight.ink\n"))
        XCTAssertNil(AdbShellOutput.versionCode(dumpsysPackageOutput: ""))
        XCTAssertNil(AdbShellOutput.versionCode(dumpsysPackageOutput: "versionCode= minSdk=29\n"), "no digits is unknown, so the caller installs")
        XCTAssertNil(AdbShellOutput.versionCode(dumpsysPackageOutput: "versionName=0.7\n"))
    }

    func testGetpropTcpPort() {
        XCTAssertEqual(AdbShellOutput.tcpPort(getpropOutput: "5555\n"), 5555)
        XCTAssertEqual(AdbShellOutput.tcpPort(getpropOutput: "5555\r\n"), 5555)
        XCTAssertEqual(AdbShellOutput.tcpPort(getpropOutput: "  5556  \n"), 5556)
        XCTAssertNil(AdbShellOutput.tcpPort(getpropOutput: "\n"), "USB mode: the property is empty")
        XCTAssertNil(AdbShellOutput.tcpPort(getpropOutput: ""))
        XCTAssertNil(AdbShellOutput.tcpPort(getpropOutput: "-1\n"), "adb usb sets -1 on some builds")
        XCTAssertNil(AdbShellOutput.tcpPort(getpropOutput: "0\n"))
        XCTAssertNil(AdbShellOutput.tcpPort(getpropOutput: "70000\n"))
        XCTAssertNil(AdbShellOutput.tcpPort(getpropOutput: "error: device offline\n"))
    }
}
