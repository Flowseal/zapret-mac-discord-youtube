namespace Nimbus.Core;

public sealed record VpnMatch(bool IsVpn, string? Reason);

/// <summary>Name / description heuristics for common desktop VPN and tun adapters.</summary>
public static class VpnSignatures
{
    public static readonly string[] AdapterTokens =
    {
        "wireguard", "wintun", "nordlynx",
        "openvpn", "tap-windows", "tap-win32", "tap-win64", "tap-windows6",
        "sing-box", "singbox", "tun2socks",
        "xray", "v2ray", "v2fly",
        "amnezia", "amneziawg",
        "rabbithole", "rabbit hole",
        "cloudflare warp", "cloudflarewarp", "warp-cloudflare", "cfwarp",
        "outline",
        "tailscale",
        "zerotier",
        "softether",
        "protonvpn", "proton vpn", "mullvad", "nordvpn", "expressvpn", "surfshark",
        "windscribe", "hide.me", "cyberghost",
        "forticlient", "fortissl", "cisco anyconnect", "anyconnect",
        "globalprotect", "pangps", "pulse secure", "juniper",
        "openconnect", "sstp", "ikev2", "l2tp",
        "hiddify", "nekobox", "clash", "hysteria",
    };

    public static readonly string[] ProcessTokens =
    {
        "wireguard", "openvpn", "openvpn-gui",
        "sing-box", "singbox", "xray", "v2ray", "v2rayn", "v2rayng",
        "amnezia", "amneziavpn", "rabbithole",
        "cloudflare WARP", "warp-svc", "CloudflareWARP",
        "outline", "tailscale", "tailscaled", "zerotier",
        "hiddify", "nekobox", "clash", "clash-meta",
        "ProtonVPN", "Mullvad", "NordVPN", "ExpressVPN",
    };

    private static readonly string[] IgnoredTokens =
    {
        "teredo", "isatap", "6to4", "loopback", "pseudo-interface",
        "microsoft kernel debug", "debug network",
    };

    public static bool IsIgnored(string? name, string? description)
    {
        var text = ((name ?? "") + " " + (description ?? "")).ToLowerInvariant();
        return IgnoredTokens.Any(token => text.Contains(token, StringComparison.Ordinal));
    }

    public static VpnMatch MatchAdapter(string? name, string? description, string? type = null)
    {
        if (IsIgnored(name, description)) return new VpnMatch(false, null);
        var text = ((name ?? "") + " " + (description ?? "")).ToLowerInvariant();
        foreach (var token in AdapterTokens)
        {
            if (text.Contains(token, StringComparison.Ordinal))
            {
                return new VpnMatch(true, "адаптер «" + Display(name, description) + "»");
            }
        }
        if (LooksLikeTunnelType(type) && !string.IsNullOrWhiteSpace(text))
        {
            // Generic "Tunnel" / "PPP" adapters often are VPNs; still skip empty/unnamed placeholders.
            if (text.Contains("tunnel", StringComparison.Ordinal) || text.Contains("vpn", StringComparison.Ordinal) ||
                text.Contains("ppp", StringComparison.Ordinal) || string.Equals(type, "Ppp", StringComparison.OrdinalIgnoreCase))
            {
                return new VpnMatch(true, "туннель «" + Display(name, description) + "»");
            }
        }
        return new VpnMatch(false, null);
    }

    public static VpnMatch MatchProcess(string? processName)
    {
        var name = (processName ?? "").Trim();
        if (name.Length == 0) return new VpnMatch(false, null);
        var lower = name.ToLowerInvariant();
        if (lower.EndsWith(".exe")) lower = lower[..^4];
        foreach (var token in ProcessTokens)
        {
            var key = token.ToLowerInvariant().Replace(" ", "");
            var candidate = lower.Replace(" ", "");
            if (candidate.Contains(key, StringComparison.Ordinal) || key.Contains(candidate, StringComparison.Ordinal) && candidate.Length >= 5)
            {
                return new VpnMatch(true, "процесс " + name);
            }
        }
        return new VpnMatch(false, null);
    }

