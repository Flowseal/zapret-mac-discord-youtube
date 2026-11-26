namespace Nimbus.Core;

public sealed record ListInfo(string Id, string Title, string Detail, string Badge, bool External, int Lines = 0);

public static class ListCatalog
{
    public const long ExternalThreshold = 80_000;

    public static readonly string[] Names =
    {
        "list-general-user.txt",
        "list-exclude-user.txt",
        "ipset-all-user.txt",
        "ipset-exclude-user.txt",
        "list-general.txt",
        "list-google.txt",
        "list-exclude.txt",
        "ipset-exclude.txt",
        "ipset-all.txt",
    };

    public static string Title(string name) => name switch
    {
        "list-general.txt" or "list-general-user.txt" => "Основные",
        "list-google.txt" => "Google",
        "list-exclude.txt" or "list-exclude-user.txt" => "Исключения",
        "ipset-all.txt" or "ipset-all-user.txt" => "IP-набор",
        "ipset-exclude.txt" or "ipset-exclude-user.txt" => "IP исключения",
        _ => name,
    };

    public static int CountLines(string text) =>
        text.Split('\n').Count(l => l.Trim().Length > 0);

    public static ListInfo Describe(string name, long size, string text)
    {
        var lines = CountLines(text);
        var external = size > ExternalThreshold;
        return new ListInfo(
            name,
            Title(name),
            external ? $"{lines} строк · открыть" : $"{lines} строк",
            name.Contains("-user") ? "свои" : "",
            external,
            lines);
    }

    /// <summary>Hostlists are read by winws line by line; keep them LF like the Mac app.</summary>
    public static string NormalizeForSave(string text) => text.Replace("\r\n", "\n").Replace('\r', '\n');
}
