namespace Nimbus.Core;

public sealed record StrategyResult(string Name, int Score, int Total, int TlsScore, bool Error = false)
{
    public string ScoreText => Error ? "ошибка" : $"{Score}/{Total}";
}

/// <summary>Same ranking as macos/Payload/test-strategies.sh: highest score wins, TLS successes break ties.</summary>
public sealed class BestTracker
{
    private readonly List<string> names = new();

    public int BestScore { get; private set; } = -1;
    public int BestTls { get; private set; } = -1;
    public IReadOnlyList<string> Names => names;

    public void Add(StrategyResult result)
    {
        if (result.Error) return;
        if (result.Score > BestScore || (result.Score == BestScore && result.TlsScore > BestTls))
        {
            BestScore = result.Score;
            BestTls = result.TlsScore;
            names.Clear();
            names.Add(result.Name);
        }
        else if (result.Score == BestScore && result.TlsScore == BestTls)
        {
            names.Add(result.Name);
        }
    }

    public bool IsBest(string name) => names.Contains(name);

    /// <summary>Parses a "Лучшая: a, b (x/y)" summary; exact names, unlike a substring match.</summary>
    public static bool IsBestInSummary(string summary, string name)
    {
        const string prefix = "Лучшая: ";
        if (!summary.StartsWith(prefix, StringComparison.Ordinal)) return false;
        var body = summary[prefix.Length..];
        var paren = body.LastIndexOf(" (", StringComparison.Ordinal);
        if (paren > 0 && body.EndsWith(')')) body = body[..paren];
        return body.Split(", ").Contains(name);
    }

    public string Summary(int maxTotal, bool cancelled)
    {
        if (cancelled) return "Остановлено";
        if (BestScore < 0) return "Лучшая: не определена";
        return $"Лучшая: {string.Join(", ", names)} ({BestScore}/{maxTotal})";
    }
}

public static class TestTargets
{
    public static readonly string[] Hosts =
    {
        "discord.com",
        "gateway.discord.gg",
        "cdn.discordapp.com",
        "updates.discord.com",
        "www.youtube.com",
        "youtu.be",
        "i.ytimg.com",
        "redirector.googlevideo.com",
        "www.gstatic.com",
    };
}
