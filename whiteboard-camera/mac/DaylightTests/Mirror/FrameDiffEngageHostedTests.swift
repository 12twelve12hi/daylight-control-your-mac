import CoreVideo
import DaylightKit
import Foundation
import XCTest
@testable import Daylight

/// Frame-difference engage on real 1200 x 1600 BGRA `CVPixelBuffer`s through `WifiMirrorSource.engage` (the path every
/// decoded Wi-Fi frame takes): a status-bar clock tick never engages, a thin pen stroke at writing speed engages, quiet
/// releases after 1 s, the crop keeps changes outside the canvas out, and the USB pen watcher wins when present.
final class FrameDiffEngageHostedTests: XCTestCase {
    static let width = 1200, height = 1600   // the default portrait stream; a 144 x 192 grid pools about 8 x 8 px cells

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

    /// Inks (luma 20) every pixel whose centre lies within `lineWidth` / 2 of the segment (ax, ay)-(bx, by).
    static func drawSegment(_ buffer: CVPixelBuffer, _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, lineWidth: Double) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let r = lineWidth / 2
        let dx = bx - ax
        let dy = by - ay
        let l2 = dx * dx + dy * dy
        let x0 = max(0, Int((min(ax, bx) - r - 1).rounded(.down)))
        let x1 = min(width - 1, Int((max(ax, bx) + r + 1).rounded(.up)))
        let y0 = max(0, Int((min(ay, by) - r - 1).rounded(.down)))
        let y1 = min(height - 1, Int((max(ay, by) + r + 1).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0...y1 {
            for x in x0...x1 {
                let px = Double(x) + 0.5
                let py = Double(y) + 0.5
                var t = l2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / l2 : 0
                t = min(max(t, 0), 1)
                let ex = px - (ax + t * dx)
                let ey = py - (ay + t * dy)
                guard ex * ex + ey * ey <= r * r else { continue }
                let offset = y * stride + x * 4
                bytes[offset] = 20
                bytes[offset + 1] = 20
                bytes[offset + 2] = 20
                bytes[offset + 3] = 255
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
    /// The default portrait crop on a 1200 x 1600 session: the top 96 native px (the pills strip) are outside.
    static let defaultCrop = Settings.defaults.mirrorCropInsetsPortrait.uv(sessionWidth: 1200, sessionHeight: 1600, nativeWidth: 1200, nativeHeight: 1600)

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

    func engage(_ source: WifiMirrorSource, _ buffer: CVPixelBuffer, crop: UVRect = FrameDiffEngageHostedTests.defaultCrop, at t: Double) {
        source.mirrorQueue.sync { source.engage(buffer: buffer, uv: crop, orientation: .portrait, now: t) }
    }

    /// A 3 px diagonal growing 10 px per 30 Hz frame (300 px/s, real handwriting) from t = 1 s, after the first frame
    /// (t = 0) and a repeat (t = 0.75) have primed and settled the detector. Stops after the first `.penContact` event or
    /// `maxFrames` frames; returns the buffer and the time of the last frame fed.
    @discardableResult
    func writeThinStroke(_ source: WifiMirrorSource, events: Locked<[GovernorEvent]>, maxFrames: Int = 30) -> (buffer: CVPixelBuffer, last: Double) {
        let frame = FrameDiffEngageHostedTests.makeBuffer()
        engage(source, frame, at: 0)
        engage(source, frame, at: 0.75)
        let step = 10.0 / 2.0.squareRoot()
        var x = 300.0
        var y = 400.0
        var t = 1.0
        for k in 1...maxFrames {
            FrameDiffEngageHostedTests.drawSegment(frame, x, y, x + step, y + step, lineWidth: 3)
            x += step
            y += step
            t = 1.0 + Double(k) / 30
            engage(source, frame, at: t)
            if !events.withLock({ $0 }).isEmpty { break }
        }
        return (frame, t)
    }

    func testGridSizesAndDefaults() {
        XCTAssertEqual(WifiMirrorSource.gridSize(.portrait).width, 144)
        XCTAssertEqual(WifiMirrorSource.gridSize(.portrait).height, 192)
        XCTAssertEqual(WifiMirrorSource.gridSize(.landscape).width, 192)
        XCTAssertEqual(WifiMirrorSource.gridSize(.landscape).height, 144)
        let config = WifiMirrorSource.frameDiffConfig(Settings.defaults)
        XCTAssertEqual(config.changedFraction, 0.002, "mirrorDiffThreshold default")
        XCTAssertEqual(config.cellDelta, 12)
        XCTAssertEqual(config.minChangedCells, 1)
        XCTAssertEqual(config.consecutiveFrames, 2)
        XCTAssertEqual(config.maxGapSeconds, 0.2)
        XCTAssertEqual(config.releaseSeconds, 1.0)
        XCTAssertEqual(config.settleSeconds, 0.5)
        // ceil(0.002 x 3072) = 7 cells against the run's baseline.
        XCTAssertEqual(config.changedCellThreshold, 7)
        var s = Settings.defaults
        s.mirrorDiffThreshold = 0.01
        XCTAssertEqual(WifiMirrorSource.frameDiffConfig(s).changedFraction, 0.01)
    }

    func testLumaGridPoolsEachCellInsideTheCrop() {
        let buffer = FrameDiffEngageHostedTests.makeBuffer()
        // Black over the left half: x < 600, exactly 72 cells of 1200 / 144 px.
        FrameDiffEngageHostedTests.fill(buffer, x: 0, y: 0, w: 600, h: 1600, value: 0)
        // A 2 px line at x = 606...607 inside cell 72 ([600, 608)): stride 2 reads column 606, a quarter of the cell.
        FrameDiffEngageHostedTests.fill(buffer, x: 606, y: 0, w: 2, h: 1600, value: 0)
        let grid = WifiMirrorSource.lumaGrid(buffer, crop: FrameDiffEngageHostedTests.fullCrop, gridWidth: 144, gridHeight: 192)
        XCTAssertEqual(grid?.count, 144 * 192)
        XCTAssertEqual(grid?[0], 0)
        XCTAssertEqual(grid?[71], 0)
        XCTAssertEqual(grid?[72], 191, "(3 x 255 + 0) / 4 = 191.25, rounded")
        XCTAssertEqual(grid?[143], 255)
        // Cropping to the right of the line sees only white.
        let right = WifiMirrorSource.lumaGrid(buffer, crop: UVRect(u0: 0.51, v0: 0, u1: 1, v1: 1), gridWidth: 144, gridHeight: 192)
        XCTAssertEqual(right?.allSatisfy { $0 == 255 }, true)
    }

    func testAClockTickNeverEngages() {
        let (source, events, _) = makeSource()
        let base = FrameDiffEngageHostedTests.makeBuffer()
        engage(source, base, at: 0)
        engage(source, base, at: 0.75)
        // The minute flips inside the canvas: a 60 x 80 px digit changes in one frame, then the screen repeats.
        let ticked = FrameDiffEngageHostedTests.copy(base)
        FrameDiffEngageHostedTests.fill(ticked, x: 1000, y: 300, w: 60, h: 80, value: 0)
        var t = 1.0
        for _ in 0..<12 {
            engage(source, ticked, at: t)
            t += 0.25   // the tablet repeats the previous frame every 250 ms
        }
        XCTAssertTrue(events.withLock { $0 }.isEmpty, "one changed frame followed by repeats never engages")
    }

    /// The refuter's case for DIFF-A1, end to end. Before the pooled grid it never engaged: the 48 x 64 centre-pixel
    /// grid saw at most 1 changed sample per frame of a 3 px stroke on a 1200 x 1600 stream and needed 7.
    func testAThinStrokeAtWritingSpeedEngagesAndQuietReleasesAfterOneSecond() {
        let (source, events, failures) = makeSource()
        let (frame, last) = writeThinStroke(source, events: events)
        XCTAssertEqual(events.withLock { $0 }, [.penContact(down: true)], "a 3 px stroke at 300 px/s engages")
        XCTAssertLessThanOrEqual(last - 1.0, 0.4 + 1e-9, "within 0.4 s of the first ink")
        XCTAssertTrue(source.mirrorQueue.sync { source.frameDiffIsDown })
        // The pen lifts: identical repeats every 250 ms; the release comes 1 s after the last change.
        var released: Double?
        var t = last
        while t < last + 1.6 {
            t += 0.25
            engage(source, frame, at: t)
            if released == nil, events.withLock({ $0 }).count == 2 { released = t }
        }
        XCTAssertEqual(events.withLock { $0 }, [.penContact(down: true), .penContact(down: false)])
        let gap = (released ?? 0) - last
        XCTAssertGreaterThanOrEqual(gap, 1.0 - 1e-9)
        XCTAssertLessThanOrEqual(gap, 1.25 + 1e-9)
        XCTAssertEqual(failures.withLock { $0 }, [.wifiStreamFrameDiffEngage], "row 37 shown once")
        XCTAssertEqual(source.diagnostics["wifi.engageSource"], "frame difference")
    }

    func testTickReleasesWhenFramesStop() {
        let (source, events, _) = makeSource()
        writeThinStroke(source, events: events)
        XCTAssertEqual(events.withLock { $0 }, [.penContact(down: true)])
        // No more frames: the 0.5 s tick (on the source's clock, long past the stroke's last frame + 1 s) releases.
        ink.sync { source.tick() }
        source.mirrorQueue.sync {}
        XCTAssertEqual(events.withLock { $0 }, [.penContact(down: true), .penContact(down: false)])
    }

    func testStreamEndWhileDownPostsTheRelease() {
        let (source, events, _) = makeSource()
        writeThinStroke(source, events: events)
        XCTAssertEqual(events.withLock { $0 }, [.penContact(down: true)])
        source.setActive(true)
        source.setActive(false)
        ink.sync {}
        source.mirrorQueue.sync {}
        XCTAssertEqual(events.withLock { $0 }, [.penContact(down: true), .penContact(down: false)])
    }

    func testChangesOutsideTheCanvasCropNeverEngage() {
        let (source, events, _) = makeSource()
        let crop = FrameDiffEngageHostedTests.defaultCrop
        XCTAssertEqual(crop.v0, 0.06, accuracy: 1e-9)
        let frame = FrameDiffEngageHostedTests.makeBuffer()
        engage(source, frame, crop: crop, at: 0)
        engage(source, frame, crop: crop, at: 0.75)
        for step in 0..<10 {
            // The status bar and pills strip (y < 90 px) churns every frame.
            FrameDiffEngageHostedTests.fill(frame, x: 0, y: 0, w: 1200, h: 90, value: step % 2 == 0 ? 0 : 255)
            engage(source, frame, crop: crop, at: 1.0 + Double(step + 1) / 30)
        }
        XCTAssertTrue(events.withLock { $0 }.isEmpty)
        // The same churn with the full frame as crop does engage, so the crop is what kept it out.
        let (control, controlEvents, _) = makeSource()
        let controlFrame = FrameDiffEngageHostedTests.makeBuffer()
        engage(control, controlFrame, crop: FrameDiffEngageHostedTests.fullCrop, at: 0)
        engage(control, controlFrame, crop: FrameDiffEngageHostedTests.fullCrop, at: 0.75)
        for step in 0..<3 {
            FrameDiffEngageHostedTests.fill(controlFrame, x: 0, y: 0, w: 1200, h: 90, value: step % 2 == 0 ? 0 : 255)
            engage(control, controlFrame, crop: FrameDiffEngageHostedTests.fullCrop, at: 1.0 + Double(step + 1) / 30)
        }
        XCTAssertEqual(controlEvents.withLock { $0 }, [.penContact(down: true)])
    }

    func testThePenWatcherIsPreferredWhenPresent() {
        let (source, events, failures) = makeSource(pen: true)
        writeThinStroke(source, events: events)
        XCTAssertTrue(events.withLock { $0 }.isEmpty, "frame-difference edges are ignored while the USB pen watcher runs")
        XCTAssertTrue(failures.withLock { $0 }.isEmpty, "row 37 is not shown with the pen watcher")
        XCTAssertEqual(source.diagnostics["wifi.engageSource"], "pen (USB getevent)")
    }
}
