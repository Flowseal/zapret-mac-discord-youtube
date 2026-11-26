using System;
using System.IO;

namespace Nimbus;

/// <summary>
/// Layout mirrors the Mac app: per-user settings and lists in the roaming profile
/// (~/Library/Application Support/ZapretMac on macOS), engine files in a machine-wide folder
/// (/Library/Application Support/ZapretMac on macOS).
/// </summary>
internal static class Paths
{
    public static string DataRoot { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Nimbus");

    public static string UserLists => Path.Combine(DataRoot, "lists");

    public static string Base { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Nimbus");

    public static string BinDir => Path.Combine(Base, "bin");
    public static string RuntimeLists => Path.Combine(Base, "lists");
    public static string Winws => Path.Combine(BinDir, "winws.exe");
    public static string EngineArgs => Path.Combine(Base, "winws-args.txt");
    public static string EngineLog => Path.Combine(Base, "engine.log");
    public static string AppLog => Path.Combine(Base, "nimbus.log");

    public static string SelectedStrategy => Path.Combine(DataRoot, "selected-strategy");
    public static string IpsetMode => Path.Combine(DataRoot, "ipset-mode");
    public static string GameFilterMode => Path.Combine(DataRoot, "game-filter-mode");
    public static string VpnAutoPause => Path.Combine(DataRoot, "vpn-autopause");
    /// <summary>"Не трогать адреса": the user's own list of addresses and networks to leave alone.</summary>
    public static string LeaveAlone => Path.Combine(DataRoot, "leave-alone");
    /// <summary>Interface plan the running engine was started with, see <see cref="Nimbus.Core.EnginePlan"/>.</summary>
    public static string EnginePlanFile => Path.Combine(Base, "engine-plan");
    public static string EngineEnabled => Path.Combine(DataRoot, "engine-enabled");
    public static string TestReport => Path.Combine(DataRoot, "strategy-test.txt");
    public static string UpdateError => Path.Combine(DataRoot, "update-error");

    public static string ExecutablePath => Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "Nimbus.exe");
}

internal static class State
{
    public static string Read(string path)
    {
        try { return File.ReadAllText(path).Trim(); }
        catch { return ""; }
    }

    public static void Write(string path, string value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, value + "\n");
        File.Move(tmp, path, true);
    }
}

internal static class Log
{
    private static readonly object Gate = new();

    public static void Write(string message) => Append(Paths.AppLog, message);

    public static void Append(string file, string message)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(file)!);
                using var stream = new FileStream(file, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
                using var writer = new StreamWriter(stream);
                writer.WriteLine($"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}");
            }
        }
        catch
        {
            // logging must never break the app
        }
    }

    public static void TrimIfLarge(string file, long maxBytes = 1_000_000)
    {
        try
        {
            var info = new FileInfo(file);
            if (!info.Exists || info.Length <= maxBytes) return;
            var text = File.ReadAllText(file);
            File.WriteAllText(file, text[^(int)(maxBytes / 2)..]);
        }
        catch
        {
        }
    }

    public static string Tail(string file, int lines)
    {
        try
        {
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream);
            var all = reader.ReadToEnd().Replace("\r\n", "\n").TrimEnd('\n').Split('\n');
            return string.Join("\n", all[Math.Max(0, all.Length - lines)..]);
        }
        catch
        {
            return "";
        }
    }
}
