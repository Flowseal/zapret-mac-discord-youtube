namespace Nimbus.Core;

public static class UserLists
{
    public const string BypassDomains = "list-general-user.txt";
    public const string BypassIpset = "ipset-all-user.txt";
    public const string ExcludeDomains = "list-exclude-user.txt";
    public const string ExcludeIpset = "ipset-exclude-user.txt";

    public static string FileFor(HostKind kind, bool exclude) => (kind, exclude) switch
    {
        (HostKind.Domain, false) => BypassDomains,
        (HostKind.Domain, true) => ExcludeDomains,
        (_, false) => BypassIpset,
        (_, true) => ExcludeIpset,
    };

    public static IReadOnlyList<string> ReadEntries(string text)
    {
        var result = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var raw in text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            if (seen.Add(line)) result.Add(line);
        }
        return result;
    }

    public static bool Contains(string text, string entry) =>
        ReadEntries(text).Contains(entry, StringComparer.OrdinalIgnoreCase);

    public static string Add(string text, string entry)
    {
        if (Contains(text, entry)) return ListCatalog.NormalizeForSave(text);
        var body = ListCatalog.NormalizeForSave(text);
        if (body.Length > 0 && !body.EndsWith('\n')) body += "\n";
        return body + entry + "\n";
    }

    public static string Remove(string text, string entry)
    {
        var lines = new List<string>();
        foreach (var raw in ListCatalog.NormalizeForSave(text).Split('\n'))
        {
            if (raw.Trim().Equals(entry, StringComparison.OrdinalIgnoreCase)) continue;
            lines.Add(raw);
        }
        while (lines.Count > 0 && lines[^1].Length == 0) lines.RemoveAt(lines.Count - 1);
        return lines.Count == 0 ? "" : string.Join('\n', lines) + "\n";
    }
}
