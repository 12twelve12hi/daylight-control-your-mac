import Foundation

/// The 16-byte header. `opcode` stays a raw UInt16 so an unknown opcode is representable.
public struct Header: Equatable {
    public var opcode: UInt16
    public var payloadLength: UInt32
    public var timestampUs: UInt64

    public init(opcode: UInt16, payloadLength: UInt32, timestampUs: UInt64) {
        self.opcode = opcode
        self.payloadLength = payloadLength
        self.timestampUs = timestampUs
    }

    public var knownOpcode: SolStream.Opcode? { return SolStream.Opcode(rawValue: opcode) }
}

public struct StrokeStart: Equatable {
    public var id: UUID
    public var tool: SolStream.Tool
    public var colorARGB: UInt32
    public var baseWidth: Float
    public var pointer: SolStream.PointerType
    public var phase: SolStream.Phase
    public var pressure: Float

    public init(id: UUID, tool: SolStream.Tool, colorARGB: UInt32, baseWidth: Float, pointer: SolStream.PointerType, phase: SolStream.Phase, pressure: Float) {
        self.id = id
        self.tool = tool
        self.colorARGB = colorARGB
        self.baseWidth = baseWidth
        self.pointer = pointer
        self.phase = phase
        self.pressure = pressure
    }

    /// The governor engages only on a stylus contact with pressure.
    public var engages: Bool { return pointer == .stylus && phase == .contact && pressure > 0 }
}

/// STATE (0x0070), 20 bytes, server to client. PROTOCOL section 6.14.
public struct StateReport: Equatable {
    public var governor: UInt8
    public var flags: UInt8
    public var mode: UInt8
    public var inkSource: UInt8
    public var progress: Float
    public var msToReturn: UInt32
    public var pageIndex: UInt16
    public var strokeCount: UInt16
    public var undoDepth: UInt16
    public var redoDepth: UInt16

    public static let noReturnScheduled: UInt32 = 0xFFFF_FFFF

    public init(governor: UInt8, flags: UInt8, mode: UInt8, inkSource: UInt8, progress: Float, msToReturn: UInt32, pageIndex: UInt16, strokeCount: UInt16, undoDepth: UInt16, redoDepth: UInt16) {
        self.governor = governor
        self.flags = flags
        self.mode = mode
        self.inkSource = inkSource
        self.progress = progress
        self.msToReturn = msToReturn
        self.pageIndex = pageIndex
        self.strokeCount = strokeCount
        self.undoDepth = undoDepth
        self.redoDepth = redoDepth
    }

    public struct Flags: OptionSet {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let pinned = Flags(rawValue: 1)
        public static let preWarning = Flags(rawValue: 2)
        public static let clientAllowed = Flags(rawValue: 4)
        public static let clientIsActiveSource = Flags(rawValue: 8)
        public static let cameraAttached = Flags(rawValue: 16)
        public static let sinkConnected = Flags(rawValue: 32)
        public static let saving = Flags(rawValue: 64)
        public static let captureIdle = Flags(rawValue: 128)
    }

    public var flagSet: Flags { return Flags(rawValue: flags) }
}

public enum Message: Equatable {
    case handshake(canvasWidth: Float, canvasHeight: Float, dpi: Float, name: String)
    case handshakeAck(width: UInt32, height: UInt32, fps: UInt32, status: SolStream.AckStatus)
    case strokeStart(StrokeStart)
    case strokeChunk(id: UUID, points: [SolStream.Point])
    case strokeCommit(id: UUID, pointCount: UInt32)
    case strokeCancel(id: UUID)
    case undo(pageID: UUID, clientTimeUs: UInt64)
    case redo(pageID: UUID, clientTimeUs: UInt64)
    case eraseStrokes(x1: Float, y1: Float, x2: Float, y2: Float, radius: Float, ids: [UUID])
    case laserPoint(x: Float, y: Float, intensity: Float, decayS: Float)
    case clearCanvas(pageID: UUID?, clientTimeUs: UInt64?)
    case pageChange(pageID: UUID, width: Float, height: Float, index: UInt32)
    case autoEngageReturn(clientTimeUs: UInt64)
    case togglePin(value: Int8, clientTimeUs: UInt64)
    case state(StateReport)
    case ping(sequence: UInt64, clientTimeUs: UInt64)
    case pong(sequence: UInt64, clientTimeUs: UInt64)

    public var opcode: SolStream.Opcode {
        switch self {
        case .handshake: return .handshake
        case .handshakeAck: return .handshakeAck
        case .strokeStart: return .strokeStart
        case .strokeChunk: return .strokeChunk
        case .strokeCommit: return .strokeCommit
        case .strokeCancel: return .strokeCancel
        case .undo: return .undo
        case .redo: return .redo
        case .eraseStrokes: return .eraseStrokes
        case .laserPoint: return .laserPoint
        case .clearCanvas: return .clearCanvas
        case .pageChange: return .pageChange
        case .autoEngageReturn: return .autoEngageReturn
        case .togglePin: return .togglePin
        case .state: return .state
        case .ping: return .ping
        case .pong: return .pong
        }
    }
}
