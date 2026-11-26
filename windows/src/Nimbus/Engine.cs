using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using Nimbus.Core;

namespace Nimbus;

/// <summary>
/// Windows counterpart of install.sh / run.sh / stop.sh: winws.exe + WinDivert instead of utunws + pf.
/// winws runs under a small detached "engine host" (Nimbus.exe --engine-host) that pipes its output into
/// engine.log, so the engine keeps running after the window app quits, like the Mac LaunchDaemon.
/// </summary>
internal static class Engine
{
    private const string ProcessName = "winws";

    public static bool IsRunning
    {
        get
        {
            var processes = Process.GetProcessesByName(ProcessName);
            foreach (var p in processes) p.Dispose();
            return processes.Length > 0;
        }
    }

    /// <summary>Interface plan the running engine was started with; empty when unknown.</summary>
    public static string RunningPlan => State.Read(Paths.EnginePlanFile);

    public static void Stop()
    {
        foreach (var process in Process.GetProcessesByName(ProcessName))
        {
            try
            {
                process.Kill(true);
                process.WaitForExit(3000);
            }
            catch (Exception ex)
            {
                Log.Write("stop: " + ex.Message);
            }
            finally
            {
                process.Dispose();
            }
        }
    }

    /// <summary>Starts winws with the given strategy; throws with the engine log tail when it does not stay up.</summary>
    public static void Start(string strategyId, string ipsetMode, bool prepare = true, string? gameFilterMode = null, NetworkSnapshot? network = null)
    {
        if (!StrategyCatalog.IsValidId(strategyId)) strategyId = StrategyCatalog.DefaultId;
        var gameFilter = GameFilterModes.Normalize(gameFilterMode);
        Stop();
        if (prepare) PrepareFiles();
        CopyLists();

        string template;
        try
        {
            template = Payload.ReadText($"payload/strategies/{strategyId}.conf.in");
        }
        catch (FileNotFoundException)
        {
            strategyId = StrategyCatalog.DefaultId;
            template = Payload.ReadText($"payload/strategies/{strategyId}.conf.in");
        }

        var ipset = EngineArguments.IpsetPath(ipsetMode, Paths.Base, Paths.RuntimeLists);
        var snapshot = network ?? Tunnels.Capture();
        Tunnels.WriteLeaveAloneFile(snapshot.Endpoints);
        var args = EngineArguments.Build(template, Paths.Base, Paths.RuntimeLists, ipset, gameFilterMode: gameFilter,
            wfIface: snapshot.Plan.PinnedIfIndex, leaveAlone: true);
        File.WriteAllLines(Paths.EngineArgs, args, new UTF8Encoding(false));
        State.Write(Paths.EnginePlanFile, snapshot.Plan.Signature);
        if (snapshot.Plan.TunnelIndexes.Count > 0)
        {
            Log.Append(Paths.EngineLog, $"VPN-адаптер «{snapshot.Plan.TunnelName}» не трогаем" +
                (snapshot.Plan.PinnedIfIndex is { } pinned ? $", движок привязан к интерфейсу {pinned}" : "") +
                (snapshot.Endpoints.Count > 0 ? $", исключено адресов: {snapshot.Endpoints.Count}" : ""));
        }

        Log.TrimIfLarge(Paths.EngineLog);
        Log.Append(Paths.EngineLog, $"— запуск: {strategyId}, пресет {IpsetModes.Normalize(ipsetMode)}, игровой фильтр {GameFilterModes.Title(gameFilter)} —");

        var host = new ProcessStartInfo(Paths.ExecutablePath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = Paths.Base,
        };
        host.ArgumentList.Add("--engine-host");
        host.ArgumentList.Add(Paths.EngineArgs);
        Process.Start(host)?.Dispose();

        var started = false;
        for (var i = 0; i < 50 && !started; i++)
        {
            Thread.Sleep(100);
            started = IsRunning;
        }
        if (started)
        {
            // winws exits right away on bad arguments or when WinDivert cannot be opened
            Thread.Sleep(1200);
            started = IsRunning;
        }
        if (!started)
        {
            throw new InvalidOperationException("winws не запустился.\n\n" + Log.Tail(Paths.EngineLog, 12));
        }
    }

    public static void PrepareFiles()
    {
        if (!Payload.HasEngine)
        {
            throw new InvalidOperationException("В этой сборке нет winws.exe. Скачайте Nimbus-Windows-x64.exe из релизов.");
        }
        Directory.CreateDirectory(Paths.Base);
        foreach (var prefix in new[] { "engine/", "payload/bin/" })
        {
            try
            {
                Payload.Extract(prefix, Paths.BinDir);
            }
            catch (IOException ex)
            {
                // WinDivert64.sys can be held open by an already loaded driver; the existing copy keeps working
                Log.Write("extract " + prefix + ": " + ex.Message);
                if (!File.Exists(Paths.Winws)) throw;
            }
        }
        foreach (var name in new[] { "ipset-none.txt", "ipset-any.txt" })
        {
            File.WriteAllBytes(Path.Combine(Paths.Base, name), Payload.Read("payload/" + name));
        }
        EnableTcpTimestamps();
    }

    private static void CopyLists()
    {
        Directory.CreateDirectory(Paths.RuntimeLists);
        foreach (var name in ListCatalog.Names)
        {
            var source = Path.Combine(Paths.UserLists, name);
            var info = new FileInfo(source);
            if (!info.Exists || info.Attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                throw new InvalidOperationException("Список не найден: " + source);
            }
            File.Copy(source, Path.Combine(Paths.RuntimeLists, name), true);
        }
    }

    /// <summary>Strategies use --dpi-desync-fooling=ts, which needs TCP timestamps (off by default on Windows).</summary>
    private static void EnableTcpTimestamps()
    {
        try
        {
            var psi = new ProcessStartInfo("netsh")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (var a in "interface tcp set global timestamps=enabled".Split(' ')) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi);
            p?.WaitForExit(5000);
        }
        catch (Exception ex)
        {
            Log.Write("netsh timestamps: " + ex.Message);
        }
    }
}

internal static class EngineHost
{
    public static int Run(string argsFile)
    {
        try
        {
            var psi = new ProcessStartInfo(Paths.Winws)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                WorkingDirectory = Paths.BinDir,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            foreach (var arg in File.ReadAllLines(argsFile).Where(l => l.Length > 0)) psi.ArgumentList.Add(arg);
            using var process = Process.Start(psi) ?? throw new InvalidOperationException("winws.exe не запустился");
            process.OutputDataReceived += (_, e) => { if (e.Data != null) Log.Append(Paths.EngineLog, e.Data); };
            process.ErrorDataReceived += (_, e) => { if (e.Data != null) Log.Append(Paths.EngineLog, e.Data); };
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            process.WaitForExit();
            Log.Append(Paths.EngineLog, $"winws завершился, код {process.ExitCode}");
            return process.ExitCode;
        }
        catch (Exception ex)
        {
            Log.Append(Paths.EngineLog, "engine host: " + ex.Message);
            return 1;
        }
    }
}
