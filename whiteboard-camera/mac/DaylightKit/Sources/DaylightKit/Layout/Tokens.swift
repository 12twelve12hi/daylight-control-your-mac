import Foundation

public struct RGBA: Equatable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public init(hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = alpha
    }
}

/// SolOS design tokens.
public enum Tokens {
    public static let inkBlack = RGBA(hex: 0x111111)
    public static let paperBg = RGBA(hex: 0xFAF8F5)
    public static let surfaceCream = RGBA(hex: 0xEAE5DC)
    public static let borderSubtle = RGBA(hex: 0xCDC6B8)
    public static let amber = RGBA(hex: 0xD97706)
    public static let amberDeep = RGBA(hex: 0xC87D20)
    public static let terracotta = RGBA(hex: 0x9C271D)
    public static let textMuted = RGBA(hex: 0x736F68)
}
