import Foundation

public enum CodecError: Error, Equatable {
    case badMagic(UInt8)
    case badVersion(UInt8)
    case truncated(needed: Int, have: Int)
    case lengthMismatch(declared: Int, actual: Int)
    case unknownOpcode(UInt16)
    case badPayload(opcode: UInt16, reason: String)
    case limitExceeded(opcode: UInt16, value: Int, max: Int)
}

/// SolStream-v1 encoder and decoder. Every layout is in docs/PROTOCOL.md section 6.
public enum Codec {
    // MARK: Encoding

    public static func encode(_ m: Message, timestampUs: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        encode(m, timestampUs: timestampUs, into: &out)
        return out
    }

    public static func encode(_ m: Message, timestampUs: UInt64, into out: inout [UInt8]) {
        var w = ByteWriter(reserving: 64)
        w.u8(SolStream.magic)
        w.u8(SolStream.version)
        w.u16(m.opcode.rawValue)
        let lengthIndex = w.count
        w.u32(0)
        w.u64(timestampUs)
        let payloadStart = w.count
        writePayload(m, into: &w)
        w.patchU32(UInt32(w.count - payloadStart), at: lengthIndex)
        out.append(contentsOf: w.storage)
    }

    private static func writePayload(_ m: Message, into w: inout ByteWriter) {
        switch m {
        case let .handshake(canvasWidth, canvasHeight, dpi, name):
            let utf8 = Array(name.utf8)
            w.f32(canvasWidth)
            w.f32(canvasHeight)
            w.f32(dpi)
            w.u16(UInt16(truncatingIfNeeded: utf8.count))
            w.bytes(utf8)
        case let .handshakeAck(width, height, fps, status):
            w.u32(width)
            w.u32(height)
            w.u32(fps)
            w.u32(status.rawValue)
        case let .strokeStart(s):
            w.uuid(s.id)
            w.u8(s.tool.rawValue)
            w.u32(s.colorARGB)
            w.f32(s.baseWidth)
            w.u8(s.pointer.rawValue)
            w.u8(s.phase.rawValue)
            w.f32(s.pressure)
        case let .strokeChunk(id, points):
            w.uuid(id)
            w.u16(UInt16(truncatingIfNeeded: points.count))
            for p in points {
                w.i32(p.x32)
                w.i32(p.y32)
                w.u8(p.pressure)
                w.u16(p.deltaMs)
            }
        case let .strokeCommit(id, pointCount):
            w.uuid(id)
            w.u32(pointCount)
        case let .strokeCancel(id):
            w.uuid(id)
        case let .undo(pageID, clientTimeUs), let .redo(pageID, clientTimeUs):
            w.uuid(pageID)
            w.u64(clientTimeUs)
        case let .eraseStrokes(x1, y1, x2, y2, radius, ids):
            w.f32(x1)
            w.f32(y1)
            w.f32(x2)
            w.f32(y2)
            w.f32(radius)
            w.u16(UInt16(truncatingIfNeeded: ids.count))
            for id in ids {
                w.uuid(id)
            }
        case let .laserPoint(x, y, intensity, decayS):
            w.f32(x)
            w.f32(y)
            w.f32(intensity)
            w.f32(decayS)
        case let .clearCanvas(pageID, clientTimeUs):
            // Clients send the 24-byte form; nil page means "current page" (all-zero UUID).
            let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            w.uuid(pageID ?? zero)
            w.u64(clientTimeUs ?? 0)
        case let .pageChange(pageID, width, height, index):
            w.uuid(pageID)
            w.f32(width)
            w.f32(height)
            w.u32(index)
        case let .autoEngageReturn(clientTimeUs):
            w.u64(clientTimeUs)
        case let .togglePin(value, clientTimeUs):
            w.i8(value)
            w.u64(clientTimeUs)
        case let .state(s):
            w.u8(s.governor)
            w.u8(s.flags)
            w.u8(s.mode)
            w.u8(s.inkSource)
            w.f32(s.progress)
            w.u32(s.msToReturn)
            w.u16(s.pageIndex)
            w.u16(s.strokeCount)
            w.u16(s.undoDepth)
            w.u16(s.redoDepth)
        case let .ping(sequence, clientTimeUs), let .pong(sequence, clientTimeUs):
            w.u64(sequence)
            w.u64(clientTimeUs)
        }
    }

    // MARK: Decoding

    public static func decodeHeader(_ bytes: UnsafeRawBufferPointer) throws -> Header {
        var r = ByteReader(bytes)
        if bytes.count < SolStream.headerLength {
            throw CodecError.truncated(needed: SolStream.headerLength, have: bytes.count)
        }
        let magic = try r.u8()
        if magic != SolStream.magic { throw CodecError.badMagic(magic) }
        let version = try r.u8()
        if version != SolStream.version { throw CodecError.badVersion(version) }
        let opcode = try r.u16()
        let length = try r.u32()
        let timestamp = try r.u64()
        if Int(length) > SolStream.maxPayload {
            throw CodecError.limitExceeded(opcode: opcode, value: Int(length), max: SolStream.maxPayload)
        }
        return Header(opcode: opcode, payloadLength: length, timestampUs: timestamp)
    }

