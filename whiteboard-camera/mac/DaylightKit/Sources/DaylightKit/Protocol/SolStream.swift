import Foundation

/// SolStream-v1 constants and enums. Bytes: docs/PROTOCOL.md.
public enum SolStream {
    public static let magic: UInt8 = 0xDA
    public static let version: UInt8 = 0x01
    public static let headerLength = 16
    public static let pointLength = 11
    public static let maxPayload = 1 << 20
    public static let maxPointsPerChunk = 4096
    public static let maxErasedPerMessage = 1024
    public static let maxNameLength = 200
    public static let defaultPort: UInt16 = 7788
    public static let serviceType = "_daylight-camera._tcp"
    public static let subprotocol = "solstream.v1"
    public static let canvasWidth = 1200
    public static let canvasHeight = 1600
    public static let targetWidth: UInt32 = 1920
    public static let targetHeight: UInt32 = 1080
    public static let targetFPS: UInt32 = 30

    public enum Opcode: UInt16 {
        case handshake = 0x0001
        case handshakeAck = 0x0002
        case strokeStart = 0x0010
        case strokeChunk = 0x0011
        case strokeCommit = 0x0012
        case strokeCancel = 0x0013
        case undo = 0x0014
        case redo = 0x0015
        case eraseStrokes = 0x0020
        case laserPoint = 0x0030
        case clearCanvas = 0x0040
        case pageChange = 0x0050
        case autoEngageReturn = 0x0060
        case togglePin = 0x0061
        case state = 0x0070
        case ping = 0x00FE
        case pong = 0x00FF
    }

    public enum PointerType: UInt8 {
        case stylus = 0
        case finger = 1
        case palm = 2
        case mouse = 3
        case unknown = 4
    }

    public enum Phase: UInt8 {
        case hover = 0
        case contact = 1
        case cancel = 2
        case unknown = 3
    }

    public enum Tool: UInt8 {
        case pen = 0
        case highlighter = 1
        case eraser = 2
        case lasso = 3
    }

    public enum AckStatus: UInt32 {
        case ok = 0
        case pendingApproval = 1
        case denied = 2
        case unsupported = 3
    }

    public enum Role: String {
        case web
        case ink
        case overlay
        case test
    }

    /// One wire point: canvas units times 32, pressure quantised to a byte, milliseconds since the FIRST point of the stroke.
    public struct Point: Equatable {
        public var x32: Int32
        public var y32: Int32
        public var pressure: UInt8
        public var deltaMs: UInt16

        public init(x32: Int32, y32: Int32, pressure: UInt8, deltaMs: UInt16) {
            self.x32 = x32
            self.y32 = y32
            self.pressure = pressure
            self.deltaMs = deltaMs
        }

        /// Builds a point from canvas units, clamping pressure to [0, 1] and saturating delta at 65535.
        public init(x: Double, y: Double, pressure: Double, deltaMs: Int) {
            self.x32 = FixedPoint.toX32(x)
            self.y32 = FixedPoint.toX32(y)
            self.pressure = FixedPoint.quantizePressure(pressure)
            self.deltaMs = UInt16(min(max(deltaMs, 0), 65535))
        }

        public var x: Double { return FixedPoint.fromX32(x32) }
        public var y: Double { return FixedPoint.fromX32(y32) }
        public var pressureUnit: Double { return Double(pressure) / 255.0 }
    }
}
