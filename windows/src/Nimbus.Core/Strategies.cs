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

public static class GameFilterModes
{
    public const string Off = "off";
    public const string Games = "games";
    public const string Wide = "wide";

    public const string GamesTcp = "3074,3075,1119,3724";
    public const string GamesUdp = "3074,3075,3478-3480,3659,4379-4380,27000-27050";
    public const string WidePorts = "1024-65535";

    public static string Normalize(string? mode) => mode switch
    {
        Games => Games,
        Wide => Wide,
        _ => Off,
    };

    public static bool IsOn(string? mode) => Normalize(mode) is Games or Wide;

    public static string Title(string? mode) => Normalize(mode) switch
    {
        Games => "Игры",
        Wide => "Широкий",
        _ => "Выкл",
    };

    public static (string Tcp, string Udp)? Ports(string? mode) => Normalize(mode) switch
    {
        Games => (GamesTcp, GamesUdp),
        Wide => (WidePorts, WidePorts),
        _ => null,
    };
}
