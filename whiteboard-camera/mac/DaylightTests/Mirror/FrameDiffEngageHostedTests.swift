import CoreVideo
import DaylightKit
import Foundation
import XCTest
@testable import Daylight

/// Frame-difference engage on real BGRA `CVPixelBuffer`s through `WifiMirrorSource.engage` (the path every decoded
/// Wi-Fi frame takes): a status-bar clock tick never engages, a moving stroke engages, quiet releases after 1 s, the
/// crop keeps changes outside the canvas out, and the USB pen watcher wins when present.
final class FrameDiffEngageHostedTests: XCTestCase {
    static let width = 480, height = 640   // portrait session; a 48 x 64 grid samples every 10 px

    let ink = DispatchQueue(label: "com.twelve.daylight.tests.framediff.ink")

    static func makeBuffer() -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created)
        precondition(status == kCVReturnSuccess)
        let buffer = created!
        fill(buffer, x: 0, y: 0, w: width, h: height, value: 255)
        return buffer
    }

    /// Paints a grey rectangle (B = G = R = value).
    static func fill(_ buffer: CVPixelBuffer, x: Int, y: Int, w: Int, h: Int, value: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for row in max(0, y)..<min(height, y + h) {
            var offset = row * stride + max(0, x) * 4
            for _ in max(0, x)..<min(width, x + w) {
                bytes[offset] = value
                bytes[offset + 1] = value
                bytes[offset + 2] = value
                bytes[offset + 3] = 255
                offset += 4
            }
        }
    }

    static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer {
        let out = makeBuffer()
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        let n = CVPixelBufferGetBytesPerRow(source) * height
        memcpy(CVPixelBufferGetBaseAddress(out)!, CVPixelBufferGetBaseAddress(source)!, n)
        CVPixelBufferUnlockBaseAddress(out, [])
        CVPixelBufferUnlockBaseAddress(source, .readOnly)
        return out
    }

    static let fullCrop = UVRect(u0: 0, v0: 0, u1: 1, v1: 1)

    func makeSource(pen: Bool = false) -> (WifiMirrorSource, Locked<[GovernorEvent]>, Locked<[FailureText.Case]>) {
        var s = Settings.defaults
        s.mirrorTransport = .wifiStream
        let source = WifiMirrorSource(settings: s, inkQueue: ink, autoTick: false)
        let events = Locked<[GovernorEvent]>([])
        let failures = Locked<[FailureText.Case]>([])
        source.onGovernorEvent = { e in events.withLock { $0.append(e) } }
        source.onFailure = { f, _ in failures.withLock { $0.append(f) } }
        source.penWatcherPresent = { pen }
        return (source, events, failures)
    }

    func engage(_ source: WifiMirrorSource, _ buffer: CVPixelBuffer, crop: UVRect = FrameDiffEngageHostedTests.fullCrop, at t: Double) {
        source.mirrorQueue.sync { source.engage(buffer: buffer, uv: crop, orientation: .portrait, now: t) }
    }

    func testGridSizesAndDefaults() {
        XCTAssertEqual(WifiMirrorSource.gridSize(.portrait).width, 48)
        XCTAssertEqual(WifiMirrorSource.gridSize(.portrait).height, 64)
        XCTAssertEqual(WifiMirrorSource.gridSize(.landscape).width, 64)
        XCTAssertEqual(WifiMirrorSource.gridSize(.landscape).height, 48)
        let config = WifiMirrorSource.frameDiffConfig(Settings.defaults)
        XCTAssertEqual(config.changedFraction, 0.002, "mirrorDiffThreshold default")
        XCTAssertEqual(config.cellDelta, 24)
        XCTAssertEqual(config.minChangedCells, 4)
        XCTAssertEqual(config.consecutiveFrames, 2)
        XCTAssertEqual(config.maxGapSeconds, 0.25)
        XCTAssertEqual(config.releaseSeconds, 1.0)
        // 0.002 x 3072 cells rounds up to 7 changed cells.
        XCTAssertEqual(config.changedCellThreshold(cellCount: 48 * 64), 7)
        var s = Settings.defaults
        s.mirrorDiffThreshold = 0.01
        XCTAssertEqual(WifiMirrorSource.frameDiffConfig(s).changedFraction, 0.01)
    }

    func testLumaGridSamplesTheCellCentresInsideTheCrop() {
        let buffer = FrameDiffEngageHostedTests.makeBuffer()
        // Black over the left half: x < 240.
        FrameDiffEngageHostedTests.fill(buffer, x: 0, y: 0, w: 240, h: 640, value: 0)
        let grid = WifiMirrorSource.lumaGrid(buffer, crop: FrameDiffEngageHostedTests.fullCrop, gridWidth: 48, gridHeight: 64)
        XCTAssertEqual(grid?.count, 48 * 64)
        XCTAssertEqual(grid?[0], 0)
        XCTAssertEqual(grid?[47], 255)
        // Cropping to the right half sees only white.
        let right = WifiMirrorSource.lumaGrid(buffer, crop: UVRect(u0: 0.5, v0: 0, u1: 1, v1: 1), gridWidth: 48, gridHeight: 64)
        XCTAssertEqual(right?.allSatisfy { $0 == 255 }, true)
    }

    func testAClockTickNeverEngages() {
        let (source, events, _) = makeSource()
        let base = FrameDiffEngageHostedTests.makeBuffer()
        engage(source, base, at: 0)
        // The minute flips: a 60 x 20 px block (6 x 2 cells) changes in one frame, then the screen repeats.
        let ticked = FrameDiffEngageHostedTests.copy(base)
        FrameDiffEngageHostedTests.fill(ticked, x: 400, y: 300, w: 60, h: 20, value: 0)
        var t = 0.25
        for _ in 0..<12 {
            engage(source, ticked, at: t)
            t += 0.25   // the tablet repeats the previous frame every 250 ms
        }
        XCTAssertTrue(events.withLock { $0 }.isEmpty, "one changed frame followed by repeats never engages")
    }

    func testAMovingStrokeEngagesAndQuietReleasesAfterOneSecond() {
        let (source, events, failures) = makeSource()
        var frame = FrameDiffEngageHostedTests.makeBuffer()
        engage(source, frame, at: 0)
        var t = 0.0
        // A pen stroke: each 30 Hz frame adds a 120 x 12 px dark segment (12 cells on one grid row).
        for step in 0..<3 {
            t += 1.0 / 30
            frame = FrameDiffEngageHostedTests.copy(frame)
            FrameDiffEngageHostedTests.fill(frame, x: 20, y: 100 + step * 40, w: 120, h: 12, value: 10)
            engage(source, frame, at: t)
        }
        XCTAssertEqual(events.withLock { $0 }, [.penContact(down: true)], "two changed frames within 250 ms engage")
        XCTAssertTrue(source.mirrorQueue.sync { source.frameDiffIsDown })
        let downAt = t
        // The pen lifts: identical repeats every 250 ms; the release comes 1 s after the last change.
        var released: Double?
        while t < downAt + 1.6 {
            t += 0.25
            engage(source, frame, at: t)
            if released == nil, events.withLock({ $0 }).count == 2 { released = t }
        }
        XCTAssertEqual(events.withLock { $0 }, [.penContact(down: true), .penContact(down: false)])
        let gap = (released ?? 0) - downAt
        XCTAssertGreaterThanOrEqual(gap, 1.0)
        XCTAssertLessThanOrEqual(gap, 1.25 + 1e-9)
        XCTAssertEqual(failures.withLock { $0 }, [.wifiStreamFrameDiffEngage], "row 37 shown once")
        XCTAssertEqual(source.diagnostics["wifi.engageSource"], "frame difference")
    }

    func engageWithTwoStrokeFrames(_ source: WifiMirrorSource) {
        var frame = FrameDiffEngageHostedTests.makeBuffer()
        engage(source, frame, at: 0)
        for step in 0..<2 {
            frame = FrameDiffEngageHostedTests.copy(frame)
            FrameDiffEngageHostedTests.fill(frame, x: 200, y: 200 + step * 40, w: 200, h: 12, value: 0)
            engage(source, frame, at: 0.1 * Double(step + 1))
        }
    }

    func testTickReleasesWhenFramesStop() {
        let (source, events, _) = makeSource()
        engageWithTwoStrokeFrames(source)
        XCTAssertEqual(events.withLock { $0 }, [.penContact(down: true)])
        // No more frames: the 0.5 s tick (on the source's clock, long past 0.2 + 1 s) releases.
        ink.sync { source.tick() }
        source.mirrorQueue.sync {}
        XCTAssertEqual(events.withLock { $0 }, [.penContact(down: true), .penContact(down: false)])
    }

    func testStreamEndWhileDownPostsTheRelease() {
        let (source, events, _) = makeSource()
        engageWithTwoStrokeFrames(source)
        XCTAssertEqual(events.withLock { $0 }, [.penContact(down: true)])
        source.setActive(true)
        source.setActive(false)
        ink.sync {}
        source.mirrorQueue.sync {}
        XCTAssertEqual(events.withLock { $0 }, [.penContact(down: true), .penContact(down: false)])
    }

    func testChangesOutsideTheCanvasCropNeverEngage() {
        let (source, events, _) = makeSource()
        // Default portrait crop: the top 96 of 1600 native pixels hide the pills (6 % of the height).
        let crop = Settings.defaults.mirrorCropInsetsPortrait.uv(sessionWidth: 480, sessionHeight: 640, nativeWidth: 1200, nativeHeight: 1600)
        XCTAssertEqual(crop.v0, 0.06, accuracy: 1e-9)
        var frame = FrameDiffEngageHostedTests.makeBuffer()
        engage(source, frame, crop: crop, at: 0)
        for step in 0..<10 {
            frame = FrameDiffEngageHostedTests.copy(frame)
            // The status bar and pills strip (y < 38 px) churns every frame.
            FrameDiffEngageHostedTests.fill(frame, x: 0, y: 0, w: 480, h: 36, value: step % 2 == 0 ? 0 : 255)
            engage(source, frame, crop: crop, at: Double(step + 1) / 30)
        }
        XCTAssertTrue(events.withLock { $0 }.isEmpty)
        // The same churn with the full frame as crop does engage, so the crop is what kept it out.
        let (control, controlEvents, _) = makeSource()
        frame = FrameDiffEngageHostedTests.makeBuffer()
        engage(control, frame, at: 0)
        for step in 0..<3 {
            frame = FrameDiffEngageHostedTests.copy(frame)
            FrameDiffEngageHostedTests.fill(frame, x: 0, y: 0, w: 480, h: 36, value: step % 2 == 0 ? 0 : 255)
            engage(control, frame, at: Double(step + 1) / 30)
        }
        XCTAssertEqual(controlEvents.withLock { $0 }, [.penContact(down: true)])
    }

    func testThePenWatcherIsPreferredWhenPresent() {
        let (source, events, failures) = makeSource(pen: true)
        var frame = FrameDiffEngageHostedTests.makeBuffer()
        engage(source, frame, at: 0)
        for step in 0..<6 {
            frame = FrameDiffEngageHostedTests.copy(frame)
            FrameDiffEngageHostedTests.fill(frame, x: 20, y: 100 + step * 40, w: 300, h: 12, value: 0)
            engage(source, frame, at: Double(step + 1) / 30)
        }
        XCTAssertTrue(events.withLock { $0 }.isEmpty, "frame-difference edges are ignored while the USB pen watcher runs")
        XCTAssertTrue(failures.withLock { $0 }.isEmpty, "row 37 is not shown with the pen watcher")
        XCTAssertEqual(source.diagnostics["wifi.engageSource"], "pen (USB getevent)")
    }
}
