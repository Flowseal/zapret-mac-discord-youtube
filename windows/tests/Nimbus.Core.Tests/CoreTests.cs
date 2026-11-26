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

    [Fact]
    public void GameFilterTitlesAndPorts()
    {
        Assert.Equal("Выкл", GameFilterModes.Title(null));
        Assert.Equal("Выкл", GameFilterModes.Title("garbage"));
        Assert.Equal("Игры", GameFilterModes.Title(GameFilterModes.Games));
        Assert.Equal("Широкий", GameFilterModes.Title(GameFilterModes.Wide));
        Assert.False(GameFilterModes.IsOn("off"));
        Assert.True(GameFilterModes.IsOn("games"));
        Assert.Equal((GameFilterModes.GamesTcp, GameFilterModes.GamesUdp), GameFilterModes.Ports(GameFilterModes.Games));
        Assert.Equal((GameFilterModes.WidePorts, GameFilterModes.WidePorts), GameFilterModes.Ports(GameFilterModes.Wide));
        Assert.Null(GameFilterModes.Ports(GameFilterModes.Off));
    }

    [Theory]
    [InlineData("off", "80,443,2053,2083,2087,2096,8443", "443,19294-19344,50000-50100", false)]
    [InlineData("games", "80,443,2053,2083,2087,2096,8443,3074,3075,1119,3724", "443,19294-19344,50000-50100,3074,3075,3478-3480,3659,4379-4380,27000-27050", true)]
    [InlineData("wide", "80,443,2053,2083,2087,2096,8443,1024-65535", "443,19294-19344,50000-50100,1024-65535", true)]
    public void GameFilterModesChangeWinDivertAndProfiles(string mode, string tcp, string udp, bool active)
    {
        var args = EngineArguments.Build(
            "--dpi-desync=fake\n--new\n--filter-tcp=443\n--ipset=\"@IPSET@\"\n",
            @"C:\PD\Nimbus", @"C:\PD\Nimbus\lists", @"C:\PD\Nimbus\lists\ipset-all.txt",
            gameFilterMode: mode);
        Assert.Equal("--wf-tcp=" + tcp, args[0]);
        Assert.Equal("--wf-udp=" + udp, args[1]);
        Assert.DoesNotContain(args, a => a == "--filter-tcp=12" || a == "--filter-udp=12");
        if (!active)
        {
            Assert.DoesNotContain(args, a => a.Contains("dpi-desync-any-protocol"));
            Assert.DoesNotContain(args, a => a.Contains("ACTIVE_GAME_UDP.bin"));
            return;
        }
        Assert.Contains("--dpi-desync-any-protocol=1", args);
        Assert.Contains("--dpi-desync-cutoff=n4", args);
        Assert.Contains("--dpi-desync-cutoff=n3", args);
        Assert.Contains("--dpi-desync-repeats=6", args);
        Assert.Contains("--dpi-desync-repeats=12", args);
        Assert.Contains("--dpi-desync-fooling=ts", args);
        Assert.Contains(@"--dpi-desync-fake-unknown-udp=C:\PD\Nimbus\bin\ACTIVE_GAME_UDP.bin", args);
        Assert.Contains(@"--ipset=C:\PD\Nimbus\lists\ipset-all.txt", args);
        Assert.Contains(@"--ipset-exclude=C:\PD\Nimbus\lists\ipset-exclude-user.txt", args);
        Assert.Contains("--filter-tcp=" + (mode == "wide" ? GameFilterModes.WidePorts : GameFilterModes.GamesTcp), args);
        Assert.Contains("--filter-udp=" + (mode == "wide" ? GameFilterModes.WidePorts : GameFilterModes.GamesUdp), args);
        foreach (var a in args)
        {
            Assert.StartsWith("--", a);
            Assert.DoesNotContain("@", a);
            Assert.DoesNotContain("\"", a);
        }
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
        Assert.Equal(new ListInfo("list-general-user.txt", "Основные", "2 строк", "свои", false, 2), small);
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

public class HostEntryTests
{
    [Theory]
    [InlineData("https://youtu.be/dQw4w9WgXcQ?t=1", "youtu.be")]
    [InlineData("http://WWW.YouTube.com/watch?v=1", "www.youtube.com")]
    [InlineData("www.discord.com/invite/x", "www.discord.com")]
    [InlineData("discord.com:443", "discord.com")]
    [InlineData("  Open.spotify.com.  ", "open.spotify.com")]
    [InlineData("chatgpt.com", "chatgpt.com")]
    public void NormalizesUrlsAndDomains(string input, string expected)
    {
        var parsed = HostEntry.Parse(input);
        Assert.NotNull(parsed);
        Assert.Equal(HostKind.Domain, parsed!.Kind);
        Assert.Equal(expected, parsed.Value);
    }

    [Fact]
    public void ConvertsCyrillicToPunycode()
    {
        var parsed = HostEntry.Parse("https://пример.рф/path");
        Assert.NotNull(parsed);
        Assert.Equal(HostKind.Domain, parsed!.Kind);
        Assert.Equal("xn--e1afmkfd.xn--p1ai", parsed.Value);
        Assert.Equal(parsed.Value, HostEntry.Normalize("пример.рф"));
    }

    [Theory]
    [InlineData("1.2.3.4", HostKind.IPv4, "1.2.3.4")]
    [InlineData("1.2.3.0/24", HostKind.IPv4, "1.2.3.0/24")]
    [InlineData("2001:db8::1", HostKind.IPv6, "2001:db8::1")]
    [InlineData("[2001:db8::1]:443", HostKind.IPv6, "2001:db8::1")]
    [InlineData("2001:db8::/32", HostKind.IPv6, "2001:db8::/32")]
    public void ParsesAddresses(string input, HostKind kind, string expected)
    {
        var parsed = HostEntry.Parse(input);
        Assert.NotNull(parsed);
        Assert.Equal(kind, parsed!.Kind);
        Assert.Equal(expected, parsed.Value);
        Assert.True(parsed.IsIp);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("https://")]
    [InlineData("not a host")]
    [InlineData("-bad.com")]
    [InlineData("localhost")]
    [InlineData("1.2.3.4/33")]
    [InlineData("999.1.1.1")]
    [InlineData("ftp://example.com")]
    public void RejectsJunk(string input) => Assert.Null(HostEntry.Parse(input));
}

public class UserListTests
{
    [Fact]
    public void AddsAndRemovesWithoutDupes()
    {
        var text = UserLists.Add("", "example.com");
        text = UserLists.Add(text, "example.com");
        text = UserLists.Add(text, "other.com");
        Assert.Equal("example.com\nother.com\n", text);
        Assert.True(UserLists.Contains(text, "EXAMPLE.com"));
        text = UserLists.Remove(text, "example.com");
        Assert.Equal("other.com\n", text);
        Assert.Equal(UserLists.BypassDomains, UserLists.FileFor(HostKind.Domain, false));
        Assert.Equal(UserLists.ExcludeIpset, UserLists.FileFor(HostKind.IPv4, true));
        Assert.Equal(UserLists.BypassIpset, UserLists.FileFor(HostKind.IPv6, false));
    }
}

public class ListUpdaterTests
{
    [Fact]
    public void AcceptsBundledUpstreamLists()
    {
        var dir = Path.Combine(AppContext.BaseDirectory, "payload", "default-lists");
        foreach (var name in ListUpdater.UpstreamFiles)
        {
            var check = ListUpdater.Validate(name, File.ReadAllText(Path.Combine(dir, name)));
            Assert.True(check.Ok, name + ": " + check.Reason);
        }
    }

    [Fact]
    public void RejectsHtmlEmptyAndUserFiles()
    {
        Assert.False(ListUpdater.Validate("list-general.txt", "<html>404</html>").Ok);
        Assert.False(ListUpdater.Validate("list-general.txt", "").Ok);
        Assert.False(ListUpdater.Validate("list-general-user.txt", "example.com\n").Ok);
        Assert.False(ListUpdater.Validate("mystery.txt", "example.com\n").Ok);
        Assert.False(ListUpdater.Validate("list-general.txt", "?????\n%%%%%\n#####\nnot a domain_at_all\n").Ok);
    }

    [Fact]
    public void AppliesAtomicallyAndBacksUpWithoutTouchingUserFiles()
    {
        var root = Path.Combine(Path.GetTempPath(), "nimbus-lists-" + Guid.NewGuid().ToString("N"));
        var lists = Path.Combine(root, "lists");
        var backup = Path.Combine(root, "backup");
        Directory.CreateDirectory(lists);
        File.WriteAllText(Path.Combine(lists, "list-general.txt"), "old.com\n");
        File.WriteAllText(Path.Combine(lists, "list-general-user.txt"), "keep.me\n");
        ListUpdater.Apply(lists, new Dictionary<string, string>
        {
            ["list-general.txt"] = "fresh.example\n# comment\n",
        }, backup);
        Assert.Equal("fresh.example\n# comment\n", File.ReadAllText(Path.Combine(lists, "list-general.txt")));
        Assert.Equal("old.com\n", File.ReadAllText(Path.Combine(backup, "list-general.txt")));
        Assert.Equal("keep.me\n", File.ReadAllText(Path.Combine(lists, "list-general-user.txt")));
        var ex = Assert.Throws<InvalidOperationException>(() =>
            ListUpdater.Apply(lists, new Dictionary<string, string> { ["list-general-user.txt"] = "nope.com\n" }, backup));
        Assert.Contains("user", ex.Message, StringComparison.OrdinalIgnoreCase);
        Directory.Delete(root, true);
    }
}

public class VpnSignatureTests
{
    [Theory]
    [InlineData("Cloudflare WARP", "Cloudflare WARP", true)]
    [InlineData("WireGuard Tunnel", "WireGuard Tunnel", true)]
    [InlineData("wintun", "Wintun Userspace Tunnel", true)]
    [InlineData("OpenVPN TAP", "TAP-Windows Adapter V9", true)]
    [InlineData("sing-box tun", "sing-box", true)]
    [InlineData("AmneziaVPN", "AmneziaWG", true)]
    [InlineData("Ethernet", "Intel(R) Ethernet Connection", false)]
    [InlineData("Wi-Fi", "Intel Wi-Fi 6", false)]
    [InlineData("Teredo Tunneling Pseudo-Interface", "Microsoft Teredo", false)]
    public void DetectsAdapters(string name, string description, bool vpn)
    {
        Assert.Equal(vpn, VpnSignatures.MatchAdapter(name, description).IsVpn);
    }

    [Fact]
    public void DetectsProcessesAndMacRoutes()
    {
        Assert.True(VpnSignatures.MatchProcess("WireGuard.exe").IsVpn);
        Assert.True(VpnSignatures.MatchProcess("CloudflareWARP").IsVpn);
        Assert.False(VpnSignatures.MatchProcess("Nimbus").IsVpn);
        Assert.True(VpnSignatures.MatchMacDefaultRoute("utun3").IsVpn);
        Assert.False(VpnSignatures.MatchMacDefaultRoute("utun50").IsVpn);
        Assert.False(VpnSignatures.MatchMacDefaultRoute("en0").IsVpn);
        Assert.True(VpnSignatures.MatchMacDefaultRoute("ipsec0").IsVpn);
    }
}

public class StrategyOrderTests
{
    private static readonly IReadOnlyList<Strategy> Sample =
    [
        new("general-alt9", "general (ALT9)"),
        new("general-simple-fake", "general (SIMPLE FAKE)"),
        new("general-alt", "general (ALT)"),
        new("general", "general"),
        new("general-exp", "general (EXP)"),
        new("general-fake-tls-auto", "general (FAKE TLS AUTO)"),
        new("general-alt2", "general (ALT2)"),
    ];

    [Fact]
    public void PutsCurrentThenWinnersThenPreferredFirst()
    {
        var ordered = StrategyOrder.ForSmart(Sample, "general-exp", ["general (ALT9)", "missing"]);
        Assert.Equal(new[]
        {
            "general-exp",
            "general-alt9",
            "general-simple-fake",
            "general",
            "general-alt",
            "general-fake-tls-auto",
            "general-alt2",
        }, ordered.Select(s => s.Id).ToArray());
        Assert.Equal(Sample.Count, ordered.Count);
        Assert.Equal(Sample.Select(s => s.Id).OrderBy(x => x), ordered.Select(s => s.Id).OrderBy(x => x));
    }

    [Fact]
    public void ParsesWinnersAndProgress()
    {
        Assert.Equal(new[] { "general (ALT2)", "general (ALT3)" }, StrategyOrder.ParseWinners("Лучшая: general (ALT2), general (ALT3) (12/27)"));
        Assert.Empty(StrategyOrder.ParseWinners("Лучшая: не определена"));
        Assert.True(StrategyOrder.TryParseProgress("Стратегия 4/21: general (ALT3)", out var current, out var total));
        Assert.Equal(4, current);
        Assert.Equal(21, total);
        Assert.Equal(0.25, StrategyOrder.ProgressFraction("4 / 16"), 3);
    }

    [Fact]
    public void SmartPassNeedsDiscordAndYouTube()
    {
        var tls = new Dictionary<string, bool>
        {
            ["discord.com"] = true,
            ["www.youtube.com"] = true,
        };
        Assert.True(StrategyOrder.PassesSmart(tls));
        tls["www.youtube.com"] = false;
        Assert.False(StrategyOrder.PassesSmart(tls));
        tls["www.youtube.com"] = true;
        Assert.False(StrategyOrder.PassesSmart(tls, "chatgpt.com"));
        tls["chatgpt.com"] = true;
        Assert.True(StrategyOrder.PassesSmart(tls, "https://chatgpt.com/app"));
    }
}

public class DiagnosticReportTests
{
    [Fact]
    public void FormatsRows()
    {
        var text = DiagnosticReport.Format("Nimbus 1.5.0", new[]
        {
            new DiagnosticRow("TCP timestamps", DiagnosticLevel.Pass, "включены"),
            new DiagnosticRow("VPN", DiagnosticLevel.Warn, "WireGuard"),
            new DiagnosticRow("winws", DiagnosticLevel.Fail, "конфликт"),
        });
        Assert.Contains("[OK] TCP timestamps — включены", text);
        Assert.Contains("[WARN] VPN — WireGuard", text);
        Assert.Contains("[FAIL] winws — конфликт", text);
    }
}
