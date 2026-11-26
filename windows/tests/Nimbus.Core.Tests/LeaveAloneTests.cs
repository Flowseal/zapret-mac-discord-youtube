using Nimbus.Core;
using Xunit;

public class LeaveAloneListTests
{
    [Fact]
    public void ParsesAddressesAndNetworksFromAnySeparator()
    {
        var r = LeaveAlone.Parse("203.0.113.7, 198.51.100.0/24;2001:db8::/32\n  192.0.2.1\t# note\n# only a comment\n");
        Assert.Equal(new[] { "203.0.113.7", "198.51.100.0/24", "2001:db8::/32", "192.0.2.1" }, r.Entries);
        Assert.Empty(r.Invalid);
    }

    [Theory]
    [InlineData("10.1.2.3/8", "10.0.0.0/8")]
    [InlineData("192.168.1.77/24", "192.168.1.0/24")]
    [InlineData("203.0.113.7/32", "203.0.113.7")]
    [InlineData("2001:DB8::1", "2001:db8::1")]
    [InlineData("2001:db8:1234::5/48", "2001:db8:1234::/48")]
    [InlineData("10.0.0.1/13", "10.0.0.0/13")]
    public void NormalizesToCanonicalForm(string input, string expected)
    {
        Assert.True(LeaveAlone.TryNormalize(input, out var normalized));
        Assert.Equal(expected, normalized);
    }

    [Theory]
    [InlineData("example.com")]
    [InlineData("1.2.3")]
    [InlineData("256.1.1.1")]
    [InlineData("203.0.113.7/33")]
    [InlineData("203.0.113.7/")]
    [InlineData("203.0.113.7/x")]
    [InlineData("0.0.0.0")]
    [InlineData("0.0.0.0/0")]
    [InlineData("::/0")]
    [InlineData("fe80::1%12")]
    [InlineData("1.2.3.4;rm")]
    [InlineData("12345")]
    public void RejectsWhatIsNotAnAddress(string input)
    {
        Assert.False(LeaveAlone.TryNormalize(input, out _));
    }

    [Fact]
    public void ReportsInvalidTokensAndDropsDuplicates()
    {
        var r = LeaveAlone.Parse("203.0.113.7 example.com 203.0.113.7 10.9.9.9/8, 10.0.0.0/8");
        Assert.Equal(new[] { "203.0.113.7", "10.0.0.0/8" }, r.Entries);
        Assert.Equal(new[] { "example.com" }, r.Invalid);
    }

    [Fact]
    public void CapsTheListSize()
    {
        var text = string.Join(" ", Enumerable.Range(1, LeaveAlone.MaxEntries + 5).Select(i => "10.0." + i + ".1"));
        var r = LeaveAlone.Parse(text);
        Assert.Equal(LeaveAlone.MaxEntries, r.Entries.Count);
        Assert.Equal(5, r.Invalid.Count);
    }

    [Fact]
    public void EmptyAndNullGiveAnEmptyList()
    {
        Assert.Empty(LeaveAlone.Parse(null).Entries);
        Assert.Empty(LeaveAlone.Parse("  \r\n ").Entries);
        Assert.Equal("", LeaveAlone.ToIpsetFile(Array.Empty<string>()));
    }

    [Fact]
    public void MergesGroupsWithoutDuplicatesOneEntryPerLine()
    {
        var text = LeaveAlone.Merge(new[] { "203.0.113.7", "10.0.0.0/8" }, new[] { "10.0.0.0/8", "198.51.100.2" });
        Assert.Equal("203.0.113.7\n10.0.0.0/8\n198.51.100.2\n", text);
    }
}

public class LeaveAloneArgumentTests
{
    private const string Base = @"C:\ProgramData\Nimbus";
    private const string Lists = @"C:\ProgramData\Nimbus\lists";
    private const string Template = "--filter-udp=443\n--dpi-desync=fake\n--new\n--filter-tcp=80,443\n--ipset-exclude=\"@LISTS@/ipset-exclude-user.txt\"\n--dpi-desync=fake\n";

    private static List<string> Build(bool leaveAlone, int? iface = null, string? game = null) =>
        EngineArguments.Build(Template, Base, Lists, EngineArguments.IpsetPath("none", Base, Lists), gameFilterMode: game, wfIface: iface, leaveAlone: leaveAlone);

