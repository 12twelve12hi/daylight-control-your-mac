import DaylightKit
import Foundation
import os

/// The cable-free interim of SPEC D42 (ARCHITECTURE 6 item 9): after a USB session remember the tablet's Wi-Fi IPv4
/// from `adb shell ip route` and run `adb tcpip 5555`; later, with no USB device listed and the toggle on, try
/// `adb connect <ip>:5555` and judge success from stdout (`adb connect` exits 0 on failure).
final class WifiMirror {
    static let log = Logger(subsystem: "com.twelve.daylight", category: "adb")
    static let port: UInt16 = 5555
    static let rememberedIPKey = "com.twelve.daylight.mirror.wifi-ip"

    let adb: AdbRunning
    let queue: DispatchQueue
    let defaults: UserDefaults?
    var onLog: ((String) -> Void)?
    private let lock = NSLock()
    private var ip: String?

    init(adb: AdbRunning, queue: DispatchQueue, defaults: UserDefaults? = .standard) {
        self.adb = adb
        self.queue = queue
        self.defaults = defaults
        ip = defaults?.string(forKey: WifiMirror.rememberedIPKey)
    }

    var rememberedIP: String? {
        lock.lock()
        defer { lock.unlock() }
        return ip
    }

    private func remember(_ address: String?) {
        lock.lock()
        ip = address
        lock.unlock()
        if let address = address {
            defaults?.set(address, forKey: WifiMirror.rememberedIPKey)
        } else {
            defaults?.removeObject(forKey: WifiMirror.rememberedIPKey)
        }
    }

    /// `ip route` output -> the `src` address of the Wi-Fi route (a `wlan` line first, else the first line with `src`).
    static func parseRouteSourceIP(_ output: String) -> String? {
        var fallback: String?
        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let tokens = line.split(separator: " ").map(String.init)
            guard let srcIndex = tokens.firstIndex(of: "src"), srcIndex + 1 < tokens.count else { continue }
            let address = tokens[srcIndex + 1]
            guard isIPv4(address) else { continue }
            if line.contains("wlan") { return address }
            if fallback == nil { fallback = address }
        }
        return fallback
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let value = Int(part), (0...255).contains(value) else { return false }
        }
        return true
    }

    /// `adb connect` prints `connected to <ip>:5555` or `already connected to ...` on success and `failed to connect
    /// to ...` or `unable to connect ...` on failure, always with exit status 0.
    static func connectSucceeded(_ stdout: String) -> Bool {
        let text = stdout.lowercased()
        return text.contains("connected to") || text.contains("already connected")
    }

    /// After a USB session: record the IPv4 and switch adbd to TCP mode so a later `connect` works without the cable.
    func rememberAfterUSBSession(serial: String, completion: ((String?) -> Void)? = nil) {
        adb.run(["-s", serial, "shell", "ip", "route"], timeout: 15) { [weak self] result in
            guard let self = self else { return }
            guard case let .success(output) = result, let address = WifiMirror.parseRouteSourceIP(output.stdoutText) else {
                self.onLog?("ip route gave no Wi-Fi address; Wi-Fi mirroring stays unavailable")
                completion?(nil)
                return
            }
            self.remember(address)
            self.adb.run(["-s", serial, "tcpip", "\(WifiMirror.port)"], timeout: 15) { tcpipResult in
                switch tcpipResult {
                case let .success(tcpip) where tcpip.succeeded:
                    self.onLog?("remembered \(address) for Wi-Fi mirroring; adbd now listens on \(WifiMirror.port)")
                    completion?(address)
                case let .success(tcpip):
                    self.onLog?("adb tcpip \(WifiMirror.port) failed: \(tcpip.errorSummary)")
                    completion?(address)
                case let .failure(error):
                    self.onLog?("adb tcpip \(WifiMirror.port) failed: \(error)")
                    completion?(address)
                }
            }
        }
    }

    /// `adb connect <ip>:5555`; false (row 32) when nothing is remembered or stdout does not say connected.
    func tryConnect(completion: @escaping (Bool) -> Void) {
        guard let address = rememberedIP else {
            onLog?(FailureText.logLine(.wifiMirrorFailed, ["<none>", "no remembered address"]))
            completion(false)
            return
        }
        adb.run(["connect", "\(address):\(WifiMirror.port)"], timeout: 15) { [weak self] result in
            switch result {
            case let .success(output):
                let ok = output.succeeded && WifiMirror.connectSucceeded(output.stdoutText)
                self?.onLog?(FailureText.logLine(.wifiMirrorFailed, [address, output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)]))
                completion(ok)
            case let .failure(error):
                self?.onLog?(FailureText.logLine(.wifiMirrorFailed, [address, "\(error)"]))
                completion(false)
            }
        }
    }

    func forget() {
        remember(nil)
    }
}
