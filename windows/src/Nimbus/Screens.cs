using System;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Nimbus.Core;

namespace Nimbus;

/// <summary>
/// `Nimbus.exe --render-screens DIR` renders every HUD page to PNG with sample data (light and dark).
/// CI uses it to check the WPF layout on a real Windows runner without starting the engine.
/// </summary>
internal static class Screens
{
    public static int Render(string dir)
    {
        Directory.CreateDirectory(dir);
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var strategies = StrategyCatalog.Parse(Payload.ReadText("payload/strategies.tsv"));
        Theme.ForceReduceMotion = true;
        var started = DateTime.Now.AddHours(-2).AddMinutes(-14);
        var samples = new double[] { 52, 48, 47, 55, 61, 50, 46, 44, 49, 58, 63, 57, 51, 47, 45, 48, 53, 49, 46, 44, 47, 52, 56, 50, 46, 43, 45, 49, 51, 48, 46, 44, 46, 50, 47, 45, 44, 46, 48, 47 };
        void On(HudModel m)
        {
            m.Running = true;
            m.LoginEnabled = true;
            m.IpsetMode = IpsetModes.Loaded;
            m.GameFilterMode = GameFilterModes.Games;
            m.Discord = ServiceHealth.Ok;
            m.YouTube = ServiceHealth.Ok;
            m.DiscordMs = 38;
            m.YouTubeMs = 47;
            m.LatencySamples = samples;
            m.LastProbe = DateTime.Now.AddSeconds(-4);
            m.EngineStarted = started;
            m.NetworkInterface = "Wi-Fi";
            m.NetworkAddress = "192.168.1.24";
            m.VpnNote = "WireGuard · не трогаем";
            m.LeaveAlone = "203.0.113.7, 10.8.0.0/16";
        }
        foreach (var light in new[] { false, true })
        {
            Theme.Apply(app.Resources, light);
            var theme = light ? "light" : "dark";
            Shoot(dir, $"{theme}-01-main", strategies, On);
            Shoot(dir, $"{theme}-02-main-problem", strategies, m =>
            {
                On(m);
                m.YouTube = ServiceHealth.Bad;
                m.YouTubeMs = null;
            });
            Shoot(dir, $"{theme}-03-main-off", strategies, m => { m.NetworkInterface = "Wi-Fi"; m.NetworkAddress = "192.168.1.24"; });
            Shoot(dir, $"{theme}-04-main-testing", strategies, m =>
            {
                On(m);
                m.Testing = true;
                m.Discord = ServiceHealth.Checking;
                m.YouTube = ServiceHealth.Checking;
                m.TestProgress = "Стратегия 4/21: general (ALT3)";
            });
            Shoot(dir, $"{theme}-05-more", strategies, m =>
            {
                On(m);
                m.Page = HudPage.More;
                m.TestRows = strategies.Take(5).Select((s, i) => new TestRow(s.Name, i == 4 ? "ошибка" : $"{20 + i}/27", i == 3)).ToList();
                m.TestBest = $"Лучшая: {strategies[3].Name} (23/27)";
                m.ApplyBestEnabled = true;
            });
            Shoot(dir, $"{theme}-06-logs", strategies, m =>
            {
                On(m);
                m.Page = HudPage.Logs;
                m.LogLines = LogParser.Parse(
                    "2026-11-26 17:40:01 started\n2026-11-26 17:40:02 — запуск: general (SIMPLE FAKE), пресет none —\n2026-11-26 17:40:02 windivert initialized. capture is started.\n2026-11-26 17:41:10 warning: retransmission to 162.159.130.234\n2026-11-26 17:42:33 error: connect timeout googlevideo.com",
                    "engine");
            });
            Shoot(dir, $"{theme}-07-lists", strategies, m =>
            {
                On(m);
                m.Page = HudPage.Lists;
                m.ListInput = "";
                m.UserEntries = new[] { new UserEntryRow(UserLists.BypassDomains, "chatgpt.com"), new UserEntryRow(UserLists.ExcludeDomains, "gosuslugi.ru") };
                m.Lists = ListCatalog.Names.Select((n, i) => new ListRow(ListCatalog.Describe(n, n == "ipset-all.txt" ? 500_000 : 100, string.Join("\n", Enumerable.Range(0, 40 + i * 37).Select(k => $"host{k}.com"))), i > 0)).ToList();
            });
            Shoot(dir, $"{theme}-08-editor", strategies, m =>
            {
                On(m);
                m.Page = HudPage.Editor;
                m.EditorName = "list-general.txt";
                m.EditorTitle = "Основные";
                m.EditorOriginal = "# Discord\ndiscord.com\ndiscord.gg\n# YouTube\nyoutube.com\ngooglevideo.com\n";
                m.EditorText = m.EditorOriginal + "example.org\n";
                m.CaretText = "Ln 7, Col 12";
            });
            Shoot(dir, $"{theme}-09-diagnostics", strategies, m =>
            {
                On(m);
                m.Page = HudPage.Diagnostics;
                m.DiagnosticsElapsed = 1.4;
                m.Diagnostics = new[]
                {
                    new DiagnosticViewRow("OK", "winws", "работает копия Nimbus", false),
                    new DiagnosticViewRow("OK", "DNS", "discord.com → 162.159.130.234", true),
                    new DiagnosticViewRow("OK", "VPN", "WireGuard: трафик туннеля Nimbus не трогает", true),
                    new DiagnosticViewRow("FAIL", "TCP timestamps", "выключены", true),
                };
                m.DiagnosticText = "Nimbus " + Updater.CurrentVersion + "\n";
            });
            Shoot(dir, $"{theme}-10-cmdk", strategies, m =>
            {
                On(m);
                m.OpenPalette();
                m.PaletteQuery = "ло";
            });
            Shoot(dir, $"{theme}-11-error", strategies, m =>
            {
                m.Notice = "winws не запустился.\n\nerror opening filter: access denied";
                m.NoticeError = true;
            });
        }
        return 0;
    }

    private static void Shoot(string dir, string name, System.Collections.Generic.IReadOnlyList<Strategy> strategies, Action<HudModel> setup)
    {
        var model = new HudModel { Strategies = strategies, StrategyName = "general (SIMPLE FAKE)", SelectedStrategyId = StrategyCatalog.DefaultId, VersionTitle = "Версия " + Updater.CurrentVersion, AppVersion = Updater.CurrentVersion };
        setup(model);
        var window = new HudWindow(model) { Left = -20000, Top = -20000, ShowActivated = false };
        window.Show();
        window.UpdateLayout();
        var root = (FrameworkElement)window.Content;
        const double scale = 2;
        // the root grid has an 18 px margin (room for the hairline panel's shadow); include it on every side
        var width = root.ActualWidth + root.Margin.Left + root.Margin.Right;
        var height = root.ActualHeight + root.Margin.Top + root.Margin.Bottom;
        var bitmap = new RenderTargetBitmap(
            (int)Math.Ceiling(width * scale), (int)Math.Ceiling(height * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
        var backdrop = new DrawingVisual();
        using (var dc = backdrop.RenderOpen())
        {
            var light = (bool)Application.Current.Resources["IsLightTheme"];
            dc.DrawRectangle(new SolidColorBrush(light ? Color.FromRgb(0xC9, 0xD6, 0xE8) : Color.FromRgb(0x1B, 0x23, 0x33)), null, new Rect(0, 0, width, height));
        }
        bitmap.Render(backdrop);
        bitmap.Render(root);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using (var file = File.Create(Path.Combine(dir, name + ".png"))) encoder.Save(file);
        window.Close();
    }
}
