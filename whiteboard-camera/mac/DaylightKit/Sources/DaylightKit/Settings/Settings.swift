import Foundation

/// Persisted user settings (SPEC section 11). Skeleton: the keys that the skeleton app and tests need.
public struct Settings: Codable, Equatable {
    public static let userDefaultsKey = "com.twelve.daylight.settings.v1"

    public var inkSource: UInt8 = InkSource.web.rawValue
    public var layout: UInt8 = LayoutStyle.studioSplit.rawValue
    public var idleTimeoutSeconds: Double = 90
    public var preWarningLeadSeconds: Double = 5
    public var port: UInt16 = SolStream.defaultPort
    public var trustLoopback: Bool = true
    public var engageOnEraser: Bool = false
    public var mirrorPillsEnabled: Bool = true
    public var viewerIdleStopSeconds: Double = 60

    public init() {}

    public static let defaults = Settings()

    /// Clamps every value into its legal range.
    public func validated() -> Settings {
        var s = self
        s.idleTimeoutSeconds = min(max(s.idleTimeoutSeconds, 10), 3600)
        s.preWarningLeadSeconds = min(max(s.preWarningLeadSeconds, 1), s.idleTimeoutSeconds - 1)
        if s.port < 1024 { s.port = SolStream.defaultPort }
        s.viewerIdleStopSeconds = min(max(s.viewerIdleStopSeconds, 5), 3600)
        return s
    }
}
