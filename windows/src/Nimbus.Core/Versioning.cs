namespace Nimbus.Core;

public static class Versioning
{
    public static string Display(string version) =>
        version.Length > 0 && (version[0] == 'v' || version[0] == 'V') ? version[1..] : version;

    /// <summary>"v1.3.0-beta.1" -> "1.3.0", same as the Mac updater's bundledVersion.</summary>
    public static string Bundled(string releaseVersion)
    {
        var display = Display(releaseVersion);
        var dash = display.IndexOf('-');
        return dash > 0 ? display[..dash] : display;
    }

    public static bool IsNewer(string candidateTag, string installed) =>
        Compare(Bundled(candidateTag), Bundled(installed)) > 0;

    public static int Compare(string a, string b)
    {
        var pa = a.Split('.');
        var pb = b.Split('.');
        for (var i = 0; i < Math.Max(pa.Length, pb.Length); i++)
        {
            var sa = i < pa.Length ? pa[i] : "0";
            var sb = i < pb.Length ? pb[i] : "0";
            if (long.TryParse(sa, out var na) && long.TryParse(sb, out var nb))
            {
                if (na != nb) return na.CompareTo(nb);
            }
            else
            {
                var c = string.Compare(sa, sb, StringComparison.OrdinalIgnoreCase);
                if (c != 0) return c;
            }
        }
        return 0;
    }
}
