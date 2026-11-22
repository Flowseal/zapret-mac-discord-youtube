using System;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace Nimbus;

/// <summary>Palette of the Mac HUD (systemBlue #0A84FF, green #30D158, red #FF453A) in light and dark variants.</summary>
internal static class Theme
{
    public static readonly Color Blue = Color.FromRgb(10, 132, 255);
    public static readonly Color Green = Color.FromRgb(48, 209, 88);
    public static readonly Color Red = Color.FromRgb(255, 69, 58);

    public static bool AppsUseLightTheme => ReadDword("AppsUseLightTheme", 1) != 0;
    public static bool SystemUsesLightTheme => ReadDword("SystemUsesLightTheme", 0) != 0;

    private static int ReadDword(string name, int fallback)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue(name) is int value ? value : fallback;
        }
        catch
        {
            return fallback;
        }
    }

    public static void Apply(ResourceDictionary resources, bool? forceLight = null)
    {
        var light = forceLight ?? AppsUseLightTheme;
        var fg = light ? Color.FromRgb(0x1D, 0x1D, 0x1F) : Color.FromRgb(0xF5, 0xF5, 0xF7);
        Set(resources, "BgBrush", light ? Color.FromArgb(0xF7, 0xF4, 0xF4, 0xF6) : Color.FromArgb(0xF5, 0x26, 0x26, 0x2A));
        Set(resources, "FgBrush", fg);
        Set(resources, "SecondaryBrush", WithAlpha(fg, light ? 0x99 : 0x99));
        Set(resources, "TertiaryBrush", WithAlpha(fg, light ? 0x55 : 0x5C));
        Set(resources, "GroupBrush", WithAlpha(light ? Colors.Black : Colors.White, 0x0E));
        Set(resources, "HoverBrush", WithAlpha(light ? Colors.Black : Colors.White, 0x0C));
        Set(resources, "HairlineBrush", WithAlpha(light ? Colors.Black : Colors.White, 0x14));
        Set(resources, "BorderBrush", WithAlpha(light ? Colors.Black : Colors.White, light ? 0x14 : 0x18));
        Set(resources, "MenuBrush", light ? Color.FromRgb(0xFB, 0xFB, 0xFC) : Color.FromRgb(0x2F, 0x2F, 0x33));
        Set(resources, "AccentBrush", Blue);
        Set(resources, "AccentSoftBrush", WithAlpha(Blue, 0x24));
        Set(resources, "RedBrush", Red);
        Set(resources, "RedSoftBrush", WithAlpha(Red, 0x1F));
        Set(resources, "SwitchOffBrush", WithAlpha(light ? Colors.Black : Colors.White, light ? 0x22 : 0x2E));
        Set(resources, "OffCircleBrush", WithAlpha(fg, 0x2E));
        Set(resources, "OffDotBrush", WithAlpha(fg, 0x55));
        Set(resources, "GreenBrush", Green);
        resources["IsLightTheme"] = light;
    }

    private static Color WithAlpha(Color c, int a) => Color.FromArgb((byte)a, c.R, c.G, c.B);

    private static void Set(ResourceDictionary resources, string key, Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        resources[key] = brush;
    }

    public static void Watch(Action changed)
    {
        SystemEvents.UserPreferenceChanged += (_, e) =>
        {
            if (e.Category == UserPreferenceCategory.General) changed();
        };
    }
}

/// <summary>The SF Symbol "cloud" drawn as geometry, used for the header badge (WPF) and the tray icon (GDI+).</summary>
internal static class CloudShape
{
    // unit-box circles (cx, cy, r) and the flat base, tuned to look like SF Symbols' cloud
    public static readonly (double X, double Y, double R)[] Circles =
    {
        (0.30, 0.62, 0.22),
        (0.52, 0.45, 0.30),
        (0.76, 0.64, 0.20),
    };
    public static readonly (double X, double Y, double W, double H, double R) Base = (0.08, 0.56, 0.88, 0.30, 0.15);

    public static Geometry Build(double width, double height)
    {
        Geometry geometry = new RectangleGeometry(
            new Rect(Base.X * width, Base.Y * height, Base.W * width, Base.H * height), Base.R * height, Base.R * height);
        foreach (var (x, y, r) in Circles)
        {
            var ellipse = new EllipseGeometry(new Point(x * width, y * height), r * width, r * width * 0.92);
            geometry = Geometry.Combine(geometry, ellipse, GeometryCombineMode.Union, null);
        }
        geometry.Freeze();
        return geometry;
    }
}
