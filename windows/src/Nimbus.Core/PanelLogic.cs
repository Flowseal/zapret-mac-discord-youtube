using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Nimbus.Core;

/// <summary>One parsed log line for the Логи page (mirror of LogLine in macos/App/NimbusSupport.swift).</summary>
public sealed record LogLine(int Id, string Source, string Time, string Level, string Text);

public static class LogParser
{
    private static readonly Regex Stamp = new(@"^\[?(\d{4}-\d{2}-\d{2}[T ])?\d{2}:\d{2}:\d{2}([.,]\d+)?([+-]\d{2}:?\d{2}|Z)?\]?\s*", RegexOptions.Compiled);
    private static readonly Regex Clock = new(@"\d{2}:\d{2}:\d{2}", RegexOptions.Compiled);
    private static readonly Regex Tag = new(@"^\[?(INF|INFO|WRN|WARN|WARNING|ERR|ERROR)\]?:?\s+", RegexOptions.Compiled | RegexOptions.IgnoreCase);

    /// <summary>A leading time stamp becomes the time column; the level comes from a tag or from error/warning keywords.</summary>
    public static IReadOnlyList<LogLine> Parse(string text, string source, int startId = 0)
    {
        var rows = new List<LogLine>();
        var id = startId;
        foreach (var raw in text.Replace("\r\n", "\n").Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            if (line.StartsWith("— ", StringComparison.Ordinal) && line.EndsWith(" —", StringComparison.Ordinal) && line.Contains(".log")) continue;
            var time = "--:--:--";
            var stamp = Stamp.Match(line);
            if (stamp.Success && stamp.Length > 0)
            {
                var clock = Clock.Match(stamp.Value);
                if (clock.Success) time = clock.Value;
                line = line[stamp.Length..];
            }
            var level = "INF";
            var tag = Tag.Match(line);
            if (tag.Success)
            {
                var word = tag.Groups[1].Value.ToUpperInvariant();
                level = word.StartsWith('E') ? "ERR" : word.StartsWith('W') ? "WRN" : "INF";
                line = line[tag.Length..];
            }
            else
            {
                var lower = line.ToLowerInvariant();
                if (lower.Contains("error") || lower.Contains("fail") || lower.Contains("ошибк") || lower.Contains("не удалось") || lower.Contains("fatal"))
                    level = "ERR";
                else if (lower.Contains("warn") || lower.Contains("timeout") || lower.Contains("retry") || lower.Contains("предупрежд"))
                    level = "WRN";
            }
            rows.Add(new LogLine(id++, source, time, level, line));
        }
        return rows;
    }

    private static int Rank(string level) => level.ToLowerInvariant() switch
    {
        "wrn" => 1,
        "err" => 2,
        "inf" => 0,
        _ => -1,
    };

    /// <summary>All plain words must appear; <c>level:wrn+</c> keeps warnings and errors, <c>level:err</c> errors only, <c>source:engine</c> one source.</summary>
    public static bool Matches(LogLine line, string query)
    {
        var q = query.Trim().ToLowerInvariant();
        if (q.Length == 0) return true;
        foreach (var token in q.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            if (token.StartsWith("level:", StringComparison.Ordinal))
            {
                var want = token["level:".Length..];
                var plus = want.EndsWith('+');
                var need = Rank(plus ? want[..^1] : want);
                var have = Rank(line.Level);
                if (need < 0) return false;
                if (plus ? have < need : have != need) return false;
                continue;
            }
            if (token.StartsWith("source:", StringComparison.Ordinal))
            {
                if (!string.Equals(line.Source, token["source:".Length..], StringComparison.OrdinalIgnoreCase)) return false;
                continue;
            }
            var hay = (line.Text + " " + line.Source + " " + line.Time).ToLowerInvariant();
            if (!hay.Contains(token)) return false;
        }
        return true;
    }

    /// <summary>52113 → "52 113" with a narrow no-break space.</summary>
    public static string GroupThousands(long value)
    {
        var digits = Math.Abs(value).ToString(CultureInfo.InvariantCulture);
        var sb = new StringBuilder();
        for (var i = 0; i < digits.Length; i++)
        {
            if (i > 0 && (digits.Length - i) % 3 == 0) sb.Append('\u202F');
            sb.Append(digits[i]);
        }
        return value < 0 ? "-" + sb : sb.ToString();
    }
}

