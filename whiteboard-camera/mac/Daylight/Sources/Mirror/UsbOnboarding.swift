import DaylightKit
import Foundation

/// The USB onboarding command lists (SPEC 9.2 step 1, 9.3 step 1, 9.4 step 2) as data plus a sequential runner.
/// Component names come from the Android manifest (E handoff): `.ui.MainActivity`, `.overlay.OverlayService`.
enum UsbOnboarding {
    static let inkPackage = "com.twelve.daylight.ink"
    static let mainActivity = "\(inkPackage)/.ui.MainActivity"
    static let overlayService = "\(inkPackage)/.overlay.OverlayService"
    static let commandTimeout: Double = 120

    /// `adb -s S reverse tcp:P tcp:P`, then `am start -a android.intent.action.VIEW -d http://localhost:P`.
    static func openWebCommands(serial: String, port: UInt16) -> [[String]] {
        return [
            ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"],
            ["-s", serial, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", "http://localhost:\(port)"],
        ]
    }

    /// `adb install` flags: `-r` replaces the installed app, `-d` allows a version downgrade (every CI APK is the debug
    /// variant, where Android permits it), so a tablet carrying a newer sideload still takes the build inside this Mac app.
    static let installFlags = ["-r", "-d"]

    /// The tablet always dials `127.0.0.1:7788` (the APK's fixed loopback candidate), so the reverse maps the tablet's
    /// 7788 onto whatever port the Mac listener bound (7788 to 7799, SPEC 11 and failure row 16).
    static func reverseCommand(serial: String, port: UInt16) -> [String] {
        return ["-s", serial, "reverse", "tcp:\(SolStream.defaultPort)", "tcp:\(port)"]
    }

    /// The `--es host` value: `host:port`, or `[v6]:port`, so the remembered wireless candidate carries the bound port
    /// (the APK's `Candidates.url` parses both forms).
    static func hostArgument(_ host: String, port: UInt16) -> String {
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Install, grant the overlay and notification permissions, reverse the port, start the activity (with `--es host`
    /// when known), and with `pills` start the overlay service.
    static func installInkCommands(serial: String, apkPath: String, port: UInt16, host: String?, pills: Bool, pillsPosition: PillsPosition) -> [[String]] {
        var commands: [[String]] = [
            ["-s", serial, "install"] + installFlags + [apkPath],
            ["-s", serial, "shell", "appops", "set", inkPackage, "SYSTEM_ALERT_WINDOW", "allow"],
            ["-s", serial, "shell", "pm", "grant", inkPackage, "android.permission.POST_NOTIFICATIONS"],
            reverseCommand(serial: serial, port: port),
        ]
        var start = ["-s", serial, "shell", "am", "start", "-n", mainActivity]
        if let host = host, !host.isEmpty { start += ["--es", "host", hostArgument(host, port: port)] }
        commands.append(start)
        if pills { commands.append(startPillsCommand(serial: serial, position: pillsPosition, host: host, port: port)) }
        return commands
    }

    /// `am start-foreground-service -n com.twelve.daylight.ink/.overlay.OverlayService --es pills top|bottom [--es host H:P]`.
    static func startPillsCommand(serial: String, position: PillsPosition, host: String?, port: UInt16) -> [String] {
        var command = ["-s", serial, "shell", "am", "start-foreground-service", "-n", overlayService, "--es", "pills", position.rawValue]
        if let host = host, !host.isEmpty { command += ["--es", "host", hostArgument(host, port: port)] }
        return command
    }

    /// Mirror mode's pills (SPEC 9.4 step 2): install and grant as for the native app, reverse the port, start only the
    /// overlay service (the note app stays in front).
    static func mirrorPillsCommands(serial: String, apkPath: String, port: UInt16, pillsPosition: PillsPosition) -> [[String]] {
        return [
            ["-s", serial, "install"] + installFlags + [apkPath],
            ["-s", serial, "shell", "appops", "set", inkPackage, "SYSTEM_ALERT_WINDOW", "allow"],
            ["-s", serial, "shell", "pm", "grant", inkPackage, "android.permission.POST_NOTIFICATIONS"],
            reverseCommand(serial: serial, port: port),
            startPillsCommand(serial: serial, position: pillsPosition, host: nil, port: port),
        ]
    }

    static func openWeb(adb: AdbRunning, serial: String, port: UInt16, completion: @escaping (Result<Void, Error>) -> Void) {
        runSequence(adb: adb, commands: openWebCommands(serial: serial, port: port), completion: completion)
    }

    static func installInk(adb: AdbRunning, serial: String, apk: URL, port: UInt16 = SolStream.defaultPort, host: String?, pills: Bool, pillsPosition: PillsPosition = .top, completion: @escaping (Result<Void, Error>) -> Void) {
        runSequence(adb: adb, commands: installInkCommands(serial: serial, apkPath: apk.path, port: port, host: host, pills: pills, pillsPosition: pillsPosition), completion: completion)
    }

    static func startMirrorPills(adb: AdbRunning, serial: String, apk: URL, port: UInt16, pillsPosition: PillsPosition, completion: @escaping (Result<Void, Error>) -> Void) {
        runSequence(adb: adb, commands: mirrorPillsCommands(serial: serial, apkPath: apk.path, port: port, pillsPosition: pillsPosition), completion: completion)
    }

    /// Runs the commands in order; the first non-zero exit stops the sequence with `AdbError.failed`.
    static func runSequence(adb: AdbRunning, commands: [[String]], index: Int = 0, completion: @escaping (Result<Void, Error>) -> Void) {
        guard index < commands.count else {
            completion(.success(()))
            return
        }
        let command = commands[index]
        adb.run(command, timeout: commandTimeout) { result in
            switch result {
            case let .success(output) where output.succeeded:
                runSequence(adb: adb, commands: commands, index: index + 1, completion: completion)
            case let .success(output):
                completion(.failure(AdbError.failed(status: output.status, detail: output.errorSummary, command: command.joined(separator: " "))))
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }
}
