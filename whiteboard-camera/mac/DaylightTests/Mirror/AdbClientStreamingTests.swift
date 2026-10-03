import DaylightKit
import Foundation
import XCTest
@testable import Daylight

/// `AdbClient.spawnStreaming` with a real child (`/bin/sh` in place of adb): the exit is reported only after both pipes
/// reached end of file, and at most `exitDrainCap` after the exit when a grandchild keeps a pipe open (finder ADB-B3).
final class AdbClientStreamingTests: XCTestCase {
    private func client() -> AdbClient {
        return AdbClient(executable: URL(fileURLWithPath: "/bin/sh"), queue: DispatchQueue(label: "adb-streaming-test"))
    }

    /// The scrcpy server's last stderr line is its error (ScrcpySession keeps it as `firstError`). The consumer here is
    /// slow on the first chunk, so the second chunk is still unread when the child exits. Before the fix the exit was
    /// reported 50 ms after it and the readability handlers were cleared, so the "[server] ERROR" chunk was never
    /// delivered and "exit:3" came first.
    func testTheLastStderrChunkArrivesBeforeTheExit() {
        let events = Locked<[String]>([])
        let exited = expectation(description: "exit reported")
        let script = "printf 'first\\n' >&2; sleep 0.05; printf '[server] ERROR: x\\n' >&2; exit 3"
        let handle = client().spawnStreaming(["-c", script], onStdout: { _ in }, onStderr: { data in
            let isFirst = events.withLock { e -> Bool in
                e.append("stderr:" + String(decoding: data, as: UTF8.self))
                return e.count == 1
            }
            // A slow consumer (the reader, not the test, is held): the child writes its last line and exits meanwhile.
            if isFirst { Thread.sleep(forTimeInterval: 0.3) }
        }, onExit: { status in
            events.withLock { $0.append("exit:\(status)") }
            exited.fulfill()
        })
        XCTAssertNotNil(handle)
        wait(for: [exited], timeout: 10)
        let log = events.withLock { $0 }
        XCTAssertEqual(log.last, "exit:3", "\(log)")
        let stderr = log.filter { $0.hasPrefix("stderr:") }.map { String($0.dropFirst("stderr:".count)) }.joined()
        XCTAssertEqual(stderr, "first\n[server] ERROR: x\n", "every stderr byte is delivered before the exit")
    }

    /// A grandchild that inherited stderr keeps the pipe open after the child exited: the exit still comes, bounded by
    /// the cap, instead of waiting for an end of file that only arrives when the grandchild ends.
    func testAPipeHeldOpenByAGrandchildDoesNotHoldTheExit() {
        XCTAssertEqual(AdbClient.exitDrainCap, 1)
        let exited = expectation(description: "exit reported")
        let status = Locked<Int32?>(nil)
        let handle = client().spawnStreaming(["-c", "sleep 8 >&2 & exit 0"], onStdout: { _ in }, onStderr: { _ in }, onExit: { code in
            status.withLock { $0 = code }
            exited.fulfill()
        })
        XCTAssertNotNil(handle)
        wait(for: [exited], timeout: 6)
        XCTAssertEqual(status.withLock { $0 }, 0)
    }
}
