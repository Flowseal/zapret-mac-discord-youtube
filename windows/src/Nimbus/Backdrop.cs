using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace Nimbus;

/// <summary>
/// Transparent panel window without WS_EX_LAYERED. A layered window (AllowsTransparency) makes WPF copy
/// every frame from the GPU back into system memory, which is what made the panel animations stutter.
/// Extending the DWM frame over the whole client area gives the same per-pixel alpha on the GPU path.
/// </summary>
internal static class Backdrop
{
    /// <summary>NIMBUS_WINDOW=layered|composed overrides the choice (CI compares both).</summary>
    public static bool UseComposition
    {
        get
        {
            var forced = Environment.GetEnvironmentVariable("NIMBUS_WINDOW");
            if (forced == "layered") return false;
            if (forced == "composed") return CompositionEnabled;
            // software rendering can't hand DWM an alpha channel; keep the layered window there
            return CompositionEnabled && RenderCapability.Tier >> 16 > 0;
        }
    }

    private static bool CompositionEnabled
    {
        get
        {
            try { return DwmIsCompositionEnabled(out var on) == 0 && on; }
            catch { return false; }
        }
    }

    /// <summary>Call from SourceInitialized.</summary>
    public static void Apply(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (HwndSource.FromHwnd(hwnd) is { CompositionTarget: { } target }) target.BackgroundColor = Colors.Transparent;
        var margins = new Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
        DwmExtendFrameIntoClientArea(hwnd, ref margins);
        // our own open/close animation only: no DWM fade, no Windows 11 rounding or border on the window
        Set(hwnd, DwmTransitionsForceDisabled, 1);
        Set(hwnd, DwmWindowCornerPreference, 1);
        Set(hwnd, DwmBorderColor, unchecked((int)0xFFFFFFFE));
    }

    private static void Set(IntPtr hwnd, int attribute, int value)
    {
        try { DwmSetWindowAttribute(hwnd, attribute, ref value, sizeof(int)); }
        catch { /* attribute not known to this Windows version */ }
    }

    private const int DwmTransitionsForceDisabled = 3;
    private const int DwmWindowCornerPreference = 33;
    private const int DwmBorderColor = 34;

    [StructLayout(LayoutKind.Sequential)]
    private struct Margins { public int Left, Right, Top, Bottom; }

    [DllImport("dwmapi.dll")]
    private static extern int DwmIsCompositionEnabled(out bool enabled);

    [DllImport("dwmapi.dll")]
    private static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins margins);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
}