public static class LatencyStats
{
    /// <summary>Linear-interpolated percentile (p in 0…1) over the finite samples.</summary>
    public static double Percentile(IEnumerable<double> values, double p)
    {
        var sorted = values.Where(double.IsFinite).OrderBy(v => v).ToArray();
        if (sorted.Length == 0) return 0;
        if (sorted.Length == 1) return sorted[0];
        var rank = Math.Clamp(p, 0, 1) * (sorted.Length - 1);
        var lo = (int)Math.Floor(rank);
        var hi = Math.Min(lo + 1, sorted.Length - 1);
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - lo);
    }

    /// <summary>"p50 61 ms · p95 88 ms", or "нет данных" with fewer than two samples.</summary>
    public static string Summary(IEnumerable<double> values)
    {
        var finite = values.Where(double.IsFinite).ToArray();
        if (finite.Length < 2) return "нет данных";
        return string.Create(CultureInfo.InvariantCulture, $"p50 {Math.Round(Percentile(finite, 0.5), MidpointRounding.AwayFromZero)} ms · p95 {Math.Round(Percentile(finite, 0.95), MidpointRounding.AwayFromZero)} ms");
    }
}

public static class EngineClock
{
    public static string Format(TimeSpan elapsed)
    {
        var s = Math.Max(0, (long)elapsed.TotalSeconds);
        return string.Create(CultureInfo.InvariantCulture, $"{s / 3600:00}:{s / 60 % 60:00}:{s % 60:00}");
    }

    /// <summary>"проверено 12 с назад" / "проверено 3 мин назад".</summary>
    public static string Since(TimeSpan elapsed)
    {
        var s = Math.Max(0, (long)elapsed.TotalSeconds);
        return s < 60 ? $"проверено {s} с назад" : $"проверено {s / 60} мин назад";
    }
}

/// <summary>Panel / tray glyph states.</summary>
public enum MarkState
{
    Off,
    Checking,
    On,
    Problem,
}

/// <summary>Animatable parameters of the offset-N mark on its 16-unit grid.</summary>
public readonly record struct MarkParams(double Fill, double Outline, double Gap, double? Band)
{
    public static MarkParams Target(MarkState state) => state switch
    {
        MarkState.On => new MarkParams(16, 0, 0, null),
        MarkState.Problem => new MarkParams(16, 0, 1, null),
        MarkState.Checking => new MarkParams(0, 1, 0, -6),
        _ => new MarkParams(0, 1, 0, null),
    };
}

public static class MarkGeometry
{
    /// <summary>SVG path of the mark: two offset stems joined by the diagonal.</summary>
    public const string PathData = "M2 4H5L11 9.333V2H14V12H11L5 6.667V14H2Z";
    public static readonly (double X, double Y)[] Points = { (2, 4), (5, 4), (11, 9.333), (11, 2), (14, 2), (14, 12), (11, 12), (5, 6.667), (5, 14), (2, 14) };
    public const double OutlineWidth = 1.2;
    public const double DiagonalDegrees = 41.63;
    public const double SweepPeriod = 1.15;
    public const double BandWidth = 6;

    /// <summary>Left edge of the checking sweep band: −6 → 16 with ease-in-out, repeating.</summary>
    public static double Band(double seconds)
    {
        var t = seconds / SweepPeriod % 1;
        if (t < 0) t += 1;
        var eased = t < 0.5 ? 4 * t * t * t : 1 - Math.Pow(-2 * t + 2, 3) / 2;
        return -6 + 22 * eased;
    }
}

/// <summary>Critically damped spring (no overshoot), the same motion the Mac glyph uses.</summary>
public static class Spring
{
    /// <summary>Advances (value, velocity) towards target by dt seconds for a spring with the given response (period, s).</summary>
    public static (double Value, double Velocity) Step(double value, double velocity, double target, double response, double dt)
    {
        var omega = 2 * Math.PI / Math.Max(0.01, response);
        var x0 = value - target;
        var decay = Math.Exp(-omega * dt);
        var c = velocity + omega * x0;
        var x = (x0 + c * dt) * decay;
        var v = (velocity - c * omega * dt) * decay;
        return (target + x, v);
    }

    public static bool Settled(double value, double velocity, double target, double epsilon = 0.01) =>
        Math.Abs(value - target) < epsilon && Math.Abs(velocity) < epsilon * 10;
}

/// <summary>Which of the four states the panel and tray show (mirror of HUDModel.phase).</summary>
public static class PanelPhase
{
    public static MarkState Resolve(bool running, bool busy, bool? switchIntent, bool testing, bool anyServiceBad, bool anyServiceChecking)
    {
        if (!running) return busy || switchIntent == true ? MarkState.Checking : MarkState.Off;
        if (busy || testing) return MarkState.Checking;
        if (anyServiceBad) return MarkState.Problem;
        if (anyServiceChecking) return MarkState.Checking;
        return MarkState.On;
    }
}
