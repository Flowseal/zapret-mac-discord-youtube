using System.Text.RegularExpressions;

namespace Nimbus.Core;

public sealed record Strategy(string Id, string Name);

public static partial class StrategyCatalog
{
    public const string DefaultId = "general-simple-fake";

    [GeneratedRegex("^general(-[a-z0-9]+)*$")]
    private static partial Regex IdPattern();

    public static bool IsValidId(string id) => IdPattern().IsMatch(id);

    /// <summary>Parses macos/Payload/strategies.tsv ("id\tname" per line), shared with the Mac app.</summary>
    public static IReadOnlyList<Strategy> Parse(string tsv)
    {
        var result = new List<Strategy>();
        foreach (var raw in tsv.Split('\n'))
        {
            var line = raw.TrimEnd('\r');
            var tab = line.IndexOf('\t');
            if (tab <= 0 || tab == line.Length - 1) continue;
            var id = line[..tab].Trim();
            var name = line[(tab + 1)..].Trim();
            if (id.Length == 0 || name.Length == 0) continue;
            result.Add(new Strategy(id, name));
        }
        return result;
    }
}

public static class IpsetModes
{
    public const string None = "none";
    public const string Loaded = "loaded";
    public const string Any = "any";

    public static string Normalize(string? mode) => mode switch
    {
        Loaded => Loaded,
        Any => Any,
        _ => None,
    };

    public static string Title(string? mode) => Normalize(mode) switch
    {
        Loaded => "Стандартный",
        Any => "Все",
        _ => "Нет",
    };
}