    [Fact]
    public void DefaultOutputIsUnchanged()
    {
        var args = Build(false);
        Assert.DoesNotContain(args, a => a.Contains(EngineArguments.LeaveAloneFile));
        Assert.DoesNotContain(args, a => a.StartsWith("--wf-iface"));
    }

    [Fact]
    public void ExcludeIsAddedOnceAtTheStartOfEveryProfile()
    {
        var args = Build(true);
        var exclude = @"--ipset-exclude=C:\ProgramData\Nimbus\lists\ipset-exclude-vpn.txt";
        Assert.Equal(2, args.Count(a => a == exclude));
        var first = args.IndexOf(exclude);
        Assert.Equal("--filter-udp=443", args[first + 1]);
        var second = args.LastIndexOf(exclude);
        Assert.Equal("--new", args[second - 1]);
        Assert.Equal("--filter-tcp=80,443", args[second + 1]);
    }

    [Fact]
    public void GameProfilesAreCoveredToo()
    {
        var args = Build(true, game: GameFilterModes.Games);
        var profiles = args.Count(a => a == "--new") + 1;
        Assert.Equal(profiles, args.Count(a => a.EndsWith(EngineArguments.LeaveAloneFile)));
    }

    [Fact]
    public void InterfacePinComesRightAfterThePortFilters()
    {
        var args = Build(true, iface: 12);
        Assert.StartsWith("--wf-tcp=", args[0]);
        Assert.StartsWith("--wf-udp=", args[1]);
        Assert.Equal("--wf-iface=12.0", args[2]);
    }

    [Fact]
    public void ExistingUserBypassStillFollowsTheUserExclude()
    {
        var args = Build(true);
        var i = args.FindIndex(a => a.EndsWith("ipset-exclude-user.txt"));
        Assert.EndsWith("ipset-all-user.txt", args[i + 1]);
    }

    [Fact]
    public void EveryShippedStrategyGetsTheExcludeInEveryProfile()
    {
        var dir = Path.Combine(AppContext.BaseDirectory, "payload", "strategies");
        foreach (var file in Directory.GetFiles(dir, "*.conf.in"))
        {
            var args = EngineArguments.Build(File.ReadAllText(file), Base, Lists, EngineArguments.IpsetPath("none", Base, Lists), leaveAlone: true);
            Assert.Equal(args.Count(a => a == "--new") + 1, args.Count(a => a.EndsWith(EngineArguments.LeaveAloneFile)));
        }
    }
}

public class VpnEndpointTests
{
    private const string Netstat = @"
Active Connections

  Proto  Local Address          Foreign Address        State           PID
  TCP    192.168.1.5:50123      203.0.113.7:443        ESTABLISHED     4242
  TCP    192.168.1.5:50124      198.51.100.9:443       TIME_WAIT       4242
  TCP    192.168.1.5:50125      198.51.100.10:80       ESTABLISHED     1111
  TCP    [2001:db8::5]:50126    [2001:db8::7]:443      ESTABLISHED     4242
  TCP    127.0.0.1:50127        127.0.0.1:9000         ESTABLISHED     4242
  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       4242
  UDP    0.0.0.0:5353           *:*                                    4242
  UDP    192.168.1.5:50128      203.0.113.8:51820                      4242
";

    private const string RoutePrint = @"
IPv4 Route Table
===========================================================================
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.5     35
        203.0.113.7  255.255.255.255      192.168.1.1     192.168.1.5     36
      198.51.100.4  255.255.255.255      192.168.9.9     192.168.1.5     36
        192.168.1.5  255.255.255.255         On-link     192.168.1.5    291
    255.255.255.255  255.255.255.255         On-link     192.168.1.5    291
          224.0.0.0        240.0.0.0      192.168.1.1     192.168.1.5     35
";

    [Fact]
    public void ParsesNetstatRows()
    {
        var rows = VpnEndpoints.ParseNetstat(Netstat);
        Assert.Equal(8, rows.Count);
        Assert.Equal(new SocketRow("TCP", "192.168.1.5:50123", "203.0.113.7:443", "ESTABLISHED", 4242), rows[0]);
        Assert.Equal(new SocketRow("UDP", "192.168.1.5:50128", "203.0.113.8:51820", "", 4242), rows[7]);
    }

