using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text.RegularExpressions;

namespace Nimbus.Core;

public enum HostKind
{
    Invalid,
    Domain,
    IPv4,
    IPv6,
}

/// <summary>
/// Normalizes a pasted URL, domain, IP or CIDR the same way on Windows and in the tests
/// that describe the macOS editor (strip scheme/path/port, punycode IDN).
/// </summary>
public static partial class HostEntry
{
    public const int MaxLength = 253;

    public sealed record Result(HostKind Kind, string Value)
    {
        public bool IsIp => Kind is HostKind.IPv4 or HostKind.IPv6;
        public bool IsDomain => Kind == HostKind.Domain;
    }

    public static Result? Parse(string? input)
    {
        if (string.IsNullOrWhiteSpace(input)) return null;
        var raw = input.Trim();
        if (raw.Length == 0 || raw.Length > 2048) return null;
        if (raw.Contains(' ') || raw.Contains('\t') || raw.Contains('\n') || raw.Contains('\r')) return null;

        raw = StripWraps(raw);
        if (TryCidr(raw, out var cidr)) return cidr;
        if (LooksLikeCidr(raw)) return null;

        if (LooksLikeUrl(raw) || raw.Contains('/'))
        {
            if (!TryHostFromUrl(raw, out var host)) return null;
            raw = host;
        }
        else if (TrySplitPort(raw, out var hostOnly, out _))
        {
            raw = hostOnly;
        }

        raw = raw.Trim().TrimEnd('.');
        if (raw.Length == 0 || raw.Length > MaxLength) return null;

        if (TryIp(raw, out var ip)) return ip;
        return TryDomain(raw);
    }

    public static string? Normalize(string? input) => Parse(input)?.Value;

    private static string StripWraps(string raw)
    {
        if (raw.Length >= 2 && ((raw[0] == '"' && raw[^1] == '"') || (raw[0] == '\'' && raw[^1] == '\'')))
        {
            raw = raw[1..^1].Trim();
        }
        return raw;
    }

    private static bool LooksLikeUrl(string raw) =>
        raw.Contains("://", StringComparison.Ordinal) ||
        raw.StartsWith("//", StringComparison.Ordinal) ||
        raw.StartsWith("www.", StringComparison.OrdinalIgnoreCase);

    private static bool TryHostFromUrl(string raw, out string host)
    {
        host = "";
        var candidate = raw;
        if (candidate.StartsWith("//", StringComparison.Ordinal)) candidate = "http:" + candidate;
        else if (!candidate.Contains("://", StringComparison.Ordinal)) candidate = "http://" + candidate;
        if (!Uri.TryCreate(candidate, UriKind.Absolute, out var uri)) return false;
        if (uri.Scheme is not ("http" or "https" or "ws" or "wss")) return false;
        if (string.IsNullOrEmpty(uri.IdnHost) && string.IsNullOrEmpty(uri.Host)) return false;
        host = string.IsNullOrEmpty(uri.IdnHost) ? uri.Host : uri.IdnHost;
        if (host.StartsWith('[') && host.EndsWith(']') && host.Length > 2) host = host[1..^1];
        return host.Length > 0;
    }

    private static bool TrySplitPort(string raw, out string host, out int? port)
    {
        host = raw;
        port = null;
        if (raw.StartsWith('[') && raw.Contains(']'))
        {
            var close = raw.IndexOf(']');
            host = raw[1..close];
            if (close + 1 < raw.Length)
            {
                if (raw[close + 1] != ':') return false;
                if (!int.TryParse(raw[(close + 2)..], NumberStyles.None, CultureInfo.InvariantCulture, out var p) || p is < 1 or > 65535) return false;
                port = p;
            }
            return host.Length > 0;
        }
        var colon = raw.LastIndexOf(':');
        if (colon <= 0 || raw.IndexOf(':') != colon) return false; // IPv6 without brackets, or no port
        if (!int.TryParse(raw[(colon + 1)..], NumberStyles.None, CultureInfo.InvariantCulture, out var portNum) || portNum is < 1 or > 65535) return false;
        host = raw[..colon];
        port = portNum;
        return host.Length > 0;
    }

    private static bool LooksLikeCidr(string raw)
    {
        var slash = raw.LastIndexOf('/');
        if (slash <= 0 || slash == raw.Length - 1) return false;
        var addr = raw[..slash];
        if (addr.StartsWith('[') && addr.EndsWith(']') && addr.Length > 2) addr = addr[1..^1];
        return IPAddress.TryParse(addr, out _);
    }

    private static bool TryCidr(string raw, out Result? result)
    {
        result = null;
        var slash = raw.LastIndexOf('/');
        if (slash <= 0 || slash == raw.Length - 1) return false;
        var addr = raw[..slash];
        if (addr.StartsWith('[') && addr.EndsWith(']') && addr.Length > 2) addr = addr[1..^1];
        if (!int.TryParse(raw[(slash + 1)..], NumberStyles.None, CultureInfo.InvariantCulture, out var prefix)) return false;
        if (!IPAddress.TryParse(addr, out var ip)) return false;
        if (ip.AddressFamily == AddressFamily.InterNetwork)
        {
            if (prefix is < 0 or > 32) return false;
            result = new Result(HostKind.IPv4, ip + "/" + prefix);
            return true;
        }
        if (ip.AddressFamily == AddressFamily.InterNetworkV6)
        {
            if (prefix is < 0 or > 128) return false;
            result = new Result(HostKind.IPv6, ip + "/" + prefix);
            return true;
        }
        return false;
    }

    private static bool TryIp(string raw, out Result? result)
    {
        result = null;
        var value = raw;
        if (value.StartsWith('[') && value.EndsWith(']') && value.Length > 2) value = value[1..^1];
        if (!IPAddress.TryParse(value, out var ip)) return false;
        result = ip.AddressFamily switch
        {
            AddressFamily.InterNetwork => new Result(HostKind.IPv4, ip.ToString()),
            AddressFamily.InterNetworkV6 => new Result(HostKind.IPv6, ip.ToString()),
            _ => null,
        };
        return result != null;
    }

    private static Result? TryDomain(string raw)
    {
        var domain = raw.Trim('.');
        if (domain.Length == 0 || domain.Length > MaxLength) return null;
        if (domain.Contains("..", StringComparison.Ordinal) || domain.StartsWith('-') || domain.EndsWith('-')) return null;
        string ascii;
        try
        {
            ascii = new IdnMapping().GetAscii(domain).ToLowerInvariant();
        }
        catch (ArgumentException)
        {
            return null;
        }
        if (!DomainPattern().IsMatch(ascii)) return null;
        var labels = ascii.Split('.');
        if (labels.Any(label => label.Length is 0 or > 63)) return null;
        if (labels.Length == 4 && labels.All(label => label.All(char.IsAsciiDigit))) return null;
        return new Result(HostKind.Domain, ascii);
    }

    [GeneratedRegex(@"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$")]
    private static partial Regex DomainPattern();
}
