using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
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
#if NIMBUS_LITE
    public const string AssetName = "Nimbus-Windows-x64-lite.exe";
#else
    public const string AssetName = "Nimbus-Windows-x64.exe";
#endif
    private const string ReleasesUrl = "https://api.github.com/repos/relocpe/Nimbus/releases";
    public const string RepoUrl = "https://github.com/relocpe/Nimbus";

    public static string CurrentVersion
    {
        get
        {
            // InformationalVersion keeps the pre-release part ("1.6.0-beta.1"), AssemblyVersion does not
            var assembly = typeof(Updater).Assembly;
            var info = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
            if (!string.IsNullOrWhiteSpace(info))
            {
                var plus = info.IndexOf('+');
                return plus >= 0 ? info[..plus] : info;
            }
            var v = assembly.GetName().Version;
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
        // pre-releases count too: 1.5.0 gets 1.6.0-beta.1, and the beta later gets 1.6.0
        var json = await client.GetStringAsync($"{ReleasesUrl}?per_page=10&t={DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}");
        var pick = ReleaseFeed.PickUpdate(json, AssetName, CurrentVersion);
        return pick == null ? null : new ReleaseInfo(pick.Tag, pick.DownloadUrl, pick.Digest);
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
        var product = info.ProductVersion ?? "";
        if (info.ProductName != "Nimbus" || version != Versioning.Bundled(release.Tag) || Versioning.Compare(product, release.Tag) != 0)
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
