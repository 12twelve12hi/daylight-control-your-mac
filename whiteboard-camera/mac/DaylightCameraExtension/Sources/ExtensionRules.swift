import Foundation

/// How the extension drains its sink stream (SPEC D33, ARCHITECTURE 2.4 item 1).
/// `.timer90Hz` is the OBS shape: a strict timer at three times the frame rate calls `consumeSampleBuffer` only while
/// the sink is started. `.recursive` is the ldenoue shape: the completion handler re-arms the next consume at once.
/// The semantics of a consume on an empty queue are UNVERIFIED (LOOSE_ENDS E1), which is why the timer is the default.
enum ConsumeStrategy {
    case timer90Hz
    case recursive
}

/// The numbers and rules of the Daylight camera extension in one place. Foundation only, so the same file can be
/// compiled into DaylightTests to pin the values (handoff request C1).
enum DaylightExtensionRules {
    /// Compile-time choice of the sink consume loop (SPEC D33).
    static let consumeStrategy: ConsumeStrategy = .timer90Hz

    /// SPEC D1: 1920x1080 at 30 fps.
    static let frameRate: Int = 30
    static let frameWidth: Int32 = 1920
    static let frameHeight: Int32 = 1080

    /// OBS consumes at three times the frame rate: 90 Hz (SPEC D33).
    static let consumeRateMultiplier: Int = 3
    static var consumeHz: Int { return frameRate * consumeRateMultiplier }
    static var consumeInterval: Double { return 1.0 / Double(consumeHz) }

    /// Only the host app may feed the sink (SPEC C3). A nil signing identifier (unsigned caller) is let through so an
    /// unsigned development build of the host is not locked out; the extension itself never loads unsigned anyway.
    static let hostSigningID = "com.twelve.daylight"

    /// Custom source-stream property that publishes the number of streaming viewers (ARCHITECTURE 2.4 item 2).
    /// Four-character code `dlvw`, global scope, element 0, in the CMIOExtension spelling.
    static let viewersPropertyName = "4cc_dlvw_glob_0000"
    static let viewersPropertyFourCC = "dlvw"

    /// SPEC 4: the only text the extension ever draws, and only while no host is connected and a viewer streams.
    static let placeholderText = "Daylight is not running. Open Daylight from the menu bar."

    /// Design tokens used by the placeholder card (SPEC 3), as 0xRRGGBB.
    static let surfaceCream: UInt32 = 0xEAE5DC
    static let paperBg: UInt32 = 0xFAF8F5
    static let borderSubtle: UInt32 = 0xCDC6B8
    static let inkBlack: UInt32 = 0x111111
    static let textMuted: UInt32 = 0x736F68

    /// `authorizedToStartStream(for:)` on the sink.
    static func authorizesSink(signingID: String?) -> Bool {
        guard let signingID = signingID else { return true }
        return signingID == hostSigningID
    }

    /// The placeholder card is drawn only while the host is absent and somebody is watching (SPEC C3).
    static func drawsPlaceholder(sinkStarted: Bool, streamingCounter: UInt32) -> Bool {
        return !sinkStarted && streamingCounter > 0
    }

    /// A consumed sink buffer is forwarded to the source stream only when a viewer streams (ARCHITECTURE 2.4 item 4).
    static func forwardsSinkFrames(streamingCounter: UInt32) -> Bool {
        return streamingCounter > 0
    }

    /// The value published through the viewers property: the decimal streaming counter as a string. A string is the
    /// one custom-property value type whose host-side read is verified by a shipping app (ldenoue `4cc_just_glob_0000`
    /// returns "sc=1"); the host parses the trailing digits, so "sc=1" and "1" both decode.
    static func viewersPropertyValue(streamingCounter: UInt32) -> String {
        return "sc=\(streamingCounter)"
    }
}
