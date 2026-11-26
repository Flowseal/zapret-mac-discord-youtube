using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Nimbus.Core;

namespace Nimbus;

/// <summary>
/// Notification-area glyph: the offset-N mark in four states — off (outline), checking (outline + sweeping band),
/// on (filled), problem (filled with a slot cut through the diagonal). State changes morph with a critically damped
/// spring like the Mac status item; Reduce Motion snaps.
/// </summary>
internal sealed class TrayIcon : IDisposable
{
    private const double Response = 0.34;
    private readonly NotifyIcon notifyIcon = new();
    private readonly Timer timer = new() { Interval = 33 };
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly Dictionary<string, Icon> cache = new();
    private Color ink;
    private int size;
    private MarkState state = MarkState.Off;
    private MarkParams current = MarkParams.Target(MarkState.Off);
    private (double Fill, double Outline, double Gap) velocity;
    private double sweepStart;
    private double lastTick;
    private Icon? transient;

    public event Action? Clicked;

    public TrayIcon()
    {
        Measure();
        notifyIcon.Icon = IconFor(current, cacheable: true);
        notifyIcon.Text = "Nimbus — выключен";
        notifyIcon.Visible = true;
        notifyIcon.MouseUp += (_, e) =>
        {
            if (e.Button is MouseButtons.Left or MouseButtons.Right) Clicked?.Invoke();
        };
        timer.Tick += (_, _) => Tick();
    }

    /// <summary>Kept for callers that only know on/off.</summary>
    public void Update(bool isRunning) => Update(isRunning ? MarkState.On : MarkState.Off, isRunning ? "включён" : "выключен");

    public void Update(MarkState next, string status)
    {
        var text = "Nimbus — " + status;
        notifyIcon.Text = text.Length > 63 ? text[..63] : text;
        if (next == state) return;
        var previous = state;
        state = next;
        var now = clock.Elapsed.TotalSeconds;
        if (next == MarkState.Checking) sweepStart = now;
        if (previous == MarkState.Checking && current.Band is double band)
        {
            // continue the wipe from wherever the sweep band is
            current = current with { Fill = Math.Max(current.Fill, Math.Min(16, band + MarkGeometry.BandWidth)), Band = null };
        }
        if (Theme.ReduceMotion)
        {
            timer.Stop();
            current = MarkParams.Target(next) with { Band = next == MarkState.Checking ? 5 : null };
            velocity = default;
            Show(current, cacheable: true);
            return;
        }
        lastTick = now;
        timer.Start();
    }

    private void Tick()
    {
        var now = clock.Elapsed.TotalSeconds;
        var dt = Math.Clamp(now - lastTick, 0, 0.1);
        lastTick = now;
        var target = MarkParams.Target(state);
        var (fill, vf) = Spring.Step(current.Fill, velocity.Fill, target.Fill, Response, dt);
        var (outline, vo) = Spring.Step(current.Outline, velocity.Outline, target.Outline, Response, dt);
        var (gap, vg) = Spring.Step(current.Gap, velocity.Gap, target.Gap, Response, dt);
        velocity = (vf, vo, vg);
        double? band = state == MarkState.Checking ? MarkGeometry.Band(now - sweepStart) : null;
        current = new MarkParams(fill, outline, gap, band);
        var settled = Spring.Settled(fill, vf, target.Fill) && Spring.Settled(outline, vo, target.Outline, 0.005) && Spring.Settled(gap, vg, target.Gap, 0.005);
        if (settled)
        {
            current = target with { Band = band };
            velocity = default;
            if (state != MarkState.Checking)
            {
                timer.Stop();
                Show(current, cacheable: true);
                return;
            }
            // steady sweep: quantise the band so the frames come from the cache
            Show(current with { Band = Math.Round(band!.Value * 2) / 2 }, cacheable: true);
            return;
        }
        Show(current, cacheable: false);
    }

    private void Show(MarkParams p, bool cacheable)
    {
        var icon = IconFor(p, cacheable);
        notifyIcon.Icon = icon;
        if (!cacheable)
        {
            transient?.Dispose();
            transient = icon;
        }
    }

    private Icon IconFor(MarkParams p, bool cacheable)
    {
        if (!cacheable) return Render(size, ink, p);
        var key = $"{p.Fill:0.##}|{p.Outline:0.##}|{p.Gap:0.##}|{p.Band?.ToString("0.#") ?? "-"}";
        if (!cache.TryGetValue(key, out var icon))
        {
            icon = Render(size, ink, p);
            cache[key] = icon;
        }
        return icon;
    }

    private void Measure()
    {
        size = Math.Max(16, SystemInformation.SmallIconSize.Width);
        ink = Theme.SystemUsesLightTheme ? Color.FromArgb(0x11, 0x11, 0x11) : Color.White;
    }

    public void RebuildForTheme()
    {
        Measure();
        var stale = new List<Icon>(cache.Values);
        cache.Clear();
        Show(current, cacheable: true);
        foreach (var icon in stale) icon.Dispose();
    }

    private static Icon Render(int size, Color color, MarkParams p)
    {
        using var bitmap = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Color.Transparent);
            var s = size / 16f;
            using var path = MarkPath(s);
            if (p.Outline > 0.001)
            {
                using var pen = new Pen(Color.FromArgb((int)Math.Round(Math.Clamp(p.Outline, 0, 1) * 255), color), (float)MarkGeometry.OutlineWidth * s) { LineJoin = LineJoin.Miter };
                g.DrawPath(pen, path);
            }
            using var clip = new Region(new RectangleF(0, 0, (float)Math.Clamp(p.Fill, 0, 16) * s, size));
            if (p.Band is double band)
                clip.Union(new RectangleF((float)band * s, 0, (float)MarkGeometry.BandWidth * s, size));
            if (p.Gap > 0.001)
            {
                using var slot = new GraphicsPath();
                var w = 2.2f * (float)p.Gap * s;
                slot.AddRectangle(new RectangleF(-w / 2, -1.75f * s, w, 3.5f * s));
                using var m = new Matrix();
                m.Translate(8 * s, 8 * s);
                m.Rotate((float)MarkGeometry.DiagonalDegrees);
                slot.Transform(m);
                clip.Exclude(slot);
            }
            g.Clip = clip;
            using var brush = new SolidBrush(color);
            g.FillPath(brush, path);
        }
        var handle = bitmap.GetHicon();
        try
        {
            return (Icon)Icon.FromHandle(handle).Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    private static GraphicsPath MarkPath(float s)
    {
        var pts = MarkGeometry.Points;
        var points = new PointF[pts.Length];
        for (var i = 0; i < pts.Length; i++) points[i] = new PointF((float)pts[i].X * s, (float)pts[i].Y * s);
        var path = new GraphicsPath(FillMode.Winding);
        path.AddPolygon(points);
        return path;
    }

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr handle);

    public void Dispose()
    {
        timer.Dispose();
        notifyIcon.Visible = false;
        notifyIcon.Dispose();
        transient?.Dispose();
        foreach (var icon in cache.Values) icon.Dispose();
    }
}
