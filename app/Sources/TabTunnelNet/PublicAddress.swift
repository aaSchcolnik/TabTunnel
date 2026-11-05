import Foundation

/// Decides whether an IP address is on the public internet. Everything else is refused for favicon fetching:
/// loopback, private LAN, link-local, CGNAT (which includes every Tailscale address), ULA, multicast,
/// documentation and reserved ranges, and IPv4 smuggled inside IPv6.
public enum PublicAddress {
    public static func isPublic(_ ip: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            return isPublicV4(UInt32(bigEndian: v4.s_addr))
        }
        var v6 = in6_addr()
        let bare = ip.split(separator: "%").first.map(String.init) ?? ip
        if inet_pton(AF_INET6, bare, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            return isPublicV6(b)
        }
        return false
    }

    static func isPublicV4(_ a: UInt32) -> Bool {
        func inNet(_ net: UInt32, _ bits: UInt32) -> Bool {
            let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
            return a & mask == net & mask
        }
        let blocked: [(UInt32, UInt32)] = [
            (0x0000_0000, 8),   // 0.0.0.0/8 "this network"
            (0x0A00_0000, 8),   // 10/8
            (0x6440_0000, 10),  // 100.64/10 CGNAT, Tailscale
            (0x7F00_0000, 8),   // loopback
            (0xA9FE_0000, 16),  // link-local (and cloud metadata 169.254.169.254)
            (0xAC10_0000, 12),  // 172.16/12
            (0xC000_0000, 24),  // 192.0.0/24 IETF
            (0xC000_0200, 24),  // TEST-NET-1
            (0xC058_6300, 24),  // 6to4 relay anycast
            (0xC0A8_0000, 16),  // 192.168/16
            (0xC612_0000, 15),  // benchmarking
            (0xC633_6400, 24),  // TEST-NET-2
            (0xCB00_7100, 24),  // TEST-NET-3
            (0xE000_0000, 4),   // multicast
            (0xF000_0000, 4),   // reserved + broadcast
        ]
        return !blocked.contains { inNet($0.0, $0.1) }
    }

    /// Only global unicast (2000::/3) counts, minus documentation, 6to4, Teredo/ORCHID/benchmarking and NAT64.
    static func isPublicV6(_ b: [UInt8]) -> Bool {
        guard b.count == 16, b[0] & 0xE0 == 0x20 else { return false }
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0D && b[3] == 0xB8 { return false } // 2001:db8::/32
        if b[0] == 0x20 && b[1] == 0x02 { return false }                                  // 2002::/16 6to4
        if b[0] == 0x20 && b[1] == 0x01 && b[2] < 0x02 { return false }                   // 2001::/23 IETF
        return true
    }
}
