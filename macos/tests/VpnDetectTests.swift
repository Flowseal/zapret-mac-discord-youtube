import Foundation

var failures = 0
func check(_ ok: Bool, _ message: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL (line \(line)): \(message)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ message: String, line: Int = #line) {
    if a != b { failures += 1; print("FAIL (line \(line)): \(message): got \(a), expected \(b)") }
}

// LeaveAlone
let parsed = LeaveAlone.parse("203.0.113.7, 198.51.100.0/24;2001:db8::/32\n  192.0.2.1\t# note\n# only a comment\n")
eq(parsed.entries, ["203.0.113.7", "198.51.100.0/24", "2001:db8::/32", "192.0.2.1"], "separators")
eq(parsed.invalid, [], "nothing invalid")
let normal: [(String, String)] = [
    ("10.1.2.3/8", "10.0.0.0/8"), ("192.168.1.77/24", "192.168.1.0/24"), ("203.0.113.7/32", "203.0.113.7"),
    ("2001:DB8::1", "2001:db8::1"), ("2001:db8:1234::5/48", "2001:db8:1234::/48"), ("10.0.0.1/13", "10.0.0.0/13"),
]
for (input, expected) in normal { eq(LeaveAlone.normalize(input), expected, "normalize \(input)") }
for bad in ["example.com", "1.2.3", "256.1.1.1", "203.0.113.7/33", "203.0.113.7/", "203.0.113.7/x", "0.0.0.0", "0.0.0.0/0", "::/0", "::", "fe80::1%12", "1.2.3.4;rm", "12345"] {
    eq(LeaveAlone.normalize(bad), nil, "reject \(bad)")
}
let mixed = LeaveAlone.parse("203.0.113.7 example.com 203.0.113.7 10.9.9.9/8, 10.0.0.0/8")
eq(mixed.entries, ["203.0.113.7", "10.0.0.0/8"], "dedupe")
eq(mixed.invalid, ["example.com"], "invalid reported")
let many = LeaveAlone.parse((1...(LeaveAlone.maxEntries + 5)).map { "10.0.\($0).1" }.joined(separator: " "))
eq(many.entries.count, LeaveAlone.maxEntries, "cap")
eq(many.invalid.count, 5, "over the cap")
eq(LeaveAlone.parse("").entries, [], "empty")

// TunnelProbe
let ifconfig = """
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
\tinet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 192.168.1.5 netmask 0xffffff00 broadcast 192.168.1.255
utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
\tinet6 fe80::1%utun0 prefixlen 64 scopeid 0xf
utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
\tinet 10.8.0.6 --> 10.8.0.5 netmask 0xffffffff
utun5: flags=8010<POINTOPOINT,MULTICAST> mtu 1500
\tinet 10.9.0.2 --> 10.9.0.1 netmask 0xffffffff
utun50: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
\tinet 10.77.0.1 --> 10.77.0.2 netmask 0xffffffff
utun6: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
\tinet6 fe80::3%utun6 prefixlen 64 scopeid 0x12
\tinet6 2001:db8::3 prefixlen 64
ppp0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
\tinet 172.16.0.9 --> 172.16.0.1 netmask 0xffffffff
"""
eq(TunnelProbe.interfaces(ifconfig: ifconfig), ["utun4", "utun6", "ppp0"], "addressed tunnels only")
check(!TunnelProbe.interfaces(ifconfig: ifconfig).contains("utun50"), "own interface skipped")
check(TunnelProbe.interfaces(ifconfig: ifconfig, nimbus: "utun99").contains("utun50"), "own interface follows the parameter")
for (name, expected) in [("utun4", true), ("utun", false), ("ipsec0", true), ("tun12", true), ("tap0", true), ("wg0", true), ("en0", false), ("bridge100", false), ("utunx", false)] {
    eq(TunnelProbe.isTunnelName(name), expected, "tunnel name \(name)")
}
eq(TunnelProbe.reason(tunnels: ["utun4"], defaultInterface: "en0", processNames: []), "туннель utun4", "split tunnel by interface")
eq(TunnelProbe.reason(tunnels: [], defaultInterface: "en0", processNames: ["Finder", "openvpn"]), "процесс openvpn", "vpn process")
eq(TunnelProbe.reason(tunnels: [], defaultInterface: "utun4", processNames: []), "маршрут по умолчанию через utun4", "default route through a tunnel")
eq(TunnelProbe.reason(tunnels: [], defaultInterface: "utun50", processNames: ["Finder"]), nil, "own interface as default is no VPN")
eq(TunnelProbe.reason(tunnels: [], defaultInterface: "en0", processNames: ["Finder"]), nil, "nothing to see")
check(TunnelProbe.isFullTunnelClient("процесс CloudflareWARP"), "warp")
check(!TunnelProbe.isFullTunnelClient("процесс openvpn"), "openvpn is not warp")

print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
