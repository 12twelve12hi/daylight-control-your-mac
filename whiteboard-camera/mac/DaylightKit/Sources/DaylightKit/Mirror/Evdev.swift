import Foundation

public struct EvdevEvent: Equatable {
    public var tsUs: UInt64
    public var type: String
    public var code: String
    public var value: String

    public init(tsUs: UInt64, type: String, code: String, value: String) {
        self.tsUs = tsUs
        self.type = type
        self.code = code
        self.value = value
    }
}

/// Parses `adb shell getevent -lt` output lines. Lands in M5.
public struct EvdevParser {
    private var pending: [UInt8] = []
    public init() {}

    public mutating func feed(_ bytes: UnsafeRawBufferPointer, emit: (EvdevEvent) -> Void) {
        pending.append(contentsOf: bytes)
    }
}

public struct StylusSample: Equatable {
    public var inRange = false
    public var eraserInRange = false
    public var touching = false
    public var side1 = false
    public var side2 = false
    public var pressure: Double = 0
    public var x = 0
    public var y = 0
    public var tsUs: UInt64 = 0
    public init() {}
}

public enum StylusTransition: Equatable {
    case contactDown(StylusSample)
    case contactUp(StylusSample)
    case eraserDown(StylusSample)
    case eraserUp(StylusSample)
    case side1Down(tsUs: UInt64)
    case side1Up(tsUs: UInt64)
    case side2Down(tsUs: UInt64)
    case side2Up(tsUs: UInt64)
}

public enum SideButtonGesture: Equatable {
    case doublePress
    case longPress
}

public struct AdbDevice: Equatable {
    public var serial: String
    public var state: String
    public var model: String?
    public var product: String?
    public var transportID: Int?

    public init(serial: String, state: String, model: String? = nil, product: String? = nil, transportID: Int? = nil) {
        self.serial = serial
        self.state = state
        self.model = model
        self.product = product
        self.transportID = transportID
    }

    public var isUSB: Bool { return !serial.contains(":") }
}

public struct CropInsets: Equatable, Codable {
    public var top: Int
    public var left: Int
    public var right: Int
    public var bottom: Int

    public init(top: Int = 0, left: Int = 0, right: Int = 0, bottom: Int = 0) {
        self.top = top
        self.left = left
        self.right = right
        self.bottom = bottom
    }

    /// UV fractions of the current session frame that show the cropped native region.
    public func uv(sessionWidth: Int, sessionHeight: Int, nativeWidth: Int, nativeHeight: Int) -> UVRect {
        guard nativeWidth > 0, nativeHeight > 0 else { return .full }
        return UVRect(
            u0: Double(left) / Double(nativeWidth),
            v0: Double(top) / Double(nativeHeight),
            u1: 1 - Double(right) / Double(nativeWidth),
            v1: 1 - Double(bottom) / Double(nativeHeight))
    }

    public func croppedAspect(nativeWidth: Int, nativeHeight: Int) -> Double {
        let w = Double(nativeWidth - left - right)
        let h = Double(nativeHeight - top - bottom)
        return h > 0 ? w / h : 0.75
    }
}
