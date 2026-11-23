using System.Text.RegularExpressions;

namespace Nimbus.Core;

public static partial class StrategyOrder
{
    /// <summary>Well-known strategies tried first in smart mode after the current one and recent winners.</summary>
    public static readonly string[] PreferredIds =
    {
        StrategyCatalog.DefaultId,
        "general",
        "general-alt",
        "general-fake-tls-auto",
        "general-alt2",
    };

    public const string DiscordHost = "discord.com";
    public const string YouTubeHost = "www.youtube.com";

    public static IReadOnlyList<Strategy> ForSmart(IReadOnlyList<Strategy> all, string? currentId, IEnumerable<string>? recentWinners = null)
    {
        var remaining = all.ToList();
        var ordered = new List<Strategy>();

        void Take(Func<Strategy, bool> match)
        {
            for (var i = 0; i < remaining.Count; i++)
            {
                if (!match(remaining[i])) continue;
                ordered.Add(remaining[i]);
                remaining.RemoveAt(i);
                i--;
            }
        }

        if (!string.IsNullOrWhiteSpace(currentId))
        {
            Take(s => s.Id == currentId);
        }
        if (recentWinners != null)
        {
            foreach (var winner in recentWinners)
            {
                var name = winner.Trim();
                if (name.Length == 0) continue;
                Take(s => s.Id == name || s.Name == name);
            }
        }
        foreach (var id in PreferredIds)
        {
            Take(s => s.Id == id);
        }
        ordered.AddRange(remaining);
        return ordered;
    }

    public static IReadOnlyList<string> ParseWinners(string? summaryOrList)
    {
        if (string.IsNullOrWhiteSpace(summaryOrList)) return Array.Empty<string>();
        var text = summaryOrList.Trim();
        const string prefix = "Лучшая: ";
        if (text.StartsWith(prefix, StringComparison.Ordinal))
        {
            var body = text[prefix.Length..];
            if (body.StartsWith("не определена", StringComparison.Ordinal)) return Array.Empty<string>();
            var paren = body.LastIndexOf(" (", StringComparison.Ordinal);
            if (paren > 0 && body.EndsWith(')')) body = body[..paren];
            text = body;
        }
        return text.Split(',').Select(s => s.Trim()).Where(s => s.Length > 0).ToList();
    }

    public static bool TryParseProgress(string? text, out int current, out int total)
    {
        current = 0;
        total = 0;
        if (string.IsNullOrWhiteSpace(text)) return false;
        var match = ProgressPattern().Match(text);
        if (!match.Success) return false;
        current = int.Parse(match.Groups[1].Value);
        total = int.Parse(match.Groups[2].Value);
        return total > 0;
    }

    public static double ProgressFraction(string? text)
    {
        if (!TryParseProgress(text, out var current, out var total)) return 0;
        return Math.Clamp(current / (double)total, 0, 1);
    }

    /// <summary>Smart mode: Discord + YouTube (and an optional extra host) must pass TLS.</summary>
    public static bool PassesSmart(IReadOnlyDictionary<string, bool> tlsByHost, string? extraHost = null)
    {
        if (!HostPassed(tlsByHost, DiscordHost) || !HostPassed(tlsByHost, YouTubeHost)) return false;
        if (string.IsNullOrWhiteSpace(extraHost)) return true;
        var parsed = HostEntry.Normalize(extraHost);
        if (parsed == null) return false;
        return HostPassed(tlsByHost, parsed);
    }

    private static bool HostPassed(IReadOnlyDictionary<string, bool> tlsByHost, string host) =>
        tlsByHost.TryGetValue(host, out var ok) && ok;

    [GeneratedRegex(@"(\d+)\s*/\s*(\d+)")]
    private static partial Regex ProgressPattern();
}
