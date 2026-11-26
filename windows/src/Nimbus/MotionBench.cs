using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using Nimbus.Core;

namespace Nimbus;

/// <summary>
/// `Nimbus.exe --motion-bench REPORT` opens the panel on screen, plays the open, page, command bar
/// and close animations and writes frame intervals per step. CI only; it never starts the engine.
/// </summary>
internal static class MotionBench
{
    /// <summary>The real screen, so the shot shows what DWM composited (transparent margin, shadow).</summary>
    private static void Snapshot(string path)
    {
        try
        {
            var b = System.Windows.Forms.SystemInformation.VirtualScreen;
            using var bmp = new System.Drawing.Bitmap(b.Width, b.Height);
            using (var g = System.Drawing.Graphics.FromImage(bmp)) g.CopyFromScreen(b.Left, b.Top, 0, 0, bmp.Size);
            bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
        catch
        {
            // no desktop to capture
        }
    }

    public static int Run(string reportPath)
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        Motion.UseDisplayRate();
        Theme.Apply(app.Resources);
        var report = new StringBuilder();
        report.AppendLine($"Nimbus {Updater.CurrentVersion}, render tier {RenderCapability.Tier >> 16}, window {(Backdrop.UseComposition ? "composed" : "layered")}");

        // work the refresh timer does on the UI thread
        foreach (var (name, probe) in new (string, Action)[]
        {
            ("Engine.IsRunning", () => _ = Engine.IsRunning),
            ("DetectVpn", () => _ = SystemDiagnostics.DetectVpn()),
            ("LocalNetwork.Primary", () => _ = LocalNetwork.Primary()),
        })
        {
            var times = new List<double>();
            for (var i = 0; i < 5; i++)
            {
                var sw = Stopwatch.StartNew();
                probe();
                times.Add(sw.Elapsed.TotalMilliseconds);
            }
            report.AppendLine($"{name,-22} {string.Join(" ", times.Select(t => t.ToString("0.0")))} ms");
        }

        var strategies = StrategyCatalog.Parse(Payload.ReadText("payload/strategies.tsv"));
        var model = new HudModel
        {
            Strategies = strategies,
            StrategyName = "general (SIMPLE FAKE)",
            SelectedStrategyId = StrategyCatalog.DefaultId,
            VersionTitle = "Версия " + Updater.CurrentVersion,
            AppVersion = Updater.CurrentVersion,
            Running = true,
            Discord = ServiceHealth.Ok,
            YouTube = ServiceHealth.Ok,
            DiscordMs = 38,
            YouTubeMs = 47,
            LatencySamples = new double[] { 52, 48, 47, 55, 61, 50, 46, 44, 49, 58, 63, 57, 51, 47, 45, 48, 53, 49, 46, 44 },
            EngineStarted = DateTime.Now.AddMinutes(-20),
        };
        var window = new HudWindow(model);
        var phase = "";
        var samples = new Dictionary<string, List<double>>();
        var last = TimeSpan.Zero;
        EventHandler onFrame = (_, e) =>
        {
            var t = ((System.Windows.Media.RenderingEventArgs)e).RenderingTime;
            if (t == last) return;
            if (last != TimeSpan.Zero && phase.Length > 0) samples[phase].Add((t - last).TotalMilliseconds);
            last = t;
        };

        async Task Step(string name, Action action, int ms)
        {
            phase = name;
            samples[name] = new List<double>();
            action();
            await Task.Delay(ms);
        }

        async Task Script()
        {
            CompositionTarget.Rendering += onFrame;
            await Task.Delay(500);
            await Step("open", window.ShowHud, 900);
            Snapshot(Path.ChangeExtension(reportPath, ".png"));
            await Step("page-more", () => model.Page = HudPage.More, 800);
            await Step("page-back", () => model.Page = HudPage.Main, 800);
            await Step("palette-open", model.OpenPalette, 700);
            await Step("palette-close", model.ClosePalette, 500);
            await Step("idle", () => { }, 1000);
            await Step("close", window.HideHud, 500);
            CompositionTarget.Rendering -= onFrame;

            report.AppendLine();
            report.AppendLine("step            frames  avg ms  p95 ms  max ms  >25ms  fps");
            foreach (var (name, list) in samples)
            {
                if (list.Count == 0) { report.AppendLine($"{name,-15} 0"); continue; }
                var sorted = list.OrderBy(x => x).ToList();
                var p95 = sorted[Math.Min(sorted.Count - 1, (int)Math.Ceiling(sorted.Count * 0.95) - 1)];
                report.AppendLine($"{name,-15} {list.Count,6}  {list.Average(),6:0.0}  {p95,6:0.0}  {sorted[^1],6:0.0}  {list.Count(x => x > 25),5}  {1000 / list.Average(),4:0}");
            }
            File.WriteAllText(reportPath, report.ToString());
            app.Shutdown(0);
        }

        app.Startup += (_, _) => _ = Script();
        return app.Run();
    }
}
