import Foundation

public struct PixelRect: Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public struct UVRect: Equatable {
    public var u0: Double
    public var v0: Double
    public var u1: Double
    public var v1: Double

    public init(u0: Double, v0: Double, u1: Double, v1: Double) {
        self.u0 = u0
        self.v0 = v0
        self.u1 = u1
        self.v1 = v1
    }

    public static let full = UVRect(u0: 0, v0: 0, u1: 1, v1: 1)
}

public struct QuadSpec: Equatable {
    public var dest: PixelRect
    public var uv: UVRect

    public init(dest: PixelRect, uv: UVRect) {
        self.dest = dest
        self.uv = uv
    }
}
