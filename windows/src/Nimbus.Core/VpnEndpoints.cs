using System.Net;
using System.Net.Sockets;

namespace Nimbus.Core;

public sealed record SocketRow(string Protocol, string Local, string Remote, string State, int Pid);

public sealed record AdapterInfo(string Name, string Description, string Type, bool IsUp, int IfIndex, bool HasGateway);

/// <summary>What the engine has to know about the current network: which interface to pin to and which VPN adapters exist.</summary>
public sealed record EnginePlan(int? PinnedIfIndex, IReadOnlyList<int> TunnelIndexes, string? TunnelName)
{
    public static readonly EnginePlan None = new(null, Array.Empty<int>(), null);

    /// <summary>Changes only when the engine has to be restarted (the WinDivert interface filter is fixed at start).</summary>
    public string Signature => PinnedIfIndex is { } idx ? "if" + idx : "-";
}

/// <summary>
/// Finds out where VPN clients connect to, so the engine can leave that traffic alone:
/// established sockets of VPN processes (netstat -ano) and host routes that point the VPN server at the
/// physical gateway (route print), which is what clients add when they take over the default route.
/// </summary>
public static class VpnEndpoints
{
    public static IReadOnlyList<SocketRow> ParseNetstat(string text)
    {
        var rows = new List<SocketRow>();
        foreach (var raw in text.Replace("\r\n", "\n").Split('\n'))
        {
            var parts = raw.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 4) continue;
            var proto = parts[0].ToUpperInvariant();
            if (proto is not ("TCP" or "UDP")) continue;
            string state = "";
            int pid;
            if (proto == "TCP")
            {
                if (parts.Length < 5 || !int.TryParse(parts[4], out pid)) continue;
                state = parts[3].ToUpperInvariant();
            }
            else if (!int.TryParse(parts[3], out pid)) continue;
            rows.Add(new SocketRow(proto, parts[1], parts[2], state, pid));
        }
        return rows;
    }

    /// <summary>Remote addresses of connected sockets that belong to the given processes.</summary>
    public static IReadOnlyList<string> RemotesOf(IEnumerable<SocketRow> rows, ISet<int> pids)
    {
        var result = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in rows)
        {
            if (!pids.Contains(row.Pid)) continue;
            if (row.Protocol == "TCP" && row.State != "ESTABLISHED") continue;
            var host = HostOf(row.Remote);
            if (host == null || !IsUsableRemote(host)) continue;
            var text = host.ToString();
            if (seen.Add(text)) result.Add(text);
        }
        return result;
    }

    /// <summary>`route print -4` rows (dest, mask, gateway, interface, metric): /32 routes through the given gateway.</summary>
    public static IReadOnlyList<string> HostRoutes(string routePrint, string gateway)
    {
        var result = new List<string>();
        if (!IPAddress.TryParse(gateway, out var gw)) return result;
        foreach (var raw in routePrint.Replace("\r\n", "\n").Split('\n'))
        {
            var parts = raw.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 5) continue;
            if (parts[1] != "255.255.255.255") continue;
            if (!IPAddress.TryParse(parts[0], out var dest) || !IPAddress.TryParse(parts[2], out var via)) continue;
            if (!via.Equals(gw) || !IsUsableRemote(dest)) continue;
            var text = dest.ToString();
            if (!result.Contains(text)) result.Add(text);
        }
        return result;
    }

    /// <summary>Address part of "1.2.3.4:443" or "[2001:db8::1]:443"; null for "*:*" and "0.0.0.0:0".</summary>
    public static IPAddress? HostOf(string endpoint)
    {
        string host;
        if (endpoint.StartsWith('['))
        {
            var close = endpoint.IndexOf(']');
            if (close < 0) return null;
            host = endpoint[1..close];
        }
        else
        {
            var colon = endpoint.LastIndexOf(':');
            if (colon <= 0) return null;
            host = endpoint[..colon];
        }
        var percent = host.IndexOf('%');
        if (percent >= 0) host = host[..percent];
        return IPAddress.TryParse(host, out var address) ? address : null;
    }

    private static bool IsUsableRemote(IPAddress address)
    {
        if (IPAddress.IsLoopback(address) || address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any) || address.Equals(IPAddress.Broadcast)) return false;
        if (address.AddressFamily == AddressFamily.InterNetworkV6) return !address.IsIPv6LinkLocal && !address.IsIPv6Multicast;
        var b = address.GetAddressBytes();
        return b[0] < 224;
    }

    /// <summary>
    /// Physical interface to pin the WinDivert filter to, only while a VPN adapter is up:
    /// the adapter that Windows would use for internet traffic if it is not a tunnel, else the first one with a gateway.
    /// </summary>
    public static EnginePlan Plan(IEnumerable<AdapterInfo> adapters, int? bestIfIndex)
    {
        var all = adapters.Where(a => a.IsUp).ToList();
        var tunnels = new List<AdapterInfo>();
        foreach (var a in all)
        {
            if (VpnSignatures.MatchAdapter(a.Name, a.Description, a.Type).IsVpn) tunnels.Add(a);
        }
        if (tunnels.Count == 0) return EnginePlan.None;
        var tunnelIdx = tunnels.Select(t => t.IfIndex).Distinct().OrderBy(i => i).ToList();
        var candidates = all
            .Where(a => a.HasGateway && !tunnelIdx.Contains(a.IfIndex) && a.Type is not ("Loopback" or "Tunnel" or "Ppp"))
            .OrderBy(a => a.IfIndex)
            .ToList();
        int? pinned = null;
        if (bestIfIndex is { } best && candidates.Any(c => c.IfIndex == best)) pinned = best;
        else if (candidates.Count > 0) pinned = candidates[0].IfIndex;
        return new EnginePlan(pinned, tunnelIdx, tunnels[0].Name);
    }
}
