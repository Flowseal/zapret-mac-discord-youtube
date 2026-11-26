using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Nimbus.Core;

/// <summary>
/// "Не трогать адреса": addresses and networks Nimbus must never touch. The same list is applied on both
/// platforms (winws --ipset-exclude on Windows, pass rules in the pf anchor on macOS).
/// Accepts IPv4/IPv6 addresses and CIDR networks separated by commas, spaces, semicolons or new lines.
/// </summary>
public static class LeaveAlone
{
    public const int MaxEntries = 64;

    public sealed record ParseResult(IReadOnlyList<string> Entries, IReadOnlyList<string> Invalid);

    public static ParseResult Parse(string? text)
    {
        var entries = new List<string>();
        var invalid = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var rawLine in (text ?? "").Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
        {
            var line = rawLine;
            var hash = line.IndexOf('#');
            if (hash >= 0) line = line[..hash];
            foreach (var token in line.Split(new[] { ',', ';', ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries))
            {
                if (!TryNormalize(token, out var normalized)) { invalid.Add(token); continue; }
                if (entries.Count >= MaxEntries) { invalid.Add(token); continue; }
                if (seen.Add(normalized)) entries.Add(normalized);
            }
        }
        return new ParseResult(entries, invalid);
    }

    /// <summary>Canonical form: plain address, or network address masked to its prefix ("10.1.2.3/8" becomes "10.0.0.0/8").</summary>
    public static bool TryNormalize(string token, out string normalized)
    {
        normalized = "";
        token = token.Trim();
        if (token.Length == 0 || token.Length > 60) return false;
        var slash = token.IndexOf('/');
        var addressText = slash < 0 ? token : token[..slash];
        int? prefix = null;
        if (slash >= 0)
        {
            var prefixText = token[(slash + 1)..];
            if (prefixText.Length == 0 || prefixText.Length > 3 || !prefixText.All(char.IsAsciiDigit)) return false;
            prefix = int.Parse(prefixText);
        }
        if (!LooksLikeAddress(addressText) || !IPAddress.TryParse(addressText, out var address)) return false;
        if (address.IsIPv6ScopeId()) return false;
        var bits = address.AddressFamily == AddressFamily.InterNetwork ? 32 : 128;
        if (prefix is { } p)
        {
            // /0 would switch Nimbus off completely; that is what the toggle is for
            if (p < 1 || p > bits) return false;
            address = Mask(address, p);
        }
        else if (address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any)) return false;
        normalized = address.ToString() + (prefix is { } q && q < bits ? "/" + q : "");
        return true;
    }

    public static bool IsIPv6(string entry) => entry.Contains(':');

    /// <summary>One entry per line, the format winws reads for --ipset-exclude.</summary>
    public static string ToIpsetFile(IEnumerable<string> entries)
    {
        var sb = new StringBuilder();
        foreach (var entry in entries) sb.Append(entry).Append('\n');
        return sb.ToString();
    }

    public static string Merge(params IEnumerable<string>[] groups)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var sb = new StringBuilder();
        foreach (var group in groups)
            foreach (var entry in group)
                if (seen.Add(entry)) sb.Append(entry).Append('\n');
        return sb.ToString();
    }

    private static bool LooksLikeAddress(string text)
    {
        if (text.Contains(':'))
            return text.All(c => char.IsAsciiHexDigit(c) || c == ':' || c == '.');
        var parts = text.Split('.');
        return parts.Length == 4 && parts.All(x => x.Length is >= 1 and <= 3 && x.All(char.IsAsciiDigit));
    }

    private static bool IsIPv6ScopeId(this IPAddress address) => address.AddressFamily == AddressFamily.InterNetworkV6 && address.ScopeId != 0;

    private static IPAddress Mask(IPAddress address, int prefix)
    {
        var bytes = address.GetAddressBytes();
        for (var i = 0; i < bytes.Length; i++)
        {
            var keep = Math.Clamp(prefix - i * 8, 0, 8);
            bytes[i] &= (byte)(0xFF << (8 - keep));
        }
        return new IPAddress(bytes);
    }
}
