import Foundation

/// The strokes JSON written next to each page PNG (SPEC section 12). Skeleton shape; filled in M3.
public struct PageDocument: Codable, Equatable {
    public struct Point: Codable, Equatable {
        public var x: Double
        public var y: Double
        public var p: Double
        public var t: Int
    }

    public struct StrokeRecord: Codable, Equatable {
        public var id: String
        public var tool: String
        public var color: String
        public var width: Double
        public var points: [Point]
    }

    public var version: Int = 1
    public var app: String = "daylight"
    public var pageID: String
    public var pageIndex: Int
    public var canvasWidth: Int
    public var canvasHeight: Int
    public var sessionStart: String
    public var savedAt: String
    public var reason: SaveReason
    public var inkSource: String
    public var clientLabel: String
    public var strokes: [StrokeRecord]

    public init(pageID: String, pageIndex: Int, canvasWidth: Int, canvasHeight: Int, sessionStart: String, savedAt: String, reason: SaveReason, inkSource: String, clientLabel: String, strokes: [StrokeRecord]) {
        self.pageID = pageID
        self.pageIndex = pageIndex
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.sessionStart = sessionStart
        self.savedAt = savedAt
        self.reason = reason
        self.inkSource = inkSource
        self.clientLabel = clientLabel
        self.strokes = strokes
    }
}
