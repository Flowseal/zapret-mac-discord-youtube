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
        foreach (var light in new[] { false, true })
        {
            Theme.Apply(app.Resources, light);
            var theme = light ? "light" : "dark";
            Shoot(dir, $"{theme}-1-main-off", strategies, m => { });
            Shoot(dir, $"{theme}-2-main-on", strategies, m =>
            {
                m.Running = true;
                m.LoginEnabled = true;
                m.IpsetMode = IpsetModes.Loaded;
                m.Discord = ServiceHealth.Ok;
                m.YouTube = ServiceHealth.Bad;
            });
            Shoot(dir, $"{theme}-3-main-testing", strategies, m =>
            {
                m.Running = true;
                m.Testing = true;
                m.Discord = ServiceHealth.Checking;
                m.YouTube = ServiceHealth.Checking;
                m.TestProgress = "Стратегия 4/21: general (ALT3)";
            });
            Shoot(dir, $"{theme}-4-more-results", strategies, m =>
            {
                m.Running = true;
                m.Page = HudPage.More;
                m.TestRows = strategies.Take(5).Select((s, i) => new TestRow(s.Name, i == 4 ? "ошибка" : $"{20 + i}/27", i == 3)).ToList();
                m.TestBest = $"Лучшая: {strategies[3].Name} (23/27)";
                m.ApplyBestEnabled = true;
                m.TestTitle = "Повторить тест";
            });
            Shoot(dir, $"{theme}-5-logs", strategies, m =>
            {
                m.Page = HudPage.Logs;
                m.Logs = "— nimbus.log —\n2026-11-22 17:40:01 started\n\n— engine.log —\n2026-11-22 17:40:02 — запуск: general-simple-fake, пресет none —\n2026-11-22 17:40:02 windivert initialized. capture is started.";
            });
            Shoot(dir, $"{theme}-6-lists", strategies, m =>
            {
                m.Page = HudPage.Lists;
                m.Lists = ListCatalog.Names.Select((n, i) => new ListRow(ListCatalog.Describe(n, n == "ipset-all.txt" ? 500_000 : 100, "a\nb\n"), i > 0)).ToList();
            });
            Shoot(dir, $"{theme}-7-editor", strategies, m =>
            {
                m.Page = HudPage.Editor;
                m.EditorTitle = "Основные";
                m.EditorText = "discord.com\nyoutube.com\nexample.org\n";
                m.Notice = "Сохранено";
            });
            Shoot(dir, $"{theme}-8-error", strategies, m =>
            {
                m.Notice = "winws не запустился.\n\nerror opening filter: access denied";
                m.NoticeError = true;
            });
        }
        return 0;
    }

    private static void Shoot(string dir, string name, System.Collections.Generic.IReadOnlyList<Strategy> strategies, Action<HudModel> setup)
    {
        var model = new HudModel { Strategies = strategies, StrategyName = "general (SIMPLE FAKE)", SelectedStrategyId = StrategyCatalog.DefaultId, VersionTitle = "Версия " + Updater.CurrentVersion };
        setup(model);
        var window = new HudWindow(model) { Left = -20000, Top = -20000, ShowActivated = false };
        window.Show();
        window.UpdateLayout();
        var root = (FrameworkElement)window.Content;
        const double scale = 2;
        // the root grid has an 8 px margin (room for the shadow); include it on every side
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
