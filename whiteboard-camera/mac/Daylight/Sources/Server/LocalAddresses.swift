import Darwin
import Foundation

/// IPv4 addresses the owner can type into the tablet (SPEC 9.2): Tailscale (`utun*` in 100.64.0.0/10) first, then
/// Wi-Fi and Ethernet (`en*`); loopback, link-local, AWDL, bridges and other tunnels are skipped.
enum LocalAddresses {
    enum Kind: Equatable {
        case tailscale
        case wifiOrEthernet
    }

    struct Entry: Equatable {
        let ip: String
        let interface: String
        let kind: Kind
    }

    static func list() -> [Entry] {
        var raw: [(String, String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let flags = Int32(entry.pointee.ifa_flags)
            if let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    raw.append((String(cString: entry.pointee.ifa_name), String(cString: host)))
                }
            }
            cursor = entry.pointee.ifa_next
        }
        return classify(raw)
    }

    /// Pure part, unit-tested: interface name plus dotted IPv4 to an ordered list.
    static func classify(_ raw: [(interface: String, ip: String)]) -> [Entry] {
        var tailscale: [Entry] = []
        var lan: [Entry] = []
        for (name, ip) in raw {
            if ip.hasPrefix("169.254.") || ip.hasPrefix("127.") { continue }
            if name.hasPrefix("utun") {
                if isTailscale(ip) { tailscale.append(Entry(ip: ip, interface: name, kind: .tailscale)) }
                continue
            }
            if name.hasPrefix("en") {
                lan.append(Entry(ip: ip, interface: name, kind: .wifiOrEthernet))
            }
        }
        return tailscale + lan
    }

    /// 100.64.0.0/10: first octet 100, second octet 64...127.
    static func isTailscale(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127
    }

    /// "http://100.101.102.103:7788" for the first entry, or nil.
    static func primaryURL(port: UInt16, entries: [Entry]? = nil) -> String? {
        guard let first = (entries ?? list()).first else { return nil }
        return "http://\(first.ip):\(port)"
    }

    static func hostname() -> String {
        let name = ProcessInfo.processInfo.hostName
        if let dot = name.firstIndex(of: ".") { return String(name[..<dot]) }
        return name
    }
}