    public static func decode(_ bytes: [UInt8]) throws -> (Header, Message) {
        return try bytes.withUnsafeBytes { try decode($0) }
    }

    public static func decode(_ bytes: UnsafeRawBufferPointer) throws -> (Header, Message) {
        let (header, message) = try decodeLenient(bytes)
        guard let message = message else { throw CodecError.unknownOpcode(header.opcode) }
        return (header, message)
    }

    /// Returns `nil` for an unknown opcode (ignored by the server); still throws for malformed known messages.
    public static func decodeLenient(_ bytes: UnsafeRawBufferPointer) throws -> (Header, Message?) {
        let header = try decodeHeader(bytes)
        let actual = bytes.count - SolStream.headerLength
        if Int(header.payloadLength) != actual {
            throw CodecError.lengthMismatch(declared: Int(header.payloadLength), actual: actual)
        }
        guard let opcode = header.knownOpcode else { return (header, nil) }
        let payload = UnsafeRawBufferPointer(rebasing: bytes[SolStream.headerLength...])
        let message = try decodePayload(opcode, payload)
        return (header, message)
    }

    private static func exact(_ opcode: SolStream.Opcode, _ payload: UnsafeRawBufferPointer, _ sizes: [Int]) throws {
        if !sizes.contains(payload.count) {
            throw CodecError.badPayload(opcode: opcode.rawValue, reason: "payload is \(payload.count) bytes, expected \(sizes)")
        }
    }