    [Fact]
    public void KeepsEstablishedRemotesOfTheGivenProcessesOnly()
    {
        var rows = VpnEndpoints.ParseNetstat(Netstat);
        var remotes = VpnEndpoints.RemotesOf(rows, new HashSet<int> { 4242 });
        Assert.Equal(new[] { "203.0.113.7", "2001:db8::7", "203.0.113.8" }, remotes);
        Assert.Empty(VpnEndpoints.RemotesOf(rows, new HashSet<int> { 7 }));
        Assert.Equal(new[] { "198.51.100.10" }, VpnEndpoints.RemotesOf(rows, new HashSet<int> { 1111 }));
    }

    [Theory]
    [InlineData("203.0.113.7:443", "203.0.113.7")]
    [InlineData("[2001:db8::7]:443", "2001:db8::7")]
    [InlineData("[fe80::1%12]:443", "fe80::1")]
    [InlineData("*:*", null)]
    [InlineData("nonsense", null)]
    public void ExtractsTheHost(string endpoint, string? expected) =>
        Assert.Equal(expected, VpnEndpoints.HostOf(endpoint)?.ToString());

    [Fact]
    public void HostRoutesThroughThePhysicalGatewayAreEndpoints()
    {
        Assert.Equal(new[] { "203.0.113.7" }, VpnEndpoints.HostRoutes(RoutePrint, "192.168.1.1"));
        Assert.Equal(new[] { "198.51.100.4" }, VpnEndpoints.HostRoutes(RoutePrint, "192.168.9.9"));
        Assert.Empty(VpnEndpoints.HostRoutes(RoutePrint, "not an address"));
    }
}

public class EnginePlanTests
{
    private static AdapterInfo Wifi(int idx = 12, bool up = true) => new("Wi-Fi", "Intel(R) Wi-Fi 6 AX201", "Wireless80211", up, idx, true);
    private static AdapterInfo Ethernet(int idx = 5) => new("Ethernet", "Realtek PCIe GbE", "Ethernet", true, idx, true);
    private static AdapterInfo Wg(int idx = 30, bool up = true) => new("wg0", "WireGuard Tunnel", "Ethernet", up, idx, false);
    private static AdapterInfo Tap(int idx = 31) => new("Local Area Connection 2", "TAP-Windows Adapter V9", "Ethernet", true, idx, false);

    [Fact]
    public void NoVpnMeansNoRestrictionAtAll()
    {
        var plan = VpnEndpoints.Plan(new[] { Wifi(), Ethernet() }, 12);
        Assert.Equal(EnginePlan.None, plan);
        Assert.Equal("-", plan.Signature);
    }

    [Fact]
    public void VpnAdapterPinsTheEngineToThePhysicalInterface()
    {
        var plan = VpnEndpoints.Plan(new[] { Wifi(), Wg() }, 12);
        Assert.Equal(12, plan.PinnedIfIndex);
        Assert.Equal(new[] { 30 }, plan.TunnelIndexes);
        Assert.Equal("if12", plan.Signature);
    }

    [Fact]
    public void RecognisesTapAndSeveralTunnels()
    {
        var plan = VpnEndpoints.Plan(new[] { Ethernet(), Tap(), Wg() }, 5);
        Assert.Equal(5, plan.PinnedIfIndex);
        Assert.Equal(new[] { 30, 31 }, plan.TunnelIndexes);
    }

    [Fact]
    public void BestInterfaceThatIsATunnelIsIgnored()
    {
        var plan = VpnEndpoints.Plan(new[] { Wifi(12), Ethernet(5), Wg() }, 30);
        Assert.Equal(5, plan.PinnedIfIndex); // lowest index among the physical adapters with a gateway
    }

    [Fact]
    public void BestInterfaceWinsWhenItIsPhysical()
    {
        var plan = VpnEndpoints.Plan(new[] { Wifi(12), Ethernet(5), Wg() }, 12);
        Assert.Equal(12, plan.PinnedIfIndex);
    }

