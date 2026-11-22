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

            var strategies = StrategyCatalog.Parse(Payload.ReadText("payload/strategies.tsv"));
            foreach (var strategy in strategies)
            {
                foreach (var mode in new[] { IpsetModes.None, IpsetModes.Loaded, IpsetModes.Any })
                {
                    var args = EngineArguments.Build(Payload.ReadText($"payload/strategies/{strategy.Id}.conf.in"), Paths.Base, Paths.RuntimeLists,
                        EngineArguments.IpsetPath(mode, Paths.Base, Paths.RuntimeLists));
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

            Line("");
            Line("engine start (general-simple-fake, none) …");
            Engine.Start(StrategyCatalog.DefaultId, IpsetModes.None);
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
}
