import Foundation

/// "Не трогать адреса": addresses and networks Nimbus never touches. Same rules as the Windows app
/// and the shell helper in pf-lib.sh: IPv4/IPv6 addresses or CIDR networks, separated by commas, spaces, semicolons or lines.
enum LeaveAlone {
    static let maxEntries = 64

    static func parse(_ text: String) -> (entries: [String], invalid: [String]) {
        var entries: [String] = []
        var invalid: [String] = []
        var seen = Set<String>()
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            let tokens = line.split(whereSeparator: { ",; \t".contains($0) }).map(String.init)
            for token in tokens {
                guard let normalized = normalize(token), entries.count < maxEntries else { invalid.append(token); continue }
                if seen.insert(normalized).inserted { entries.append(normalized) }
            }
        }
        return (entries, invalid)
    }

    /// Plain address or network masked to its prefix ("10.1.2.3/8" becomes "10.0.0.0/8"); nil for anything else.
    static func normalize(_ token: String) -> String? {
        let text = token.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 60 else { return nil }
        let pieces = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var prefix: Int?
        if pieces.count == 2 {
            guard !pieces[1].isEmpty, pieces[1].count <= 3, pieces[1].allSatisfy(\.isASCII), pieces[1].allSatisfy(\.isNumber), let p = Int(pieces[1]) else { return nil }
            prefix = p
        }
        let address = pieces[0]
        let v6 = address.contains(":")
        guard v6 ? address.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) : looksLikeIPv4(address) else { return nil }
        var bytes = [UInt8](repeating: 0, count: v6 ? 16 : 4)
        let parsed = bytes.withUnsafeMutableBytes { inet_pton(v6 ? AF_INET6 : AF_INET, address, $0.baseAddress) }
        guard parsed == 1 else { return nil }
        let bits = bytes.count * 8
        if let p = prefix {
            // /0 would switch Nimbus off completely; that is what the toggle is for
            guard p >= 1, p <= bits else { return nil }
            for i in 0..<bytes.count {
                let keep = max(0, min(8, p - i * 8))
                bytes[i] &= UInt8(truncatingIfNeeded: 0xFF << (8 - keep))
            }
        } else if bytes.allSatisfy({ $0 == 0 }) {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: 64)
        guard bytes.withUnsafeBytes({ inet_ntop(v6 ? AF_INET6 : AF_INET, $0.baseAddress, &buffer, 64) }) != nil else { return nil }
        let canonical = String(cString: buffer)
        if let p = prefix, p < bits { return canonical + "/" + String(p) }
        return canonical
    }

    private static func looksLikeIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { (1...3).contains($0.count) && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }
}

/// Tunnel detection from `ifconfig` and process names, including split-tunnel VPNs that leave the default route alone.
enum TunnelProbe {
    static func isTunnelName(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap", "wg"].contains { prefix in
            name.hasPrefix(prefix) && name.count > prefix.count && name.dropFirst(prefix.count).allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    /// Tunnels that are up and carry a real address. The system keeps a few utun interfaces with only an fe80:: address; those are not VPNs.
    static func interfaces(ifconfig: String, nimbus: String = "utun50") -> [String] {
        var result: [String] = []
        var name: String?
        var up = false
        var addressed = false
        func flush() {
            if let name, up, addressed, isTunnelName(name), name != nimbus { result.append(name) }
            name = nil; up = false; addressed = false
        }
        for raw in ifconfig.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, !first.isWhitespace {
                flush()
                guard let colon = raw.firstIndex(of: ":") else { continue }
                name = String(raw[..<colon])
                if let open = raw.firstIndex(of: "<"), let close = raw.firstIndex(of: ">"), open < close {
                    up = raw[raw.index(after: open)..<close].split(separator: ",").contains("UP")
                }
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("inet ") { addressed = true }
            else if line.hasPrefix("inet6 "), !line.lowercased().hasPrefix("inet6 fe80:") { addressed = true }
        }
        flush()
        return result
    }

    /// Why Nimbus thinks a VPN is active, or nil. The default route through a tunnel, a VPN process or an extra tunnel interface all count.
    static func reason(tunnels: [String], defaultInterface: String, processNames: [String], nimbus: String = "utun50") -> String? {
        let name = defaultInterface.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != nimbus, isTunnelName(name) || name.hasPrefix("ipip") { return "маршрут по умолчанию через \(name)" }
        for process in processNames where isVpnProcess(process) { return "процесс \(process)" }
        if let first = tunnels.first { return "туннель \(first)" }
        return nil
    }

    static let processTokens = [
        "openvpn", "wireguard", "wg-quick", "openconnect", "racoon", "vpnc", "charon", "tailscaled", "zerotier",
        "sing-box", "xray", "v2ray", "hiddify", "amnezia", "clash", "mihomo", "hysteria", "outline", "cloudflarewarp", "warp-svc",
        "protonvpn", "mullvad", "nordvpn", "expressvpn", "rabbithole",
    ]

    static func isVpnProcess(_ name: String) -> Bool {
        let lower = name.lowercased()
        return processTokens.contains { lower.contains($0) }
    }

    /// WARP takes over every connection, so a bypass has nothing left to work on.
    static func isFullTunnelClient(_ text: String) -> Bool {
        text.lowercased().contains("warp")
    }
}