    [Fact]
    public void DownAdaptersDoNotCount()
    {
        Assert.Equal(EnginePlan.None, VpnEndpoints.Plan(new[] { Wifi(), Wg(up: false) }, 12));
        Assert.Equal(5, VpnEndpoints.Plan(new[] { Wifi(12, up: false), Ethernet(5), Wg() }, null).PinnedIfIndex);
    }

    [Fact]
    public void WithoutAPhysicalGatewayNothingIsPinned()
    {
        var plan = VpnEndpoints.Plan(new[] { Wg() }, null);
        Assert.Null(plan.PinnedIfIndex);
        Assert.Equal(new[] { 30 }, plan.TunnelIndexes);
        Assert.Equal("-", plan.Signature);
    }

    [Fact]
    public void WarpCountsAsFullTunnelClient()
    {
        Assert.True(VpnSignatures.IsFullTunnelClient("адаптер «Cloudflare WARP»"));
        Assert.False(VpnSignatures.IsFullTunnelClient("адаптер «WireGuard Tunnel»"));
    }
}

public class MacTunnelTests
{
    private const string Ifconfig = @"lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
	inet 127.0.0.1 netmask 0xff000000
	inet6 ::1 prefixlen 128
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 192.168.1.5 netmask 0xffffff00 broadcast 192.168.1.255
utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
	inet6 fe80::1%utun0 prefixlen 64 scopeid 0xf
utun1: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 2000
	inet6 fe80::2%utun1 prefixlen 64 scopeid 0x10
utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
	inet 10.8.0.6 --> 10.8.0.5 netmask 0xffffffff
utun5: flags=8010<POINTOPOINT,MULTICAST> mtu 1500
	inet 10.9.0.2 --> 10.9.0.1 netmask 0xffffffff
utun50: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
	inet 10.77.0.1 --> 10.77.0.2 netmask 0xffffffff
utun6: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet6 fe80::3%utun6 prefixlen 64 scopeid 0x12
	inet6 2001:db8::3 prefixlen 64
ppp0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
	inet 172.16.0.9 --> 172.16.0.1 netmask 0xffffffff
";

    [Fact]
    public void FindsAddressedTunnelsAndSkipsSystemOnes()
    {
        Assert.Equal(new[] { "utun4", "utun6", "ppp0" }, VpnSignatures.MacTunnelInterfaces(Ifconfig));
    }

    [Fact]
    public void NimbusOwnInterfaceIsNotAVpn()
    {
        Assert.DoesNotContain("utun50", VpnSignatures.MacTunnelInterfaces(Ifconfig));
        Assert.Contains("utun50", VpnSignatures.MacTunnelInterfaces(Ifconfig, "utun99"));
    }

    [Theory]
    [InlineData("utun4", true)]
    [InlineData("utun", false)]
    [InlineData("ipsec0", true)]
    [InlineData("tun12", true)]
    [InlineData("tap0", true)]
    [InlineData("wg0", true)]
    [InlineData("en0", false)]
    [InlineData("bridge100", false)]
    [InlineData("utunx", false)]
    public void KnowsTunnelNames(string name, bool expected) => Assert.Equal(expected, VpnSignatures.IsMacTunnelName(name));

    [Fact]
    public void SplitTunnelIsDetectedWhileTheDefaultRouteStaysPhysical()
    {
        var m = VpnSignatures.MatchMacTunnels(new[] { "utun4" }, "en0", Array.Empty<string>());
        Assert.True(m.IsVpn);
        Assert.Equal("туннель utun4", m.Reason);
    }

    [Fact]
    public void VpnProcessIsEnoughByItself()
    {
        var m = VpnSignatures.MatchMacTunnels(Array.Empty<string>(), "en0", new[] { "Finder", "openvpn" });
        Assert.True(m.IsVpn);
        Assert.Contains("openvpn", m.Reason);
    }

    [Fact]
    public void DefaultRouteThroughATunnelStillCounts()
    {
        Assert.True(VpnSignatures.MatchMacTunnels(Array.Empty<string>(), "utun4", Array.Empty<string>()).IsVpn);
    }

    [Fact]
    public void NothingToSeeMeansNoVpn()
    {
        Assert.False(VpnSignatures.MatchMacTunnels(Array.Empty<string>(), "en0", new[] { "Finder" }).IsVpn);
    }
}
