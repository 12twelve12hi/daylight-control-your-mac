import Foundation

/// The strokes JSON written next to each page PNG (SPEC section 12, schema `daylight-whiteboard-strokes/1`).
/// Encode with a `JSONEncoder` whose `outputFormatting` includes `.sortedKeys` (the app configures it).
public struct PageDocument: Codable, Equatable {
    public static let schemaName = "daylight-whiteboard-strokes/1"

    public struct Canvas: Codable, Equatable {
        public var width: Int
        public var height: Int
        public var dpi: Int
        public var units: String

        public init(width: Int = 1200, height: Int = 1600, dpi: Int = 200, units: String = "canvas") {
            self.width = width
            self.height = height
            self.dpi = dpi
            self.units = units
        }
    }

    public struct Session: Codable, Equatable {
        /// ISO 8601, e.g. "2026-10-03T14:05:09Z".
        public var started: String
        public var saved: String
        public var reason: SaveReason
        public var inkSource: String
        public var clientLabel: String

        public init(started: String, saved: String, reason: SaveReason, inkSource: String, clientLabel: String) {
            self.started = started
            self.saved = saved
            self.reason = reason
            self.inkSource = inkSource
            self.clientLabel = clientLabel
        }
    }

    public struct Page: Codable, Equatable {
        public var id: String
        /// 1-based, like the file name `page-01`.
        public var index: Int

        public init(id: String, index: Int) {
            self.id = id
            self.index = index
        }
    }

    /// One point encoded as the JSON array `[x, y, pressure, tMs]`; `tMs` is milliseconds since the first point.
    public struct Point: Codable, Equatable {
        public var x: Double
        public var y: Double
        public var pressure: Double
        public var tMs: Int

        public init(x: Double, y: Double, pressure: Double, tMs: Int) {
            self.x = x
            self.y = y
            self.pressure = pressure
            self.tMs = tMs
        }

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            x = try c.decode(Double.self)
            y = try c.decode(Double.self)
            pressure = try c.decode(Double.self)
            let t = try c.decode(Double.self)
            tMs = Int(t.rounded())
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(x)
            try c.encode(y)
            try c.encode(pressure)
            try c.encode(tMs)
        }
    }

    public struct StrokeRecord: Codable, Equatable {
        public var id: String
        /// "pen", "highlighter", "eraser" or "lasso".
        public var tool: String
        /// "#AARRGGBB", e.g. "#FF111111".
        public var color: String
        public var baseWidth: Double
        public var points: [Point]

        public init(id: String, tool: String, color: String, baseWidth: Double, points: [Point]) {
            self.id = id
            self.tool = tool
            self.color = color
            self.baseWidth = baseWidth
            self.points = points
        }
    }

    public var schema: String
    /// "Daylight <version> (<build>)".
    public var app: String
    public var canvas: Canvas
    public var session: Session
    public var page: Page
    public var strokes: [StrokeRecord]

    public init(schema: String = PageDocument.schemaName, app: String, canvas: Canvas, session: Session, page: Page, strokes: [StrokeRecord]) {
        self.schema = schema
        self.app = app
        self.canvas = canvas
        self.session = session
        self.page = page
        self.strokes = strokes
    }

    /// "2026-10-03T14:05:09Z".
    public static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    public static func toolName(_ tool: SolStream.Tool) -> String {
        switch tool {
        case .pen: return "pen"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        }
    }

    public static func tool(named name: String) -> SolStream.Tool? {
        switch name {
        case "pen": return .pen
        case "highlighter": return .highlighter
        case "eraser": return .eraser
        case "lasso": return .lasso
        default: return nil
        }
    }

    /// "#FF111111" for 0xFF111111.
    public static func colorString(_ argb: UInt32) -> String {
        let hex = String(argb, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: max(0, 8 - hex.count)) + hex
    }

    /// Parses "#AARRGGBB" (and "#RRGGBB" as opaque).
    public static func colorValue(_ text: String) -> UInt32? {
        var hex = text
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard let v = UInt32(hex, radix: 16) else { return nil }
        if hex.count == 6 { return 0xFF00_0000 | v }
        if hex.count == 8 { return v }
        return nil
    }

    /// The strokes converted back into `Stroke` values (canvas units); used by tests and by a future reopen.
    public func strokeValues() -> [Stroke] {
        var out: [Stroke] = []
        for record in strokes {
            guard let id = UUID(uuidString: record.id), let tool = PageDocument.tool(named: record.tool),
                  let color = PageDocument.colorValue(record.color) else { continue }
            var s = Stroke(id: id, style: StrokeStyle(tool: tool, colorARGB: color, baseWidth: Float(record.baseWidth)))
            s.append(record.points.map { SolStream.Point(x: $0.x, y: $0.y, pressure: $0.pressure, deltaMs: $0.tMs) })
            s.isCommitted = true
            out.append(s)
        }
        return out
    }
}
