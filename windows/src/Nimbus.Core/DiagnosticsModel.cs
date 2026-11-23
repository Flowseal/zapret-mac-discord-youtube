namespace Nimbus.Core;

public enum DiagnosticLevel
{
    Pass,
    Warn,
    Fail,
}

public sealed record DiagnosticRow(string Name, DiagnosticLevel Level, string Detail)
{
    public string LevelText => Level switch
    {
        DiagnosticLevel.Pass => "OK",
        DiagnosticLevel.Warn => "WARN",
        DiagnosticLevel.Fail => "FAIL",
        _ => "?",
    };
}

public static class DiagnosticReport
{
    public static string Format(string header, IEnumerable<DiagnosticRow> rows)
    {
        var lines = new List<string> { header, "" };
        foreach (var row in rows)
        {
            var detail = string.IsNullOrWhiteSpace(row.Detail) ? "" : " — " + row.Detail.Replace("\r\n", "\n").Replace('\n', ' ');
            lines.Add($"[{row.LevelText}] {row.Name}{detail}");
        }
        return string.Join('\n', lines) + "\n";
    }
}
