import Foundation
import XCTest
import DaylightKit

/// SPEC F2: exactly the verified server arguments; the retry constants; the push and forward lines.
final class ScrcpyLaunchTests: XCTestCase {
    func testShellLineIsExactlySpecF2() {
        let launch = ScrcpyLaunch(serial: "JP0001")
        let expected = "-s JP0001 shell CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 4.1 log_level=info tunnel_forward=true video=true audio=false control=false cleanup=false video_codec=h264 max_size=1600 video_bit_rate=8000000 max_fps=30 send_device_meta=true send_frame_meta=true send_stream_meta=true send_dummy_byte=true"
        XCTAssertEqual(launch.shellCommandLine, expected)
        XCTAssertEqual(launch.shellArguments.count, 8 + 14)
        XCTAssertEqual(launch.shellArguments[7], "4.1", "the version is the first server argument")
        XCTAssertFalse(launch.shellCommandLine.contains("send_codec_meta"), "4.1 renamed it to send_stream_meta")
        XCTAssertFalse(launch.shellCommandLine.contains("raw_stream"))
    }

    func testSettingsFlowIntoTheOptions() {
        let low = Settings.lowBandwidthMirror
        let launch = ScrcpyLaunch(serial: "S", maxSize: low.maxSize, bitRate: low.bitRate, maxFps: low.maxFps, localPort: 27190)
        XCTAssertTrue(launch.serverOptions.contains("max_size=1200"))
        XCTAssertTrue(launch.serverOptions.contains("video_bit_rate=4000000"))
        XCTAssertTrue(launch.serverOptions.contains("max_fps=24"))
        XCTAssertEqual(launch.forwardArguments, ["-s", "S", "forward", "tcp:27190", "localabstract:scrcpy"])
        XCTAssertEqual(launch.forwardRemoveArguments, ["-s", "S", "forward", "--remove", "tcp:27190"])
        XCTAssertEqual(launch.pushArguments(serverPath: "/App/Vendor/scrcpy-server-v4.1"), ["-s", "S", "push", "/App/Vendor/scrcpy-server-v4.1", "/data/local/tmp/scrcpy-server.jar"])
    }

    func testConstants() {
        XCTAssertEqual(ScrcpyLaunch.serverVersion, "4.1")
        XCTAssertEqual(ScrcpyLaunch.defaultLocalPort, 27183)
        XCTAssertEqual(ScrcpyLaunch.lastLocalPort, 27199)
        XCTAssertEqual(ScrcpyLaunch.dummyByteAttempts, 100)
        XCTAssertEqual(ScrcpyLaunch.dummyByteRetryInterval, 0.1)
        XCTAssertEqual(ScrcpyLaunch.serverErrorPrefix, "[server] ERROR:")
        XCTAssertEqual(ScrcpyLaunch(serial: "x").localPort, 27183)
        XCTAssertEqual(ScrcpyLaunch(serial: "x").maxSize, Settings.defaults.mirrorMaxSize)
        XCTAssertEqual(ScrcpyLaunch(serial: "x").bitRate, Settings.defaults.mirrorBitRate)
        XCTAssertEqual(ScrcpyLaunch(serial: "x").maxFps, Settings.defaults.mirrorMaxFps)
    }

    func testOptionValueHygiene() {
        XCTAssertTrue(ScrcpyLaunch.isSafeOptionValue("1600"))
        XCTAssertTrue(ScrcpyLaunch.isSafeOptionValue("h264"))
        for bad in ["a b", "x;y", "$HOME", "a&b", "q?", "\"q\"", "a|b", "(x)", "~"] {
            XCTAssertFalse(ScrcpyLaunch.isSafeOptionValue(bad), bad)
        }
        for option in ScrcpyLaunch(serial: "x").serverOptions {
            let value = option.split(separator: "=").last.map(String.init) ?? ""
            XCTAssertTrue(ScrcpyLaunch.isSafeOptionValue(value), option)
        }
    }
}