    /// <summary>macOS: a default route going through a utun/ipsec/ppp interface that is not Nimbus's utun50.</summary>
    public static VpnMatch MatchMacDefaultRoute(string? iface, string nimbusIface = "utun50")
    {
        var name = (iface ?? "").Trim();
        if (name.Length == 0) return new VpnMatch(false, null);
        if (string.Equals(name, nimbusIface, StringComparison.Ordinal)) return new VpnMatch(false, null);
        if (name.StartsWith("utun", StringComparison.Ordinal) ||
            name.StartsWith("ipsec", StringComparison.Ordinal) ||
            name.StartsWith("ppp", StringComparison.Ordinal) ||
            name.StartsWith("ipip", StringComparison.Ordinal) ||
            name == "wg0")
        {
            return new VpnMatch(true, "маршрут по умолчанию через " + name);
        }
        return new VpnMatch(false, null);
    }

    /// <summary>
    /// macOS `ifconfig` output: tunnel interfaces that are up and carry a real address. The system keeps a few
    /// utun interfaces around with only an fe80:: address; those are not VPNs.
    /// </summary>
    public static IReadOnlyList<string> MacTunnelInterfaces(string ifconfig, string nimbusIface = "utun50")
    {
        var result = new List<string>();
        string? name = null;
        var up = false;
        var addressed = false;
        void Flush()
        {
            if (name != null && up && addressed && IsMacTunnelName(name) && name != nimbusIface) result.Add(name);
            name = null; up = false; addressed = false;
        }
        foreach (var raw in ifconfig.Replace("\r\n", "\n").Split('\n'))
        {
            if (raw.Length > 0 && !char.IsWhiteSpace(raw[0]))
            {
                Flush();
                var colon = raw.IndexOf(':');
                if (colon <= 0) continue;
                name = raw[..colon];
                var flagsStart = raw.IndexOf('<');
                var flagsEnd = raw.IndexOf('>');
                up = flagsStart >= 0 && flagsEnd > flagsStart && raw[(flagsStart + 1)..flagsEnd].Split(',').Contains("UP");
                continue;
            }
            var line = raw.Trim();
            if (line.StartsWith("inet ", StringComparison.Ordinal)) addressed = true;
            else if (line.StartsWith("inet6 ", StringComparison.Ordinal) && !line.StartsWith("inet6 fe80:", StringComparison.OrdinalIgnoreCase)) addressed = true;
        }
        Flush();
        return result;
    }

    public static bool IsMacTunnelName(string name) =>
        new[] { "utun", "ipsec", "ppp", "tun", "tap", "wg" }.Any(prefix =>
            name.Length > prefix.Length && name.StartsWith(prefix, StringComparison.Ordinal) && name[prefix.Length..].All(char.IsAsciiDigit));

    /// <summary>A split-tunnel VPN does not touch the default route: an extra tunnel interface or a VPN process is the tell.</summary>
    public static VpnMatch MatchMacTunnels(IReadOnlyList<string> tunnels, string? defaultIface, IEnumerable<string> processNames)
    {
        var viaDefault = MatchMacDefaultRoute(defaultIface);
        if (viaDefault.IsVpn) return viaDefault;
        foreach (var name in processNames)
        {
            var process = MatchProcess(name);
            if (process.IsVpn) return process;
        }
        if (tunnels.Count > 0) return new VpnMatch(true, "туннель " + tunnels[0]);
        return new VpnMatch(false, null);
    }

    /// <summary>WARP takes over every connection, so a bypass has nothing left to work on; it is the one case worth a warning.</summary>
    public static bool IsFullTunnelClient(string? text)
    {
        var lower = (text ?? "").ToLowerInvariant();
        return lower.Contains("warp", StringComparison.Ordinal);
    }

    private static bool LooksLikeTunnelType(string? type) =>
        type is not null && (
            type.Equals("Tunnel", StringComparison.OrdinalIgnoreCase) ||
            type.Equals("Ppp", StringComparison.OrdinalIgnoreCase) ||
            type.Equals("54", StringComparison.Ordinal)); // NetworkInterfaceType.Tunnel = 53? actually Tunnel=131, Ppp=23. We pass enum names.

    private static string Display(string? name, string? description)
    {
        if (!string.IsNullOrWhiteSpace(name)) return name.Trim();
        if (!string.IsNullOrWhiteSpace(description)) return description.Trim();
        return "VPN";
    }
}
