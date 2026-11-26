using System;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using Nimbus.Core;

namespace Nimbus;

/// <summary>Panel colors: near-black hairline panel, three text levels, one indigo accent (mirror of NB in NimbusDesign.swift).</summary>
internal static class Theme
{
    public static bool AppsUseLightTheme => ReadDword("AppsUseLightTheme", 1) != 0;
    public static bool SystemUsesLightTheme => ReadDword("SystemUsesLightTheme", 0) != 0;

    /// <summary>Windows "Animation effects" off ≈ macOS Reduce Motion.</summary>
    /// <summary>Set by `--render-screens` so every animation lands on its final frame.</summary>
    public static bool ForceReduceMotion { get; set; }

    public static bool ReduceMotion => ForceReduceMotion || !SystemParameters.ClientAreaAnimation;

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

    private static Color Hex(uint rgb, double alpha = 1) =>
        Color.FromArgb((byte)Math.Round(alpha * 255), (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    public static void Apply(ResourceDictionary resources, bool? forceLight = null)
    {
        var light = forceLight ?? AppsUseLightTheme;
        uint ink = light ? 0x000000u : 0xFFFFFFu;
        Set(resources, "PanelBrush", light ? Hex(0xFBFBFC, 0.95) : Hex(0x0F1012, 0.82));
        // WPF has no behind-window blur for a layered window: the solid tone sits under the tinted panel
        Set(resources, "PanelBaseBrush", light ? Hex(0xF4F4F6) : Hex(0x111215));
        Set(resources, "SolidBrush", light ? Hex(0xFCFCFD) : Hex(0x0F1012));
        Set(resources, "RaisedBrush", Hex(ink, light ? 0.018 : 0.028));
        Set(resources, "LineBrush", Hex(ink, 0.075));
        Set(resources, "Line2Brush", Hex(ink, 0.12));
        Set(resources, "HoverBrush", Hex(ink, light ? 0.035 : 0.045));
        Set(resources, "SelBrush", Hex(ink, light ? 0.055 : 0.075));
        Set(resources, "KbdBrush", Hex(ink, light ? 0.045 : 0.06));
        Set(resources, "T1Brush", light ? Hex(0x17181B) : Hex(0xEDEEF0));
        Set(resources, "T2Brush", light ? Hex(0x686C74) : Hex(0x8A8F98));
        Set(resources, "T3Brush", light ? Hex(0x9A9DA4) : Hex(0x5B5F67));
        Set(resources, "AccentBrush", light ? Hex(0x5E6AD2) : Hex(0x7C84FF));
        Set(resources, "AccentSoftBrush", light ? Hex(0x5E6AD2, 0.11) : Hex(0x7C84FF, 0.14));
        Set(resources, "AccentTextBrush", light ? Hex(0x5E6AD2) : Hex(0xA5ABFF));
        Set(resources, "WarnBrush", light ? Hex(0xC9801A) : Hex(0xE2A33E));
        Set(resources, "ErrBrush", light ? Hex(0xD64545) : Hex(0xEB5C5C));
        Set(resources, "ErrSoftBrush", light ? Hex(0xD64545, 0.08) : Hex(0xEB5C5C, 0.10));
        Set(resources, "ScrimBrush", light ? Hex(0xFAFAFB, 0.55) : Hex(0x040506, 0.55));
        Set(resources, "KnobBrush", Colors.White);
        resources["ShadowOpacity"] = light ? 0.18 : 0.55;
        resources["IsLightTheme"] = light;
    }

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
            if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.Color or UserPreferenceCategory.VisualStyle) changed();
        };
    }
}

/// <summary>The offset-N mark as WPF geometry (16-unit grid, scaled to any size).</summary>
internal static class MarkShape
{
    public static Geometry Build(double size)
    {
        var s = size / 16.0;
        var figure = new PathFigure { IsClosed = true, IsFilled = true };
        var pts = MarkGeometry.Points;
        figure.StartPoint = new Point(pts[0].X * s, pts[0].Y * s);
        for (var i = 1; i < pts.Length; i++)
            figure.Segments.Add(new LineSegment(new Point(pts[i].X * s, pts[i].Y * s), true));
        var geometry = new PathGeometry(new[] { figure });
        geometry.Freeze();
        return geometry;
    }

    /// <summary>The slot punched through the diagonal in the problem state; gap 0…1 grows it from the centre.</summary>
    public static Geometry Gap(double size, double gap)
    {
        var s = size / 16.0;
        var w = 2.2 * gap * s;
        var rect = new RectangleGeometry(new Rect(-w / 2, -1.75 * s, w, 3.5 * s))
        {
            Transform = new TransformGroup
            {
                Children = { new RotateTransform(MarkGeometry.DiagonalDegrees), new TranslateTransform(8 * s, 8 * s) },
            },
        };
        return rect;
    }

    /// <summary>Draws the mark for the given animation parameters (outline, left-to-right fill, sweep band, gap).</summary>
    public static void Draw(DrawingContext dc, double size, Brush brush, MarkParams p)
    {
        var s = size / 16.0;
        var mark = Build(size);
        if (p.Outline > 0.001)
        {
            var pen = new Pen(brush, MarkGeometry.OutlineWidth * s) { LineJoin = PenLineJoin.Miter };
            dc.PushOpacity(Math.Clamp(p.Outline, 0, 1));
            dc.DrawGeometry(null, pen, mark);
            dc.Pop();
        }
        Geometry clip = new RectangleGeometry(new Rect(0, 0, Math.Clamp(p.Fill, 0, 16) * s, size));
        if (p.Band is double band)
            clip = new CombinedGeometry(GeometryCombineMode.Union, clip, new RectangleGeometry(new Rect(band * s, 0, MarkGeometry.BandWidth * s, size)));
        Geometry fill = new CombinedGeometry(GeometryCombineMode.Intersect, mark, clip);
        if (p.Gap > 0.001)
            fill = new CombinedGeometry(GeometryCombineMode.Exclude, fill, Gap(size, p.Gap));
        dc.DrawGeometry(brush, null, fill);
    }
}
