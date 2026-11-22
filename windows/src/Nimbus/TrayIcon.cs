using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Nimbus;

/// <summary>Notification-area icon: outline cloud when off, filled "breathing" cloud when on (like the Mac menu bar item).</summary>
internal sealed class TrayIcon : IDisposable
{
    private const int Frames = 26; // 2.6 s cycle at 10 fps
    private readonly NotifyIcon notifyIcon = new();
    private readonly Timer breathTimer = new() { Interval = 100 };
    private Icon? offIcon;
    private Icon[] onFrames = Array.Empty<Icon>();
    private bool? running;
    private int frame;

    public event Action? Clicked;

    public TrayIcon()
    {
        BuildIcons();
        notifyIcon.Icon = offIcon;
        notifyIcon.Text = "Nimbus выключен";
        notifyIcon.Visible = true;
        notifyIcon.MouseUp += (_, e) =>
        {
            if (e.Button is MouseButtons.Left or MouseButtons.Right) Clicked?.Invoke();
        };
        breathTimer.Tick += (_, _) =>
        {
            frame = (frame + 1) % Frames;
            notifyIcon.Icon = onFrames[frame];
        };
    }

    public void Update(bool isRunning)
    {
        if (running == isRunning) return;
        running = isRunning;
        notifyIcon.Text = isRunning ? "Nimbus включён" : "Nimbus выключен";
        if (isRunning)
        {
            frame = 0;
            notifyIcon.Icon = onFrames[0];
            breathTimer.Start();
        }
        else
        {
            breathTimer.Stop();
            notifyIcon.Icon = offIcon;
        }
    }

    public void RebuildForTheme()
    {
        BuildIcons();
        var r = running;
        running = null;
        Update(r ?? false);
    }

    private void BuildIcons()
    {
        var size = SystemInformation.SmallIconSize.Width;
        if (size < 16) size = 16;
        var color = Theme.SystemUsesLightTheme ? Color.FromArgb(0x1D, 0x1D, 0x1F) : Color.White;
        var oldOff = offIcon;
        var oldFrames = onFrames;
        offIcon = Render(size, color, filled: false, alpha: 1);
        onFrames = new Icon[Frames];
        for (var i = 0; i < Frames; i++)
        {
            var wave = (Math.Sin(2 * Math.PI * i / Frames) + 1) / 2;
            onFrames[i] = Render(size, color, filled: true, alpha: 0.58 + 0.42 * wave);
        }
        oldOff?.Dispose();
        foreach (var icon in oldFrames) icon.Dispose();
    }

    private static Icon Render(int size, Color color, bool filled, double alpha)
    {
        using var bitmap = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            var pad = size * 0.06f;
            var w = size - 2 * pad;
            var h = w * 0.78f;
            var top = (size - h) / 2f;
            using var path = CloudPath(pad, top, w, h, 0);
            var tint = Color.FromArgb((int)Math.Round(alpha * 255), color);
            using var brush = new SolidBrush(tint);
            if (filled)
            {
                g.FillPath(brush, path);
            }
            else
            {
                // outline = full cloud minus a cloud eroded by the stroke width
                g.FillPath(brush, path);
                var stroke = Math.Max(1.4f, size / 11f);
                using var inner = CloudPath(pad, top, w, h, stroke);
                g.CompositingMode = CompositingMode.SourceCopy;
                using var clear = new SolidBrush(Color.Transparent);
                g.FillPath(clear, inner);
            }
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

    private static GraphicsPath CloudPath(float x0, float y0, float w, float h, float inset)
    {
        var path = new GraphicsPath { FillMode = FillMode.Winding };
        var b = CloudShape.Base;
        var bx = x0 + (float)b.X * w + inset;
        var by = y0 + (float)b.Y * h + inset;
        var bw = (float)b.W * w - 2 * inset;
        var bh = (float)b.H * h - 2 * inset;
        var radius = Math.Max(0.5f, (float)b.R * h - inset);
        if (bw > 0 && bh > 0)
        {
            var d = Math.Min(radius * 2, Math.Min(bw, bh));
            path.AddArc(bx, by, d, d, 180, 90);
            path.AddArc(bx + bw - d, by, d, d, 270, 90);
            path.AddArc(bx + bw - d, by + bh - d, d, d, 0, 90);
            path.AddArc(bx, by + bh - d, d, d, 90, 90);
            path.CloseFigure();
        }
        foreach (var (cx, cy, r) in CloudShape.Circles)
        {
            var rx = (float)r * w - inset;
            var ry = (float)r * w * 0.92f - inset;
            if (rx <= 0 || ry <= 0) continue;
            path.AddEllipse(x0 + (float)cx * w - rx, y0 + (float)cy * h - ry, 2 * rx, 2 * ry);
        }
        return path;
    }

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr handle);

    public void Dispose()
    {
        breathTimer.Dispose();
        notifyIcon.Visible = false;
        notifyIcon.Dispose();
        offIcon?.Dispose();
        foreach (var icon in onFrames) icon.Dispose();
    }
}
