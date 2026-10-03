import Foundation
import XCTest
import DaylightKit

/// Timings printed by `measure {}` for the kit's hot paths (ARCHITECTURE 11.1 and SPEC D48): nothing here asserts a
/// wall-clock number; the functional invariants are asserted once after each measured block.
final class PerfTests: XCTestCase {
    func testDecodeFullChunkPerformance() throws {
        var points: [SolStream.Point] = []
        points.reserveCapacity(4096)
        for i in 0..<4096 {
            let x: Int32 = Int32(i * 7)
            let y: Int32 = Int32(i * 11)
            let p: UInt8 = UInt8(i & 0xFF)
            let d: UInt16 = UInt16(i & 0xFFFF)
            points.append(SolStream.Point(x32: x, y32: y, pressure: p, deltaMs: d))
        }
        let bytes = Codec.encode(.strokeChunk(id: UUID(), points: points), timestampUs: 1)
        XCTAssertEqual(bytes.count, 16 + 18 + 11 * 4096)
        var decodedPoints = 0
        measure {
            for _ in 0..<20 {
                if let result = try? Codec.decode(bytes), case let .strokeChunk(_, pts) = result.1 {
                    decodedPoints = pts.count
                }
            }
        }
        XCTAssertEqual(decodedPoints, 4096)
    }

    func testGovernorTickPerformance() {
        var governor = EngageGovernor(now: 0)
        _ = governor.handle(.contact(strokeID: UUID(), pointer: .stylus, phase: .contact, pressure: 0.5, tool: .pen), now: 0)
        var now = 0.0
        measure {
            for _ in 0..<3000 {
                now += 1.0 / 30
                _ = governor.tick(now: now)
            }
        }
        XCTAssertEqual(governor.snapshot.state, .live, "a pen on the glass keeps the board up for the whole run")
    }

    func testLayoutFramePerformance() {
        var frames = 0
        measure {
            var s = 0.0
            while s <= 1 {
                _ = StudioLayout.frame(progress: s, layout: .studioSplit, orientation: .portrait, canvasAspect: 0.75, breath: s)
                frames += 1
                s += 1.0 / 3000
            }
        }
        XCTAssertGreaterThan(frames, 3000)
    }

    func testWebSocketParsePerformance() throws {
        let payload = [UInt8](repeating: 0x5A, count: 65536)
        let frame = WebSocketFrame.encodeMasked(opcode: WebSocketFrame.opcodeBinary, payload: payload, key: (1, 2, 3, 4))
        var parsed = 0
        measure {
            for _ in 0..<20 {
                var buffer = frame
                if let r = try? WebSocketFrame.parse(&buffer, maxPayload: WebSocketFrame.defaultMaxPayload) {
                    parsed = r.frame.payload.count
                }
            }
        }
        XCTAssertEqual(parsed, 65536)
    }

    func testStrokeStoreAppendPerformance() {
        var store = StrokeStore()
        let id = UUID()
        store.start(StrokeStart(id: id, tool: .pen, colorARGB: 0xFF11_1111, baseWidth: 3.2, pointer: .stylus, phase: .contact, pressure: 0.5))
        var chunk: [SolStream.Point] = []
        for i in 0..<64 {
            let x: Double = Double(i)
            let y: Double = Double(i) * 1.5
            chunk.append(SolStream.Point(x: x, y: y, pressure: 0.5, deltaMs: i))
        }
        measure {
            for i in 0..<200 {
                _ = store.append(id: id, points: chunk, now: Double(i))
            }
        }
        XCTAssertGreaterThanOrEqual(store.stroke(id: id)?.points.count ?? 0, 64 * 200)
    }
}
