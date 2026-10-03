import Foundation

/// The exact adb command lines that start scrcpy-server 4.1 (SPEC F2, ARCHITECTURE 6 item 3, research-scrcpy-adb 1.3).
/// Pure data so the mac `ScrcpySession` and the Linux tests share one spelling.
public struct ScrcpyLaunch: Equatable {
    public static let serverVersion = "4.1"
    public static let remoteServerPath = "/data/local/tmp/scrcpy-server.jar"
    public static let socketName = "scrcpy"
    public static let defaultLocalPort: UInt16 = 27183
    public static let lastLocalPort: UInt16 = 27199
    /// scrcpy reads the dummy byte with 100 attempts of 100 ms (`server.c:489-539`).
    public static let dummyByteAttempts = 100
    public static let dummyByteRetryInterval: Double = 0.1
    /// `[server] ERROR: ` lines on stderr are failure row 25.
    public static let serverErrorPrefix = "[server] ERROR:"

    public var serial: String
    public var maxSize: Int
    public var bitRate: Int
    public var maxFps: Int
    public var localPort: UInt16

    public init(serial: String, maxSize: Int = 1600, bitRate: Int = 8_000_000, maxFps: Int = 30, localPort: UInt16 = ScrcpyLaunch.defaultLocalPort) {
        self.serial = serial
        self.maxSize = maxSize
        self.bitRate = bitRate
        self.maxFps = maxFps
        self.localPort = localPort
    }

    /// `adb -s S push <server> /data/local/tmp/scrcpy-server.jar`
    public func pushArguments(serverPath: String) -> [String] {
        return ["-s", serial, "push", serverPath, ScrcpyLaunch.remoteServerPath]
    }

    /// `adb -s S forward tcp:PORT localabstract:scrcpy`
    public var forwardArguments: [String] {
        return ["-s", serial, "forward", "tcp:\(localPort)", "localabstract:\(ScrcpyLaunch.socketName)"]
    }

    /// `adb -s S forward --remove tcp:PORT`
    public var forwardRemoveArguments: [String] {
        return ["-s", serial, "forward", "--remove", "tcp:\(localPort)"]
    }

    /// The server options after the version, in SPEC F2 order.
    public var serverOptions: [String] {
        return [
            "log_level=info",
            "tunnel_forward=true",
            "video=true",
            "audio=false",
            "control=false",
            "cleanup=false",
            "video_codec=h264",
            "max_size=\(maxSize)",
            "video_bit_rate=\(bitRate)",
            "max_fps=\(maxFps)",
            "send_device_meta=true",
            "send_frame_meta=true",
            "send_stream_meta=true",
            "send_dummy_byte=true",
        ]
    }

    /// `adb -s S shell CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 4.1 <options>`
    public var shellArguments: [String] {
        return ["-s", serial, "shell", "CLASSPATH=\(ScrcpyLaunch.remoteServerPath)", "app_process", "/", "com.genymobile.scrcpy.Server", ScrcpyLaunch.serverVersion] + serverOptions
    }

    /// The whole shell line as one string (for logs and diagnostics).
    public var shellCommandLine: String {
        return shellArguments.joined(separator: " ")
    }

    /// Option values pass through the device shell unquoted: scrcpy refuses these characters (`server.c:193-206`).
    public static func isSafeOptionValue(_ value: String) -> Bool {
        let forbidden: Set<Character> = [" ", ";", "'", "\"", "*", "$", "?", "&", "`", "#", "\\", "|", "<", ">", "[", "]", "{", "}", "(", ")", "!", "~", "\r", "\n"]
        return !value.contains(where: { forbidden.contains($0) })
    }
}