    private static func decodePayload(_ opcode: SolStream.Opcode, _ payload: UnsafeRawBufferPointer) throws -> Message {
        var r = ByteReader(payload)
        let op = opcode.rawValue
        switch opcode {
        case .handshake:
            if payload.count < 14 { throw CodecError.badPayload(opcode: op, reason: "handshake shorter than 14 bytes") }
            let cw = try r.f32()
            let ch = try r.f32()
            let dpi = try r.f32()
            let nameLength16 = try r.u16()
            let nameLength = Int(nameLength16)
            if nameLength < 1 || nameLength > SolStream.maxNameLength {
                throw CodecError.limitExceeded(opcode: op, value: nameLength, max: SolStream.maxNameLength)
            }
            if r.remaining != nameLength {
                throw CodecError.badPayload(opcode: op, reason: "name_len \(nameLength) but \(r.remaining) bytes follow")
            }
            let nameBytes = try r.bytes(nameLength)
            let name = String(decoding: nameBytes, as: UTF8.self)
            return .handshake(canvasWidth: cw, canvasHeight: ch, dpi: dpi, name: name)
        case .handshakeAck:
            try exact(opcode, payload, [16])
            let w = try r.u32()
            let h = try r.u32()
            let fps = try r.u32()
            let raw = try r.u32()
            guard let status = SolStream.AckStatus(rawValue: raw) else {
                throw CodecError.badPayload(opcode: op, reason: "unknown ack status \(raw)")
            }
            return .handshakeAck(width: w, height: h, fps: fps, status: status)
        case .strokeStart:
            try exact(opcode, payload, [25, 31])
            let id = try r.uuid()
            let toolRaw = try r.u8()
            guard let tool = SolStream.Tool(rawValue: toolRaw) else {
                throw CodecError.badPayload(opcode: op, reason: "unknown tool \(toolRaw)")
            }
            let color = try r.u32()
            let width = try r.f32()
            var pointer = SolStream.PointerType.stylus
            var phase = SolStream.Phase.contact
            var pressure: Float = 0.5
            if payload.count == 31 {
                let pr = try r.u8()
                let ph = try r.u8()
                guard let p = SolStream.PointerType(rawValue: pr) else {
                    throw CodecError.badPayload(opcode: op, reason: "unknown pointer type \(pr)")
                }
                guard let q = SolStream.Phase(rawValue: ph) else {
                    throw CodecError.badPayload(opcode: op, reason: "unknown phase \(ph)")
                }
                pointer = p
                phase = q
                pressure = try r.f32()
            }
            return .strokeStart(StrokeStart(id: id, tool: tool, colorARGB: color, baseWidth: width, pointer: pointer, phase: phase, pressure: pressure))
        case .strokeChunk:
            if payload.count < 18 { throw CodecError.badPayload(opcode: op, reason: "chunk shorter than 18 bytes") }
            let id = try r.uuid()
            let count16 = try r.u16()
            let count = Int(count16)
            if count < 1 || count > SolStream.maxPointsPerChunk {
                throw CodecError.limitExceeded(opcode: op, value: count, max: SolStream.maxPointsPerChunk)
            }
            if r.remaining != count * SolStream.pointLength {
                throw CodecError.badPayload(opcode: op, reason: "count \(count) needs \(count * SolStream.pointLength) bytes, have \(r.remaining)")
            }
            var points: [SolStream.Point] = []
            points.reserveCapacity(count)
            for _ in 0..<count {
                let x = try r.i32()
                let y = try r.i32()
                let p = try r.u8()
                let d = try r.u16()
                points.append(SolStream.Point(x32: x, y32: y, pressure: p, deltaMs: d))
            }
            return .strokeChunk(id: id, points: points)
        case .strokeCommit:
            try exact(opcode, payload, [20])
            let id = try r.uuid()
            let pointCount = try r.u32()
            return .strokeCommit(id: id, pointCount: pointCount)
        case .strokeCancel:
            try exact(opcode, payload, [16])
            let id = try r.uuid()
            return .strokeCancel(id: id)
        case .undo:
            try exact(opcode, payload, [24])
            let pageID = try r.uuid()
            let t = try r.u64()
            return .undo(pageID: pageID, clientTimeUs: t)
        case .redo:
            try exact(opcode, payload, [24])
            let pageID = try r.uuid()
            let t = try r.u64()
            return .redo(pageID: pageID, clientTimeUs: t)
        case .eraseStrokes:
            if payload.count < 22 { throw CodecError.badPayload(opcode: op, reason: "erase shorter than 22 bytes") }
            let x1 = try r.f32()
            let y1 = try r.f32()
            let x2 = try r.f32()
            let y2 = try r.f32()
            let radius = try r.f32()
            let count16 = try r.u16()
            let count = Int(count16)
            if count > SolStream.maxErasedPerMessage {
                throw CodecError.limitExceeded(opcode: op, value: count, max: SolStream.maxErasedPerMessage)
            }
            if r.remaining != count * 16 {
                throw CodecError.badPayload(opcode: op, reason: "count \(count) needs \(count * 16) bytes, have \(r.remaining)")
            }
            var ids: [UUID] = []
            ids.reserveCapacity(count)
            for _ in 0..<count {
                let id = try r.uuid()
                ids.append(id)
            }
            return .eraseStrokes(x1: x1, y1: y1, x2: x2, y2: y2, radius: radius, ids: ids)
        case .laserPoint:
            try exact(opcode, payload, [16])
            let x = try r.f32()
            let y = try r.f32()
            let intensity = try r.f32()
            let decayS = try r.f32()
            return .laserPoint(x: x, y: y, intensity: intensity, decayS: decayS)
        case .clearCanvas:
            try exact(opcode, payload, [0, 24])
            if payload.count == 0 { return .clearCanvas(pageID: nil, clientTimeUs: nil) }
            let pageID = try r.uuid()
            let t = try r.u64()
            return .clearCanvas(pageID: pageID, clientTimeUs: t)
        case .pageChange:
            try exact(opcode, payload, [28])
            let pageID = try r.uuid()
            let width = try r.f32()
            let height = try r.f32()
            let index = try r.u32()
            return .pageChange(pageID: pageID, width: width, height: height, index: index)
        case .autoEngageReturn:
            try exact(opcode, payload, [8])
            let t = try r.u64()
            return .autoEngageReturn(clientTimeUs: t)
        case .togglePin:
            try exact(opcode, payload, [9])
            let value = try r.i8()
            if value < -1 || value > 1 {
                throw CodecError.badPayload(opcode: op, reason: "pin value \(value) not in -1...1")
            }
            let t = try r.u64()
            return .togglePin(value: value, clientTimeUs: t)
        case .state:
            // Compatible additions may append fields; read the first 20 bytes (PROTOCOL section 10).
            if payload.count < 20 { throw CodecError.badPayload(opcode: op, reason: "state shorter than 20 bytes") }
            let governor = try r.u8()
            let flags = try r.u8()
            let mode = try r.u8()
            let inkSource = try r.u8()
            let progress = try r.f32()
            let msToReturn = try r.u32()
            let pageIndex = try r.u16()
            let strokeCount = try r.u16()
            let undoDepth = try r.u16()
            let redoDepth = try r.u16()
            return .state(StateReport(
                governor: governor, flags: flags, mode: mode, inkSource: inkSource,
                progress: progress, msToReturn: msToReturn,
                pageIndex: pageIndex, strokeCount: strokeCount, undoDepth: undoDepth, redoDepth: redoDepth))
        case .ping:
            try exact(opcode, payload, [16])
            let sequence = try r.u64()
            let t = try r.u64()
            return .ping(sequence: sequence, clientTimeUs: t)
        case .pong:
            try exact(opcode, payload, [16])
            let sequence = try r.u64()
            let t = try r.u64()
            return .pong(sequence: sequence, clientTimeUs: t)
        }
    }
}
