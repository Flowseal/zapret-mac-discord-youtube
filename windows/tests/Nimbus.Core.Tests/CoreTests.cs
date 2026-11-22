using System.Net;
using Nimbus.Core;
using Xunit;

public class StrategyTests
{
    private static string PayloadDir => Path.Combine(AppContext.BaseDirectory, "payload");

    [Fact]
    public void ParsesSharedStrategyList()
    {
        var list = StrategyCatalog.Parse(File.ReadAllText(Path.Combine(PayloadDir, "strategies.tsv")));
        Assert.True(list.Count >= 20);
        Assert.Contains(list, s => s.Id == StrategyCatalog.DefaultId);
        foreach (var s in list)
        {
            Assert.True(StrategyCatalog.IsValidId(s.Id), s.Id);
            Assert.True(File.Exists(Path.Combine(PayloadDir, "strategies", s.Id + ".conf.in")), s.Id);
        }
    }

    [Fact]
    public void ParseIgnoresJunkAndCrlf()
    {
        var list = StrategyCatalog.Parse("a\tA\r\n\nbroken\n\tx\nb\tB (ALT)\n");
        Assert.Equal(new[] { new Strategy("a", "A"), new Strategy("b", "B (ALT)") }, list);
    }

    [Theory]
    [InlineData("general", true)]
    [InlineData("general-alt12", true)]
    [InlineData("general-fake-tls-auto-alt3", true)]
    [InlineData("../evil", false)]
    [InlineData("general/../x", false)]
    [InlineData("", false)]
    public void ValidatesIds(string id, bool ok) => Assert.Equal(ok, StrategyCatalog.IsValidId(id));

