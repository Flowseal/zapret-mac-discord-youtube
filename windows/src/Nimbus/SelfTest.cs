using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using Nimbus.Core;

namespace Nimbus;

/// <summary>
/// `Nimbus.exe --self-test REPORT` (used by CI on windows-latest):
/// 1. extracts the embedded engine, 2. runs `winws.exe --dry-run` for every strategy,
/// 3. starts the real engine through the engine host, checks it stays up, stops it.
/// </summary>
internal static class SelfTest
{
    public static int Run(string reportPath)
    {
        var report = new StringBuilder();
        var failures = 0;
        void Line(string s) { report.AppendLine(s); File.WriteAllText(reportPath, report.ToString()); }

        try
        {
            Line($"Nimbus {Updater.CurrentVersion}, engine {(Payload.HasEngine ? Payload.ReadText("engine/VERSION").Trim() : "missing")}");
            Directory.CreateDirectory(Paths.UserLists);
            Payload.Extract("payload/default-lists/", Paths.UserLists, overwrite: false);
            Engine.PrepareFiles();
            Directory.CreateDirectory(Paths.RuntimeLists);
            foreach (var name in ListCatalog.Names) File.Copy(Path.Combine(Paths.UserLists, name), Path.Combine(Paths.RuntimeLists, name), true);
            // documentation addresses stand in for VPN servers; the file has to exist before winws parses its arguments
            Tunnels.WriteLeaveAloneFile(new[] { "203.0.113.7", "198.51.100.0/24", "2001:db8::/32" });

            var strategies = StrategyCatalog.Parse(Payload.ReadText("payload/strategies.tsv"));
            foreach (var strategy in strategies)
            {
                foreach (var mode in new[] { IpsetModes.None, IpsetModes.Loaded, IpsetModes.Any })
                {
                    var args = EngineArguments.Build(Payload.ReadText($"payload/strategies/{strategy.Id}.conf.in"), Paths.Base, Paths.RuntimeLists,
                        EngineArguments.IpsetPath(mode, Paths.Base, Paths.RuntimeLists), leaveAlone: true);
                    var psi = new ProcessStartInfo(Paths.Winws) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = Paths.BinDir };
                    psi.ArgumentList.Add("--dry-run");
                    foreach (var a in args) psi.ArgumentList.Add(a);
                    using var p = Process.Start(psi)!;
                    var stdout = p.StandardOutput.ReadToEndAsync();
                    var stderr = p.StandardError.ReadToEndAsync();
                    if (!p.WaitForExit(20000)) { p.Kill(); }
                    var output = (stdout.Result + stderr.Result).Trim();
                    var last = output.Length == 0 ? "" : output.Split('\n')[^1].Trim();
                    var ok = p.HasExited && p.ExitCode == 0;
                    if (!ok) failures++;
                    Line($"{(ok ? "ok  " : "FAIL")} dry-run {strategy.Id} ipset={mode}: {last}");
                    if (!ok) Line(output);
                }
            }

            var defaultTemplate = Payload.ReadText($"payload/strategies/{StrategyCatalog.DefaultId}.conf.in");
            var loaded = EngineArguments.IpsetPath(IpsetModes.Loaded, Paths.Base, Paths.RuntimeLists);
            foreach (var game in new[] { GameFilterModes.Games, GameFilterModes.Wide })
            {
                var args = EngineArguments.Build(defaultTemplate, Paths.Base, Paths.RuntimeLists, loaded, gameFilterMode: game, wfIface: 1, leaveAlone: true);
                var psi = new ProcessStartInfo(Paths.Winws) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = Paths.BinDir };
                psi.ArgumentList.Add("--dry-run");
                foreach (var a in args) psi.ArgumentList.Add(a);
                using var p = Process.Start(psi)!;
                var stdout = p.StandardOutput.ReadToEndAsync();
                var stderr = p.StandardError.ReadToEndAsync();
                if (!p.WaitForExit(20000)) { p.Kill(); }
                var output = (stdout.Result + stderr.Result).Trim();
                var last = output.Length == 0 ? "" : output.Split('\n')[^1].Trim();
                var ok = p.HasExited && p.ExitCode == 0;
                if (!ok) failures++;
                Line($"{(ok ? "ok  " : "FAIL")} dry-run {StrategyCatalog.DefaultId} game={game}: {last}");
                if (!ok) Line(output);
            }

