using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading.Tasks;
using Nimbus.Core;

namespace Nimbus;

internal sealed record ReleaseInfo(string Tag, string DownloadUrl, string? Digest);

/// <summary>Same flow as the Mac updater: newest release of relocpe/Nimbus, its Windows asset, sha256 digest check, swap, relaunch.</summary>
internal static class Updater
{
    public const string AssetName = "Nimbus-Windows-x64.exe";
    private const string ReleasesUrl = "https://api.github.com/repos/relocpe/Nimbus/releases";
    public const string RepoUrl = "https://github.com/relocpe/Nimbus";

    public static string CurrentVersion
    {
        get
        {
            var v = typeof(Updater).Assembly.GetName().Version;
            return v == null ? "—" : $"{v.Major}.{v.Minor}.{v.Build}";
        }
    }

    private static HttpClient Client()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(12) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Nimbus");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return client;
    }

    /// <summary>Returns the newer release, null when up to date; throws when the check itself failed.</summary>
    public static async Task<ReleaseInfo?> CheckAsync()
    {
        using var client = Client();
        var json = await client.GetStringAsync($"{ReleasesUrl}?per_page=1&t={DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}");
        using var doc = JsonDocument.Parse(json);
        if (doc.RootElement.GetArrayLength() == 0) return null;
        var latest = doc.RootElement[0];
        var tag = latest.GetProperty("tag_name").GetString() ?? "";
        if (!Versioning.IsNewer(tag, CurrentVersion)) return null;
        foreach (var asset in latest.GetProperty("assets").EnumerateArray())
        {
            if (asset.GetProperty("name").GetString() != AssetName) continue;
            var url = asset.GetProperty("browser_download_url").GetString();
            var digest = asset.TryGetProperty("digest", out var d) && d.ValueKind == JsonValueKind.String ? d.GetString() : null;
            return url == null ? null : new ReleaseInfo(tag, url, digest);
        }
        return null;
    }

    /// <summary>Downloads and verifies the new exe, swaps it in place and starts it. The caller exits afterwards.</summary>
    public static async Task InstallAsync(ReleaseInfo release)
    {
        var exe = Paths.ExecutablePath;
        var download = Path.Combine(Path.GetTempPath(), $"Nimbus-{Guid.NewGuid():N}.exe");
        try
        {
            using (var client = Client())
            {
                client.Timeout = TimeSpan.FromMinutes(3);
                using var response = await client.GetAsync(release.DownloadUrl, HttpCompletionOption.ResponseHeadersRead);
                response.EnsureSuccessStatusCode();
                await using var file = File.Create(download);
                await response.Content.CopyToAsync(file);
            }
            Verify(download, release);

            var old = exe + ".old";
            if (File.Exists(old)) File.Delete(old);
            File.Move(exe, old); // a running exe can be renamed, not overwritten
            try
            {
                File.Copy(download, exe, false);
            }
            catch
            {
                File.Move(old, exe, true);
                throw;
            }
            var psi = new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(exe)! };
            psi.ArgumentList.Add("--updated");
            Process.Start(psi)?.Dispose();
        }
        finally
        {
            try { File.Delete(download); } catch { }
        }
    }

    private static void Verify(string file, ReleaseInfo release)
    {
        if (release.Digest is { } digest && digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
        {
            using var stream = File.OpenRead(file);
            var actual = Convert.ToHexString(SHA256.HashData(stream));
            if (!actual.Equals(digest[7..], StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("Контрольная сумма обновления не совпала");
            }
        }
        var info = FileVersionInfo.GetVersionInfo(file);
        var version = $"{info.FileMajorPart}.{info.FileMinorPart}.{info.FileBuildPart}";
        if (info.ProductName != "Nimbus" || version != Versioning.Bundled(release.Tag))
        {
            throw new InvalidOperationException("Файл релиза содержит неподходящую версию приложения");
        }
    }

    public static void CleanupOldBinary()
    {
        try
        {
            var old = Paths.ExecutablePath + ".old";
            if (File.Exists(old)) File.Delete(old);
        }
        catch
        {
            // still locked by the previous process; next start will retry
        }
    }
}
