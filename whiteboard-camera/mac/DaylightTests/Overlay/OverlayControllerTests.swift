import CoreVideo
import DaylightKit
import Metal
import QuartzCore
import XCTest
@testable import Daylight

/// OverlayController with fake engines (SPEC 6.7, SPEC 13.3 rows 48 and 49): fallback after 15 failures with exactly one
/// row 48, drop-when-busy, matte and rectangle presentation. Never depends on Vision producing a mask.
final class OverlayControllerTests: XCTestCase {
    private final class Posted {
        private let lock = NSLock()
        private var items: [(FailureText.Case, [String])] = []

        func add(_ failure: FailureText.Case, _ args: [String]) {
            lock.lock()
            items.append((failure, args))
            lock.unlock()
        }

        func count(_ failure: FailureText.Case) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return items.filter { $0.0 == failure }.count
        }

        func args(_ failure: FailureText.Case) -> [String]? {
            lock.lock()
            defer { lock.unlock() }
            return items.first { $0.0 == failure }?.1
        }
    }

    private var enabled: Settings {
        var s = Settings.defaults
        s.overlayEnabled = true
        return s
    }

    private func makeController(_ engine: PersonMaskEngine, posted: Posted) throws -> OverlayController {
        let device = try OverlayFakes.device()
        let controller = try OverlayController(device: device, settings: enabled, telemetry: Telemetry(perfLog: false), engine: engine)
        controller.onFailure = { failure, args in posted.add(failure, args) }
        return controller
    }

    private let frame = SelfTest.gradientBuffer(width: 192, height: 108)!

    func testFifteenFailuresFallBackWithExactlyOneRow48() throws {
        let engine = ThrowingMaskEngine()
        let posted = Posted()
        let controller = try makeController(engine, posted: posted)
        XCTAssertEqual(OverlayLayout.failureLimit, 15)
        for i in 1...20 {
            controller.offer(frame, hostTimeNs: nil)
            controller.drain()
            let fellBack = controller.renderInput(now: CACurrentMediaTime()).fellBack
            XCTAssertEqual(fellBack, i >= 15, "after \(i) failures")
        }
        XCTAssertEqual(engine.calls, 15, "drained between offers; after the fallback latched nothing is segmented")
        XCTAssertEqual(controller.dropped, 0, "frames skipped while fallen back are not busy drops")
        XCTAssertEqual(posted.count(.overlayFallback), 1, "row 48 exactly once")
        XCTAssertEqual(posted.args(.overlayFallback)?.first, "15")
        XCTAssertEqual(posted.count(.overlayLowCoverage), 0)
        XCTAssertTrue(controller.isFellBack)
        XCTAssertTrue(controller.perfLine(now: CACurrentMediaTime()).hasSuffix("state=fellBack"))
        // A quality change resets the state machine (as does toggling Overlay, which makes a new controller).
        var balanced = enabled
        balanced.overlayQuality = .balanced
        controller.update(settings: balanced)
        XCTAssertFalse(controller.renderInput(now: CACurrentMediaTime()).fellBack)
        controller.offer(frame, hostTimeNs: nil)
        controller.drain()
        XCTAssertEqual(engine.calls, 16, "after the reset frames are segmented again")
    }

    func testBusySegmenterDropsInsteadOfQueueing() throws {
        let engine = BlockingMaskEngine()
        let posted = Posted()
        let controller = try makeController(engine, posted: posted)
        controller.offer(frame, hostTimeNs: nil)
        XCTAssertEqual(engine.entered.wait(timeout: .now() + 5), .success, "the first frame is being segmented")
        for _ in 0..<5 { controller.offer(frame, hostTimeNs: nil) }
        XCTAssertEqual(controller.dropped, 5, "frames offered while busy are dropped, never queued")
        engine.release()
        controller.drain()
        XCTAssertFalse(controller.segmenter.busy)
        XCTAssertEqual(engine.entered.wait(timeout: .now() + 0.3), .timedOut, "no queued frame runs afterwards")
        XCTAssertEqual(controller.dropped, 5)
    }

    func testAMaskGivesTheMatteAndAnEmptyOneTheRectangle() throws {
        let posted = Posted()
        let full = try makeController(FixedMaskEngine(value: 255), posted: posted)
        let before = full.renderInput(now: CACurrentMediaTime())
        XCTAssertFalse(before.fellBack)
        XCTAssertNil(before.input.mask, "no mask yet: the camera rectangle")
        full.offer(frame, hostTimeNs: nil)
        full.drain()
        let now = CACurrentMediaTime()
        XCTAssertEqual(full.presentation(now: now), .matte)
        XCTAssertNotNil(full.renderInput(now: now).input.mask)
        XCTAssertGreaterThanOrEqual(full.lastSegmentationMs, 0)
        XCTAssertEqual(full.presentation(now: now + OverlayLayout.staleMaskSeconds + 0.1), .rectangle, "a stale mask shows the rectangle")
        XCTAssertNil(full.renderInput(now: now + 1).input.mask)
        let line = full.perfLine(now: now)
        XCTAssertTrue(line.hasPrefix("perf overlay seg_ms="), line)
        XCTAssertTrue(line.contains(" mask_age_ms=") && line.contains(" seg_dropped=0 state=matte"), line)

        let empty = try makeController(FixedMaskEngine(value: 0), posted: posted)
        empty.offer(frame, hostTimeNs: nil)
        empty.drain()
        empty.offer(frame, hostTimeNs: nil)
        empty.drain()
        XCTAssertEqual(empty.presentation(now: CACurrentMediaTime()), .rectangle, "coverage below 0.01")
        XCTAssertEqual(posted.count(.overlayLowCoverage), 1, "row 49 once per transition")
        XCTAssertEqual(posted.count(.overlayFallback), 0)
    }
}
