namespace Nimbus.Core;

/// <summary>
/// Turns a Mac strategy template (macos/Payload/strategies/*.conf.in, nfqws syntax) into a winws.exe argument list.
/// winws shares the nfqws option parser; the only addition is the WinDivert filter (--wf-tcp/--wf-udp),
/// which mirrors the ports the Mac app redirects through pf. On Windows, an optional Game Filter can
/// widen those ports and append two any-protocol desync profiles for game traffic.
/// </summary>
public static class EngineArguments
{
    public const string WinDivertTcp = "80,443,2053,2083,2087,2096,8443";
    public const string WinDivertUdp = "443,19294-19344,50000-50100";

    /// <summary>Addresses the engine leaves alone (VPN servers found at runtime plus the user's own list); rewritten while the engine runs.</summary>
    public const string LeaveAloneFile = "ipset-exclude-vpn.txt";

    /// <param name="wfIface">Pins the WinDivert filter to one interface (used while a VPN adapter is up, so tunnel traffic is never diverted).</param>
    /// <param name="leaveAlone">Adds <see cref="LeaveAloneFile"/> as an IP exclude to every profile.</param>
    public static List<string> Build(string template, string baseDir, string listsDir, string ipsetPath, char separator = '\\', string? gameFilterMode = null,
        int? wfIface = null, bool leaveAlone = false)
    {
        var ports = GameFilterModes.Ports(gameFilterMode);
        var args = new List<string>
        {
            "--wf-tcp=" + WinDivertTcp + (ports == null ? "" : "," + ports.Value.Tcp),
            "--wf-udp=" + WinDivertUdp + (ports == null ? "" : "," + ports.Value.Udp),
        };
        if (wfIface is { } index) args.Add("--wf-iface=" + index + ".0");
        var profileStart = leaveAlone;
        foreach (var raw in template.Split('\n')) Append(args, raw, baseDir, listsDir, ipsetPath, separator, leaveAlone, ref profileStart);
        if (ports is { } game)
        {
            foreach (var raw in GameProfiles(game.Tcp, game.Udp)) Append(args, raw, baseDir, listsDir, ipsetPath, separator, leaveAlone, ref profileStart);
        }
        return args;
    }

    public static string IpsetPath(string mode, string baseDir, string listsDir, char separator = '\\') => IpsetModes.Normalize(mode) switch
    {
        IpsetModes.Loaded => TrimSeparators(listsDir) + separator + "ipset-all.txt",
        IpsetModes.Any => TrimSeparators(baseDir) + separator + "ipset-any.txt",
        _ => TrimSeparators(baseDir) + separator + "ipset-none.txt",
    };

    private static IEnumerable<string> GameProfiles(string tcp, string udp)
    {
        yield return "--new";
        yield return "--filter-tcp=" + tcp;
        yield return "--ipset=\"@IPSET@\"";
        yield return "--ipset-exclude=\"@LISTS@/ipset-exclude.txt\"";
        yield return "--ipset-exclude=\"@LISTS@/ipset-exclude-user.txt\"";
        yield return "--dpi-desync=fake";
        yield return "--dpi-desync-repeats=6";
        yield return "--dpi-desync-any-protocol=1";
        yield return "--dpi-desync-cutoff=n4";
        yield return "--dpi-desync-fooling=ts";
        yield return "--dpi-desync-fake-tls=\"@BASE@/bin/tls_clienthello_www_google_com.bin\"";
        yield return "--dpi-desync-fake-http=\"@BASE@/bin/tls_clienthello_max_ru.bin\"";
        yield return "--dpi-desync-fake-unknown=\"@BASE@/bin/stun2.bin\"";
        yield return "--new";
        yield return "--filter-udp=" + udp;
        yield return "--ipset=\"@IPSET@\"";
        yield return "--ipset-exclude=\"@LISTS@/ipset-exclude.txt\"";
        yield return "--ipset-exclude=\"@LISTS@/ipset-exclude-user.txt\"";
        yield return "--dpi-desync=fake";
        yield return "--dpi-desync-repeats=12";
        yield return "--dpi-desync-any-protocol=1";
        yield return "--dpi-desync-fake-unknown-udp=\"@BASE@/bin/ACTIVE_GAME_UDP.bin\"";
        yield return "--dpi-desync-cutoff=n3";
    }

    private static void Append(List<string> args, string raw, string baseDir, string listsDir, string ipsetPath, char separator, bool leaveAlone, ref bool profileStart)
    {
        var line = Translate(raw, baseDir, listsDir, ipsetPath, separator);
        if (line == null) return;
        if (line == "--new")
        {
            args.Add(line);
            profileStart = leaveAlone;
            return;
        }
        if (profileStart)
        {
            args.Add("--ipset-exclude=" + TrimSeparators(listsDir) + separator + LeaveAloneFile);
            profileStart = false;
        }
        args.Add(line);
        // Always attach the user IP bypass list to the same profile that already has IP excludes.
        if (line.StartsWith("--ipset-exclude=", StringComparison.Ordinal) && line.EndsWith("ipset-exclude-user.txt", StringComparison.Ordinal))
        {
            args.Add("--ipset=" + TrimSeparators(listsDir) + separator + "ipset-all-user.txt");
        }
    }

    private static string? Translate(string raw, string baseDir, string listsDir, string ipsetPath, char separator)
    {
        var line = raw.Trim();
        if (line.Length == 0 || line.StartsWith('#')) return null;
        var hasPath = line.Contains("@BASE@") || line.Contains("@LISTS@") || line.Contains("@IPSET@");
        line = line
            .Replace("@BASE@", TrimSeparators(baseDir))
            .Replace("@LISTS@", TrimSeparators(listsDir))
            .Replace("@IPSET@", ipsetPath);
        var eq = line.IndexOf('=');
        if (eq > 0)
        {
            var key = line[..eq];
            var value = line[(eq + 1)..];
            if (value.Length >= 2 && value[0] == '"' && value[^1] == '"')
            {
                value = value[1..^1];
            }
            if (hasPath)
            {
                value = value.Replace('/', separator).Replace('\\', separator);
            }
            line = key + "=" + value;
        }
        return line;
    }

    private static string TrimSeparators(string path) => path.TrimEnd('\\', '/');
}