            Line("");
            // the same engine pinned to a real interface, with exclusions loaded: winws has to accept the filter and stay up
            var nicIndex = RealInterfaceIndex();
            if (nicIndex != null)
            {
                Line($"engine start pinned to interface {nicIndex}, with leave-alone addresses …");
                Engine.Start(StrategyCatalog.DefaultId, IpsetModes.None, gameFilterMode: GameFilterModes.Off,
                    network: new NetworkSnapshot(new EnginePlan(nicIndex, new[] { 99 }, "test"), new[] { "203.0.113.7", "198.51.100.0/24", "2001:db8::/32" }));
                Thread.Sleep(1500);
                var pinned = Engine.IsRunning;
                Line(pinned ? "ok   winws is running with --wf-iface and the exclude list" : "FAIL winws did not stay up with --wf-iface");
                if (!pinned) failures++;
                Line($"ok   engine plan file: {Engine.RunningPlan}");
                Engine.Stop();
                Thread.Sleep(500);
            }
            else
            {
                Line("skip pinned start: no usable interface");
            }
            Line("engine start (general-simple-fake, none) …");
            Engine.Start(StrategyCatalog.DefaultId, IpsetModes.None, gameFilterMode: GameFilterModes.Off);
            Line($"engine plan: {Engine.RunningPlan}");
            Thread.Sleep(2000);
            var running = Engine.IsRunning;
            Line(running ? "ok   winws is running" : "FAIL winws is not running");
            if (!running) failures++;
            Engine.Stop();
            Thread.Sleep(500);
            var stopped = !Engine.IsRunning;
            Line(stopped ? "ok   winws stopped" : "FAIL winws still running");
            if (!stopped) failures++;
            Line("");
            Line("engine.log tail:");
            Line(Log.Tail(Paths.EngineLog, 20));
        }
        catch (Exception ex)
        {
            failures++;
            Line("FAIL exception: " + ex);
            Line(Log.Tail(Paths.EngineLog, 20));
        }
        Line(failures == 0 ? "SELF-TEST PASSED" : $"SELF-TEST FAILED ({failures})");
        return failures == 0 ? 0 : 1;
    }

    /// `Nimbus.exe --probe-network REPORT`: what the engine would do on this machine (adapters, VPN detection, interface pin, endpoints).
    public static int ProbeNetwork(string reportPath)
    {
        var report = new StringBuilder();
        foreach (var nic in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
        {
            int? index = null;
            try { index = nic.GetIPProperties().GetIPv4Properties()?.Index; } catch { }
            report.AppendLine($"adapter if={index?.ToString() ?? "?"} up={nic.OperationalStatus == System.Net.NetworkInformation.OperationalStatus.Up} type={nic.NetworkInterfaceType} name=\"{nic.Name}\" description=\"{nic.Description}\"");
        }
        var snapshot = Tunnels.Capture();
        report.AppendLine($"vpn adapters: {string.Join(",", snapshot.Plan.TunnelIndexes)} ({snapshot.Plan.TunnelName})");
        report.AppendLine($"pinned interface: {snapshot.Plan.PinnedIfIndex?.ToString() ?? "none"}");
        report.AppendLine($"plan signature: {snapshot.Plan.Signature}");
        report.AppendLine($"endpoints: {string.Join(",", snapshot.Endpoints)}");
        report.AppendLine($"detected: {SystemDiagnostics.DetectVpn().Reason ?? "no VPN"}");
        File.WriteAllText(reportPath, report.ToString());
        Console.Write(report.ToString());
        return 0;
    }

    private static int? RealInterfaceIndex()
    {
        try
        {
            foreach (var nic in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
                if (nic.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Loopback) continue;
                var index = nic.GetIPProperties().GetIPv4Properties()?.Index;
                if (index is > 0) return index;
            }
        }
        catch
        {
        }
        return null;
    }
}