    [Fact]
    public void EveryStrategyTranslatesToWindowsPaths()
    {
        foreach (var file in Directory.GetFiles(Path.Combine(PayloadDir, "strategies"), "*.conf.in"))
        {
            var args = EngineArguments.Build(File.ReadAllText(file), @"C:\ProgramData\Nimbus", @"C:\ProgramData\Nimbus\lists",
                EngineArguments.IpsetPath("none", @"C:\ProgramData\Nimbus", @"C:\ProgramData\Nimbus\lists"));
            Assert.Equal("--wf-tcp=" + EngineArguments.WinDivertTcp, args[0]);
            Assert.Equal("--wf-udp=" + EngineArguments.WinDivertUdp, args[1]);
            foreach (var a in args)
            {
                Assert.StartsWith("--", a);
                Assert.DoesNotContain("@", a);
                Assert.DoesNotContain("\"", a);
                if (a.Contains(@"C:\"))
                {
                    Assert.DoesNotContain("/", a);
                }
            }
            Assert.Contains(args, a => a == "--new");
        }
    }

    [Fact]
    public void SubstitutesPlaceholders()
    {
        var args = EngineArguments.Build(
            "--hostlist=\"@LISTS@/list-general.txt\"\n--dpi-desync-fake-quic=\"@BASE@/bin/quic.bin\"\n--ipset=\"@IPSET@\"\n--dpi-desync=fake\n",
            @"C:\PD\Nimbus\", @"C:\PD\Nimbus\lists", @"C:\PD\Nimbus\ipset-any.txt");
        Assert.Equal(@"--hostlist=C:\PD\Nimbus\lists\list-general.txt", args[2]);
        Assert.Equal(@"--dpi-desync-fake-quic=C:\PD\Nimbus\bin\quic.bin", args[3]);
        Assert.Equal(@"--ipset=C:\PD\Nimbus\ipset-any.txt", args[4]);
        Assert.Equal("--dpi-desync=fake", args[5]);
    }

    [Theory]
    [InlineData("loaded", @"C:\L\ipset-all.txt")]
    [InlineData("any", @"C:\B\ipset-any.txt")]
    [InlineData("none", @"C:\B\ipset-none.txt")]
    [InlineData("garbage", @"C:\B\ipset-none.txt")]
    public void IpsetPaths(string mode, string expected) =>
        Assert.Equal(expected, EngineArguments.IpsetPath(mode, @"C:\B", @"C:\L"));

    [Fact]
    public void IpsetTitlesMatchMac()
    {
        Assert.Equal("Нет", IpsetModes.Title("none"));
        Assert.Equal("Стандартный", IpsetModes.Title("loaded"));
        Assert.Equal("Все", IpsetModes.Title("any"));
    }
}

public class VersionTests
{
    [Theory]
    [InlineData("v1.3.0", "1.2.0", true)]
    [InlineData("v1.2.10", "1.2.9", true)]
    [InlineData("v1.2.0", "1.2.0", false)]
    [InlineData("v1.3.0-beta.1", "1.3.0", false)]
    [InlineData("v1.3.0-beta.1", "1.2.0", true)]
    [InlineData("1.1.2", "1.2.0", false)]
    public void ComparesLikeMacUpdater(string tag, string installed, bool newer) =>
        Assert.Equal(newer, Versioning.IsNewer(tag, installed));

    [Fact]
    public void StripsPrefixAndSuffix()
    {
        Assert.Equal("1.3.0", Versioning.Bundled("v1.3.0-rc"));
        Assert.Equal("1.3.0-rc", Versioning.Display("V1.3.0-rc"));
    }
}

public class ScoringTests
{
    [Fact]
    public void TiesBrokenByTlsThenListed()
    {
        var best = new BestTracker();
        best.Add(new StrategyResult("general", 10, 27, 5));
        best.Add(new StrategyResult("general (ALT)", 12, 27, 6));
        best.Add(new StrategyResult("general (ALT2)", 12, 27, 7));
        best.Add(new StrategyResult("general (ALT3)", 12, 27, 7));
        best.Add(new StrategyResult("broken", 0, 0, 0, Error: true));
        Assert.Equal("Лучшая: general (ALT2), general (ALT3) (12/27)", best.Summary(27, false));
        Assert.True(best.IsBest("general (ALT2)"));
        Assert.False(best.IsBest("general")); // the Mac app's substring check would say true here
        Assert.Equal("Остановлено", best.Summary(27, true));
        var summary = best.Summary(27, false);
        Assert.True(BestTracker.IsBestInSummary(summary, "general (ALT3)"));
        Assert.False(BestTracker.IsBestInSummary(summary, "general"));
        Assert.False(BestTracker.IsBestInSummary("Лучшая: не определена", "general"));
    }

    [Fact]
    public void NoResults() => Assert.Equal("Лучшая: не определена", new BestTracker().Summary(0, false));

    [Fact]
    public void ScoreText()
    {
        Assert.Equal("3/9", new StrategyResult("x", 3, 9, 1).ScoreText);
        Assert.Equal("ошибка", new StrategyResult("x", 0, 0, 0, true).ScoreText);
    }
}

public class ListTests
{
    [Fact]
    public void DescribesLikeMac()
    {
        var small = ListCatalog.Describe("list-general-user.txt", 20, "a.com\n\n  \nb.com\n");
        Assert.Equal(new ListInfo("list-general-user.txt", "Основные", "2 строк", "свои", false), small);
        var big = ListCatalog.Describe("ipset-all.txt", 500_000, "1.1.1.1\n");
        Assert.True(big.External);
        Assert.Equal("1 строк · открыть", big.Detail);
        Assert.Equal("IP-набор", big.Title);
    }

    [Fact]
    public void NormalizesNewlines() => Assert.Equal("a\nb\nc", ListCatalog.NormalizeForSave("a\r\nb\rc"));
}

public class DnsTests
{
    [Fact]
    public void BuildsQuery()
    {
        var q = DnsClient.BuildQuery(0x1234, "youtu.be");
        Assert.Equal(new byte[] { 0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 5, (byte)'y', (byte)'o', (byte)'u', (byte)'t', (byte)'u', 2, (byte)'b', (byte)'e', 0, 0, 1, 0, 1 }, q);
    }

    [Fact]
    public void ParsesCompressedAnswersAndSkipsCname()
    {
        var q = DnsClient.BuildQuery(7, "www.youtube.com");
        var r = new List<byte>(q);
        r[2] = 0x81; r[3] = 0x80; // response, no error
        r[7] = 3; // ANCOUNT
        // CNAME answer pointing at the question name
        r.AddRange(new byte[] { 0xC0, 12, 0, 5, 0, 1, 0, 0, 0, 60, 0, 2, 0xC0, 12 });
        // two A answers
        r.AddRange(new byte[] { 0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 142, 250, 74, 46 });
        r.AddRange(new byte[] { 0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 142, 250, 74, 78 });
        var ips = DnsClient.ParseA(r.ToArray(), 7);
        Assert.Equal(new[] { IPAddress.Parse("142.250.74.46"), IPAddress.Parse("142.250.74.78") }, ips);
        Assert.Empty(DnsClient.ParseA(r.ToArray(), 8));
    }

    [Fact]
    public void RejectsErrorsAndTruncation()
    {
        var q = DnsClient.BuildQuery(9, "a.b");
        var r = (byte[])q.Clone();
        r[3] = 0x83; // NXDOMAIN
        Assert.Empty(DnsClient.ParseA(r, 9));
        Assert.Empty(DnsClient.ParseA(new byte[] { 0, 9, 0 }, 9));
    }
}
