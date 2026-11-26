using Nimbus.Core;
using Xunit;

public class LogParserTests
{
    [Fact]
    public void ParsesStampLevelAndKeywords()
    {
        var rows = LogParser.Parse(
            "— nimbus.log —\r\n2026-11-22 17:40:01 started\n[12:03:12] ERROR desync rejected\n11:42:10 retry 1/2\nplain line\n\n",
            "engine", startId: 10);
        Assert.Equal(4, rows.Count);
        Assert.Equal(new LogLine(10, "engine", "17:40:01", "INF", "started"), rows[0]);
        Assert.Equal(("12:03:12", "ERR", "desync rejected"), (rows[1].Time, rows[1].Level, rows[1].Text));
        Assert.Equal("WRN", rows[2].Level);
        Assert.Equal(("--:--:--", "INF"), (rows[3].Time, rows[3].Level));
        Assert.Equal(13, rows[3].Id);
    }

    [Theory]
    [InlineData("", "INF", true)]
    [InlineData("level:wrn+", "INF", false)]
    [InlineData("level:wrn+", "WRN", true)]
    [InlineData("level:wrn+", "ERR", true)]
    [InlineData("level:err", "WRN", false)]
    [InlineData("level:inf", "INF", true)]
    [InlineData("level:bogus", "INF", false)]
    [InlineData("youtube timeout", "WRN", true)]
    [InlineData("youtube discord", "WRN", false)]
    [InlineData("source:probe", "WRN", true)]
    [InlineData("source:engine", "WRN", false)]
    public void FilterQueries(string query, string level, bool expected)
    {
        var line = new LogLine(0, "probe", "11:42:10", level, "www.youtube.com:443 retry 1/2 · timeout 3000 ms");
        Assert.Equal(expected, LogParser.Matches(line, query));
    }

    [Theory]
    [InlineData(0, "0")]
    [InlineData(491, "491")]
    [InlineData(1240, "1\u202F240")]
    [InlineData(52113, "52\u202F113")]
    [InlineData(-1284, "-1\u202F284")]
    public void GroupsThousands(long value, string expected) => Assert.Equal(expected, LogParser.GroupThousands(value));
}

public class LatencyTests
{
    [Fact]
    public void Percentiles()
    {
        Assert.Equal(25, LatencyStats.Percentile(new double[] { 10, 20, 30, 40 }, 0.5), 6);
        Assert.Equal(40, LatencyStats.Percentile(new double[] { 40, 10, 30, 20 }, 1), 6);
        Assert.Equal(0, LatencyStats.Percentile(Array.Empty<double>(), 0.5));
        Assert.Equal(7, LatencyStats.Percentile(new[] { 7, double.NaN }, 0.95));
    }

    [Fact]
    public void Summary()
    {
        Assert.Equal("нет данных", LatencyStats.Summary(new[] { 42.0 }));
        Assert.Equal("p50 25 ms · p95 39 ms", LatencyStats.Summary(new double[] { 10, 20, 30, 40, double.NaN }));
    }

    [Fact]
    public void Clock()
    {
        Assert.Equal("02:14:36", EngineClock.Format(TimeSpan.FromSeconds(8076)));
        Assert.Equal("00:00:00", EngineClock.Format(TimeSpan.FromSeconds(-5)));
        Assert.Equal("проверено 12 с назад", EngineClock.Since(TimeSpan.FromSeconds(12)));
        Assert.Equal("проверено 2 мин назад", EngineClock.Since(TimeSpan.FromSeconds(150)));
    }
}

public class MarkTests
{
    [Fact]
    public void Targets()
    {
        Assert.Equal(new MarkParams(0, 1, 0, null), MarkParams.Target(MarkState.Off));
        Assert.Equal(new MarkParams(16, 0, 0, null), MarkParams.Target(MarkState.On));
        Assert.Equal(new MarkParams(16, 0, 1, null), MarkParams.Target(MarkState.Problem));
        Assert.NotNull(MarkParams.Target(MarkState.Checking).Band);
    }

    [Fact]
    public void BandSweepsAcrossTheGrid()
    {
        Assert.Equal(-6, MarkGeometry.Band(0), 6);
        Assert.Equal(5, MarkGeometry.Band(MarkGeometry.SweepPeriod / 2), 6);
        Assert.Equal(-6, MarkGeometry.Band(MarkGeometry.SweepPeriod), 6);
        for (var t = 0.0; t < 2.3; t += 0.05)
        {
            var b = MarkGeometry.Band(t);
            Assert.InRange(b, -6, 16);
        }
    }

    [Fact]
    public void SpringIsCriticallyDampedAndSettles()
    {
        double x = 0, v = 0, max = 0;
        for (var i = 0; i < 120; i++)
        {
            (x, v) = Spring.Step(x, v, 16, 0.34, 1 / 60.0);
            max = Math.Max(max, x);
        }
        Assert.True(max <= 16 + 1e-9, "no overshoot");
        Assert.True(Spring.Settled(x, v, 16));
    }

    [Theory]
    [InlineData(false, false, null, false, false, false, MarkState.Off)]
    [InlineData(false, true, null, false, false, false, MarkState.Checking)]
    [InlineData(false, false, true, false, false, false, MarkState.Checking)]
    [InlineData(true, false, null, true, false, false, MarkState.Checking)]
    [InlineData(true, false, null, false, true, true, MarkState.Problem)]
    [InlineData(true, false, null, false, false, true, MarkState.Checking)]
    [InlineData(true, false, null, false, false, false, MarkState.On)]
    public void Phase(bool running, bool busy, bool? intent, bool testing, bool bad, bool checking, MarkState expected) =>
        Assert.Equal(expected, PanelPhase.Resolve(running, busy, intent, testing, bad, checking));
}
