import Foundation

/// Finds this Mac's Tailscale address without asking Tailscale: the IPv4 address in 100.64.0.0/10 on a
/// tunnel interface. The relay binds only there, so nothing on the LAN or the internet can reach it.
public enum Tailscale {
    /// This Mac's Tailscale IPv4, or nil. An address counts only if it's in 100.64.0.0/10 on a tunnel (utun)
    /// interface that also carries Tailscale's own IPv6 prefix (fd7a:115c:a1e0::/48), or if Tailscale's CLI lists
    /// it as this device's address. Other 100.64/10 users (Cloudflare WARP, carrier NAT, corporate VPNs) are never
    /// mistaken for Tailscale, and there's no fallback to Wi-Fi or Ethernet.
    public static func ipv4() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var v4: [String: String] = [:]      // interface -> 100.64/10 address
        var tailscaleV6: Set<String> = []   // interfaces with an fd7a:115c:a1e0::/48 address
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            defer { p = i.pointee.ifa_next }
            let name = String(cString: i.pointee.ifa_name)
            guard name.hasPrefix("utun"), let sa = i.pointee.ifa_addr, i.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            if sa.pointee.sa_family == UInt8(AF_INET) {
                var a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                guard UInt32(bigEndian: a.s_addr) & 0xFFC0_0000 == 0x6440_0000 else { continue } // 100.64.0.0/10
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
                v4[name] = String(cString: buf)
            } else if sa.pointee.sa_family == UInt8(AF_INET6) {
                let b = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s in withUnsafeBytes(of: s.pointee.sin6_addr) { Array($0) } }
                if b.starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]) { tailscaleV6.insert(name) }
            }
        }
        if let (_, ip) = v4.first(where: { tailscaleV6.contains($0.key) }) { return ip }
        // No IPv6 marker (Tailscale with IPv6 off): accept only an address the Tailscale CLI vouches for.
        guard !v4.isEmpty, let confirmed = selfIPsFromCLI() else { return nil }
        return v4.values.first { confirmed.contains($0) }
    }

    /// `tailscale status --json` → Self.TailscaleIPs. Blocking, 3 s.
    static func selfIPsFromCLI() -> Set<String>? {
        guard let me = cliStatusSelf() else { return nil }
        return Set((me["TailscaleIPs"] as? [String]) ?? [])
    }

    /// The MagicDNS name for an address (e.g. "mac.tail1234.ts.net"), by reverse lookup. Blocking.
    public static func reverseName(_ ip: String) -> String? {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &sin.sin_addr) == 1 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &buf, socklen_t(buf.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0 else { return nil }
        var name = String(cString: buf).lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty || name == ip ? nil : name
    }

    static let cliPaths = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                           "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]

    /// This Mac's MagicDNS name from `tailscale status --json` (fallback when reverse DNS is off). Blocking, 3 s.
    public static func dnsNameFromCLI() -> String? {
        guard var name = cliStatusSelf()?["DNSName"] as? String else { return nil }
        while name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty ? nil : name.lowercased()
    }

    /// The "Self" object of `tailscale status --json`, run with a fixed path, fixed arguments and a 3 s limit.
    static func cliStatusSelf() -> [String: Any]? {
        guard let cli = cliPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["status", "--json", "--self=true", "--peers=false"]
        p.environment = ["PATH": "/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard let obj = try? JSONSerialization.jsonObject(with: data.prefix(4 * 1024 * 1024)) as? [String: Any] else { return nil }
        return obj["Self"] as? [String: Any]
    }

    /// A short, friendly name for a peer address ("linux-box" from "linux-box.tail1234.ts.net"). Blocking.
    public static func peerName(_ ip: String) -> String? {
        reverseName(ip).map { String($0.split(separator: ".").first ?? Substring($0)) }
    }
}
