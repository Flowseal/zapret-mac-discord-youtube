using System;
using System.Collections.Generic;
using System.Text.Json;

namespace Nimbus.Core;

public static class Versioning
{
    public static string Display(string version) =>
        version.Length > 0 && (version[0] == 'v' || version[0] == 'V') ? version[1..] : version;

    /// <summary>"v1.3.0-beta.1" -> "1.3.0": the numeric part, which is what FileVersion and CFBundleShortVersionString hold.</summary>
    public static string Bundled(string releaseVersion)
    {
        var display = Display(releaseVersion);
        var dash = display.IndexOf('-');
        return dash > 0 ? display[..dash] : display;
    }

    public static bool IsNewer(string candidateTag, string installed) =>
        Compare(candidateTag, installed) > 0;

    /// <summary>
    /// Semver-style order: 1.5.0 &lt; 1.6.0-beta.1 &lt; 1.6.0-beta.2 &lt; 1.6.0-rc.1 &lt; 1.6.0.
    /// A leading "v" and "+build" metadata are ignored.
    /// </summary>
    public static int Compare(string a, string b)
    {
        var (coreA, preA) = Split(a);
        var (coreB, preB) = Split(b);
        var core = CompareParts(coreA.Split('.'), coreB.Split('.'), padWithZero: true);
        if (core != 0) return core;
        if (preA.Length == 0 && preB.Length == 0) return 0;
        if (preA.Length == 0) return 1;  // 1.6.0 > 1.6.0-beta.1
        if (preB.Length == 0) return -1;
        return CompareParts(preA.Split('.'), preB.Split('.'), padWithZero: false);
    }

    private static (string Core, string Pre) Split(string version)
    {
        var v = Display(version.Trim());
        var plus = v.IndexOf('+');
        if (plus >= 0) v = v[..plus];
        var dash = v.IndexOf('-');
        return dash >= 0 ? (v[..dash], v[(dash + 1)..]) : (v, "");
    }

    private static int CompareParts(string[] a, string[] b, bool padWithZero)
    {
        for (var i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            if (!padWithZero && i >= a.Length) return -1;
            if (!padWithZero && i >= b.Length) return 1;
            var sa = i < a.Length ? a[i] : "0";
            var sb = i < b.Length ? b[i] : "0";
            var numA = long.TryParse(sa, out var na);
            var numB = long.TryParse(sb, out var nb);
            int c;
            if (numA && numB) c = na.CompareTo(nb);
            else if (numA != numB) c = numA ? -1 : 1; // "beta.1" < "beta.x"
            else c = Math.Sign(string.Compare(sa, sb, StringComparison.OrdinalIgnoreCase));
            if (c != 0) return c;
        }
        return 0;
    }
}

public sealed record ReleaseCandidate(string Tag, string DownloadUrl, string? Digest);

/// <summary>Picks the update from the GitHub /releases list (pre-releases included, drafts skipped).</summary>
public static class ReleaseFeed
{
    public static ReleaseCandidate? PickUpdate(string json, string assetName, string installed)
    {
        using var doc = JsonDocument.Parse(json);
        if (doc.RootElement.ValueKind != JsonValueKind.Array) return null;
        ReleaseCandidate? best = null;
        foreach (var release in doc.RootElement.EnumerateArray())
        {
            if (release.TryGetProperty("draft", out var draft) && draft.ValueKind == JsonValueKind.True) continue;
            var tag = release.TryGetProperty("tag_name", out var t) ? t.GetString() ?? "" : "";
            if (tag.Length == 0 || !Versioning.IsNewer(tag, installed)) continue;
            if (best != null && Versioning.Compare(tag, best.Tag) <= 0) continue;
            if (!release.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array) continue;
            foreach (var asset in assets.EnumerateArray())
            {
                if (asset.TryGetProperty("name", out var n) && n.GetString() == assetName
                    && asset.TryGetProperty("browser_download_url", out var u) && u.GetString() is { Length: > 0 } url)
                {
                    var digest = asset.TryGetProperty("digest", out var d) && d.ValueKind == JsonValueKind.String ? d.GetString() : null;
                    best = new ReleaseCandidate(tag, url, digest);
                    break;
                }
            }
        }
        return best;
    }
}
