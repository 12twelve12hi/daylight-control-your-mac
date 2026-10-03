import Foundation
import XCTest
import DaylightKit

final class UtilTests: XCTestCase {
    func testRingBufferOverwritesTheOldest() {
        var ring = RingBuffer<Int>(capacity: 3)
        XCTAssertEqual(ring.capacity, 3)
        XCTAssertEqual(ring.count, 0)
        ring.push(1)
        ring.push(2)
        XCTAssertEqual(ring.count, 2)
        ring.push(3)
        ring.push(4)
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring.drain(), [2, 3, 4])
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.drain(), [])
        ring.push(9)
        XCTAssertEqual(ring.drain(), [9])
        var tiny = RingBuffer<String>(capacity: 0)
        XCTAssertEqual(tiny.capacity, 1, "capacity is at least one")
        tiny.push("a")
        tiny.push("b")
        XCTAssertEqual(tiny.drain(), ["b"])
    }

    func testRateLimiter() {
        var limiter = RateLimiter(minInterval: 0.1)   // 10 Hz STATE cadence
        XCTAssertTrue(limiter.allow(now: 0))
        XCTAssertFalse(limiter.allow(now: 0.05))
        XCTAssertFalse(limiter.allow(now: 0.0999))
        XCTAssertTrue(limiter.allow(now: 0.1))
        XCTAssertFalse(limiter.allow(now: 0.15))
        XCTAssertTrue(limiter.allow(now: 5))
        var oneHz = RateLimiter(minInterval: 1)
        XCTAssertTrue(oneHz.allow(now: 10))
        XCTAssertFalse(oneHz.allow(now: 10.9))
        XCTAssertTrue(oneHz.allow(now: 11))
    }

    func testFixedPointRoundsHalfAwayFromZero() {
        XCTAssertEqual(FixedPoint.toX32(10.5), 336)
        XCTAssertEqual(FixedPoint.toX32(-3.25), -104)
        XCTAssertEqual(FixedPoint.toX32(1199.96875), 38399)
        XCTAssertEqual(FixedPoint.toX32(0.015625), 1, "exactly 0.5 after scaling rounds away from zero")
        XCTAssertEqual(FixedPoint.toX32(-0.015625), -1)
        XCTAssertEqual(FixedPoint.fromX32(336), 10.5)
        XCTAssertEqual(FixedPoint.fromX32(-104), -3.25)
        XCTAssertEqual(FixedPoint.toX32(1e12), Int32.max, "saturates")
        XCTAssertEqual(FixedPoint.toX32(-1e12), Int32.min)
        XCTAssertEqual(FixedPoint.quantizePressure(0.73), 186)
        XCTAssertEqual(FixedPoint.quantizePressure(0.2), 51)
        XCTAssertEqual(FixedPoint.quantizePressure(1.0), 255)
        XCTAssertEqual(FixedPoint.quantizePressure(7.0), 255, "clamped")
        XCTAssertEqual(FixedPoint.quantizePressure(-1), 0)
        XCTAssertEqual(FixedPoint.quantizePressure(0.5), 128, "127.5 rounds away from zero")
        let p = SolStream.Point(x: 1199.96875, y: 1599.0, pressure: 1.0, deltaMs: 70000)
        XCTAssertEqual(p, SolStream.Point(x32: 38399, y32: 51168, pressure: 255, deltaMs: 65535))
        XCTAssertEqual(SolStream.Point(x: 0, y: 0, pressure: 0, deltaMs: -5).deltaMs, 0)
    }

    func testHex() {
        XCTAssertEqual(Hex.encode([0xDA, 0x01, 0x00, 0xFF]), "da0100ff")
        XCTAssertEqual(Hex.encode([]), "")
        XCTAssertEqual(Hex.decode("da0100ff"), [0xDA, 0x01, 0x00, 0xFF])
        XCTAssertEqual(Hex.decode("DA01"), [0xDA, 0x01], "upper case accepted")
        XCTAssertEqual(Hex.decode(""), [])
        XCTAssertNil(Hex.decode("abc"), "odd length")
        XCTAssertNil(Hex.decode("zz"))
        XCTAssertNil(Hex.decode("0g"))
    }

    func testLocked() {
        let counter = Locked(0)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.locked", attributes: .concurrent)
        for _ in 0..<8 {
            queue.async(group: group) {
                for _ in 0..<1000 {
                    counter.withLock { $0 += 1 }
                }
            }
        }
        group.wait()
        XCTAssertEqual(counter.withLock { $0 }, 8000)
        let value = counter.withLock { v -> String in "\(v)" }
        XCTAssertEqual(value, "8000")
    }

    func testClocks() {
        let manual = ManualClock(start: 10)
        XCTAssertEqual(manual.now(), 10)
        manual.advance(1.5)
        XCTAssertEqual(manual.now(), 11.5)
        manual.set(3)
        XCTAssertEqual(manual.now(), 3)
        let system = SystemClock()
        let a = system.now()
        let b = system.now()
        XCTAssertGreaterThanOrEqual(b, a, "monotonic")
        XCTAssertLessThan(a, 1e9, "uptime seconds, not an epoch (wall-clock epochs are above 1.7e9)")
    }

    func testIdentityRules() {
        let ok = Identity(name: "ink;6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b;Mike\u{2019}s DC-1")
        XCTAssertEqual(ok?.role, .ink)
        XCTAssertEqual(ok?.clientID, "6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b")
        XCTAssertEqual(ok?.label, "Mike\u{2019}s DC-1")
        XCTAssertEqual(ok?.name, "ink;6f1a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b;Mike\u{2019}s DC-1")
        XCTAssertEqual(Identity(name: "overlay;id;a;b;c")?.label, "a;b;c", "the label may contain semicolons")
        XCTAssertEqual(Identity(name: "test;id;")?.label, "")
        XCTAssertNil(Identity(name: "web;id"), "two semicolons required")
        XCTAssertNil(Identity(name: "pilot;id;label"), "unknown role")
        XCTAssertNil(Identity(name: "web;;label"), "empty clientId")
        XCTAssertNil(Identity(name: "web;" + String(repeating: "x", count: 65) + ";label"), "clientId over 64 bytes")
        XCTAssertNotNil(Identity(name: "web;id;" + String(repeating: "x", count: 64)), "64-byte label is the limit")
        XCTAssertNil(Identity(name: "web;id;" + String(repeating: "x", count: 65)), "65-byte label rejected")
        XCTAssertNil(Identity(name: "web;id;" + String(repeating: "\u{2019}", count: 22)), "66 UTF-8 bytes in 22 characters")
        XCTAssertNotNil(Identity(name: "web;id;" + String(repeating: "\u{2019}", count: 21)), "63 UTF-8 bytes")
        let test = Identity(role: .test, clientID: "t", label: "self-test")
        XCTAssertTrue(test.mayControl(.strokeStart))
        let overlay = Identity(role: .overlay, clientID: "o", label: "pills")
        XCTAssertTrue(overlay.mayControl(.togglePin))
        XCTAssertTrue(overlay.mayControl(.clearCanvas))
        XCTAssertTrue(overlay.mayControl(.autoEngageReturn))
        XCTAssertFalse(overlay.mayControl(.strokeStart))
        XCTAssertFalse(Identity(role: .web, clientID: "w", label: "").mayControl(.strokeChunk), "ink needs the active-source gate, not this check")
    }
}
