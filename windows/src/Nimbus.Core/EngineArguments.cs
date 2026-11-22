namespace Nimbus.Core;

/// <summary>
/// Turns a Mac strategy template (macos/Payload/strategies/*.conf.in, nfqws syntax) into a winws.exe argument list.
/// winws shares the nfqws option parser; the only addition is the WinDivert filter (--wf-tcp/--wf-udp),
/// which mirrors the ports the Mac app redirects through pf.
/// </summary>
public static class EngineArguments
{
    public const string WinDivertTcp = "80,443,2053,2083,2087,2096,8443";
    public const string WinDivertUdp = "443,19294-19344,50000-50100";

    public static List<string> Build(string template, string baseDir, string listsDir, string ipsetPath, char separator = '\\')
    {
        var args = new List<string>
        {
            "--wf-tcp=" + WinDivertTcp,
            "--wf-udp=" + WinDivertUdp,
        };
        foreach (var raw in template.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
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
            args.Add(line);
        }
        return args;
    }

    public static string IpsetPath(string mode, string baseDir, string listsDir, char separator = '\\') => IpsetModes.Normalize(mode) switch
    {
        IpsetModes.Loaded => TrimSeparators(listsDir) + separator + "ipset-all.txt",
        IpsetModes.Any => TrimSeparators(baseDir) + separator + "ipset-any.txt",
        _ => TrimSeparators(baseDir) + separator + "ipset-none.txt",
    };

    private static string TrimSeparators(string path) => path.TrimEnd('\\', '/');
}
