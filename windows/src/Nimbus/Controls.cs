using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using Nimbus.Core;

namespace Nimbus;

/// <summary>
/// Critically damped spring as a WPF easing curve: x(t) = 1 − (1 + ωt)·e^(−ωt), normalised to end at 1.
/// No overshoot — the same "dampingFraction 1" springs the Mac panel uses.
/// </summary>
internal sealed class SpringEase : EasingFunctionBase
{
    public double Response { get; set; } = 0.34;
    public double DurationSeconds { get; set; } = 0.6;

    protected override double EaseInCore(double t)
    {
        var omega = 2 * Math.PI / Response;
        double F(double x) => 1 - (1 + omega * x) * Math.Exp(-omega * x);
        return F(t * DurationSeconds) / F(DurationSeconds);
    }

    protected override Freezable CreateInstanceCore() => new SpringEase();
}

internal enum SpringKind { Snappy, Smooth, Panel }

internal static class Motion
{
    public static bool Reduce => Theme.ReduceMotion;
    public const double StaggerStep = 0.022;

    private static (double Response, double Duration) Params(SpringKind kind) => kind switch
    {
        SpringKind.Snappy => (0.24, 0.42),
        SpringKind.Panel => (0.42, 0.72),
        _ => (0.34, 0.58),
    };

    public static DoubleAnimation To(double to, SpringKind kind = SpringKind.Smooth, double delay = 0)
    {
        if (Reduce)
            return new DoubleAnimation(to, TimeSpan.FromMilliseconds(130)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
        var (response, duration) = Params(kind);
        return new DoubleAnimation(to, TimeSpan.FromSeconds(duration))
        {
            EasingFunction = new SpringEase { Response = response, DurationSeconds = duration },
            BeginTime = TimeSpan.FromSeconds(delay),
        };
    }

    public static DoubleAnimation FromTo(double from, double to, SpringKind kind = SpringKind.Smooth, double delay = 0)
    {
        var a = To(to, kind, delay);
        a.From = from;
        if (a.BeginTime > TimeSpan.Zero) a.FillBehavior = FillBehavior.HoldEnd;
        return a;
    }

    /// <summary>Offset + blur + fade in (page morphs, panel open). Reduce Motion: fade only.</summary>
    public static void BlurShiftIn(UIElement element, double dx, double dy, double blur, SpringKind kind = SpringKind.Smooth, double delay = 0, double scaleFrom = 1)
    {
        element.BeginAnimation(UIElement.OpacityProperty, FromTo(0, 1, kind, delay));
        if (Reduce)
        {
            element.RenderTransform = Transform.Identity;
            element.Effect = null;
            element.CacheMode = null;
            return;
        }
        var translate = new TranslateTransform(dx, dy);
        var scale = new ScaleTransform(scaleFrom, scaleFrom);
        element.RenderTransform = new TransformGroup { Children = { scale, translate } };
        translate.BeginAnimation(TranslateTransform.XProperty, FromTo(dx, 0, kind, delay));
        translate.BeginAnimation(TranslateTransform.YProperty, FromTo(dy, 0, kind, delay));
        if (Math.Abs(scaleFrom - 1) > 0.0001)
        {
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, FromTo(scaleFrom, 1, kind, delay));
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, FromTo(scaleFrom, 1, kind, delay));
        }
        if (blur > 0)
        {
            var effect = new BlurEffect { Radius = blur, RenderingBias = RenderingBias.Performance };
            element.Effect = effect;
            // while it moves, blur a cached bitmap of the element instead of re-rendering its tree every frame
            var cache = new BitmapCache { SnapsToDevicePixels = true, RenderAtScale = DeviceScale(element) };
            element.CacheMode = cache;
            var anim = FromTo(blur, 0, kind, delay);
            // a lingering blur or cache softens text: drop both once the animation has landed
            anim.Completed += (_, _) =>
            {
                if (element.Effect == effect) element.Effect = null;
                if (element.CacheMode == cache) element.CacheMode = null;
            };
            effect.BeginAnimation(BlurEffect.RadiusProperty, anim);
        }
    }

    /// <summary>
    /// WPF ticks animations at 60 fps unless told otherwise; on a 120/144 Hz screen that halves the motion.
    /// Call once at startup.
    /// </summary>
    public static void UseDisplayRate()
    {
        var hz = 60;
        var dc = GetDC(IntPtr.Zero);
        if (dc != IntPtr.Zero)
        {
            var reported = GetDeviceCaps(dc, 116 /* VREFRESH */);
            ReleaseDC(IntPtr.Zero, dc);
            if (reported > 1) hz = Math.Clamp(reported, 60, 240);
        }
        try
        {
            Timeline.DesiredFrameRateProperty.OverrideMetadata(typeof(Timeline), new FrameworkPropertyMetadata { DefaultValue = (int?)hz });
        }
        catch (ArgumentException)
        {
            // already set for this process
        }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr hwnd);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);

    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    private static extern int GetDeviceCaps(IntPtr dc, int index);

    private static double DeviceScale(UIElement element) =>
        PresentationSource.FromVisual(element)?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;

    /// <summary>Rows fade + lift in one after another (22 ms apart).</summary>
    public static void Stagger(Panel? panel, double start = 0)
    {
        if (panel == null) return;
        var i = 0;
        foreach (UIElement child in panel.Children)
        {
            if (child.Visibility != Visibility.Visible) continue;
            var delay = Reduce ? 0 : start + Math.Min(i, 14) * StaggerStep;
            child.BeginAnimation(UIElement.OpacityProperty, FromTo(0, 1, SpringKind.Smooth, delay));
            if (!Reduce)
            {
                var t = new TranslateTransform(0, 6);
                child.RenderTransform = t;
                t.BeginAnimation(TranslateTransform.YProperty, FromTo(6, 0, SpringKind.Smooth, delay));
            }
            i++;
        }
    }
}

/// <summary>The offset-N mark with animated state morphs and the checking sweep (header of the panel).</summary>
internal sealed class MarkView : FrameworkElement
{
    public static readonly DependencyProperty StateProperty = DependencyProperty.Register(
        nameof(State), typeof(MarkState), typeof(MarkView), new PropertyMetadata(MarkState.Off, (d, _) => ((MarkView)d).Retarget()));
    public static readonly DependencyProperty FillProperty = DependencyProperty.Register(
        nameof(Fill), typeof(Brush), typeof(MarkView), new FrameworkPropertyMetadata(Brushes.White, FrameworkPropertyMetadataOptions.AffectsRender));

    private MarkParams current = MarkParams.Target(MarkState.Off);
    private (double Fill, double Outline, double Gap) velocity;
    private readonly System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();
    private double last, sweepStart;
    private bool hooked;

    public MarkView()
    {
        Width = 16;
        Height = 16;
        Unloaded += (_, _) => Unhook();
        Loaded += (_, _) => Retarget();
    }

    public MarkState State { get => (MarkState)GetValue(StateProperty); set => SetValue(StateProperty, value); }
    public Brush Fill { get => (Brush)GetValue(FillProperty); set => SetValue(FillProperty, value); }

    private void Retarget()
    {
        var now = clock.Elapsed.TotalSeconds;
        if (State == MarkState.Checking) sweepStart = now;
        else if (current.Band is double band) current = current with { Fill = Math.Max(current.Fill, Math.Min(16, band + MarkGeometry.BandWidth)), Band = null };
        if (Motion.Reduce || !IsLoaded)
        {
            current = MarkParams.Target(State) with { Band = State == MarkState.Checking ? 5 : null };
            velocity = default;
            InvalidateVisual();
            return;
        }
        last = now;
        if (!hooked)
        {
            hooked = true;
            CompositionTarget.Rendering += OnFrame;
        }
    }

    private void Unhook()
    {
        if (!hooked) return;
        hooked = false;
        CompositionTarget.Rendering -= OnFrame;
    }

    private void OnFrame(object? sender, EventArgs e)
    {
        var now = clock.Elapsed.TotalSeconds;
        var dt = Math.Clamp(now - last, 0, 0.05);
        last = now;
        var target = MarkParams.Target(State);
        var (f, vf) = Spring.Step(current.Fill, velocity.Fill, target.Fill, 0.34, dt);
        var (o, vo) = Spring.Step(current.Outline, velocity.Outline, target.Outline, 0.34, dt);
        var (g, vg) = Spring.Step(current.Gap, velocity.Gap, target.Gap, 0.34, dt);
        velocity = (vf, vo, vg);
        double? band = State == MarkState.Checking ? MarkGeometry.Band(now - sweepStart) : null;
        current = new MarkParams(f, o, g, band);
        if (State != MarkState.Checking && Spring.Settled(f, vf, target.Fill) && Spring.Settled(o, vo, target.Outline, 0.005) && Spring.Settled(g, vg, target.Gap, 0.005))
        {
            current = target;
            velocity = default;
            Unhook();
        }
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc) => MarkShape.Draw(dc, Math.Min(ActualWidth, ActualHeight), Fill, current);
}

/// <summary>40-bar latency history; bars grow in left → right, the newest bar is accented.</summary>
internal sealed class LatencyChart : FrameworkElement
{
    public static readonly DependencyProperty SamplesProperty = DependencyProperty.Register(
        nameof(Samples), typeof(IReadOnlyList<double>), typeof(LatencyChart), new PropertyMetadata(Array.Empty<double>(), (d, _) => ((LatencyChart)d).InvalidateVisual()));
    public static readonly DependencyProperty AlertProperty = DependencyProperty.Register(
        nameof(Alert), typeof(bool), typeof(LatencyChart), new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty GrowProperty = DependencyProperty.Register(
        nameof(Grow), typeof(double), typeof(LatencyChart), new FrameworkPropertyMetadata(1.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public IReadOnlyList<double> Samples { get => (IReadOnlyList<double>)GetValue(SamplesProperty); set => SetValue(SamplesProperty, value); }
    public bool Alert { get => (bool)GetValue(AlertProperty); set => SetValue(AlertProperty, value); }
    public double Grow { get => (double)GetValue(GrowProperty); set => SetValue(GrowProperty, value); }

    public LatencyChart() => Height = 26;

    /// <summary>Re-run the left-to-right growth (page appear).</summary>
    public void Replay()
    {
        if (Motion.Reduce) { Grow = 1; return; }
        BeginAnimation(GrowProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.9)) { EasingFunction = new SpringEase { Response = 0.5, DurationSeconds = 0.9 } });
    }

    protected override void OnRender(DrawingContext dc)
    {
        const int count = 40;
        var values = (Samples ?? Array.Empty<double>()).TakeLast(count).ToList();
        while (values.Count < count) values.Insert(0, double.NaN);
        var finite = values.Where(double.IsFinite).ToList();
        var lo = Math.Max(0, (finite.Count > 0 ? finite.Min() : 0) - 20);
        var hi = Math.Max(lo + 40, finite.Count > 0 ? finite.Max() : 100);
        var line2 = (Brush)(TryFindResource("Line2Brush") ?? Brushes.Gray);
        var accent = (Brush)(TryFindResource(Alert ? "WarnBrush" : "AccentBrush") ?? Brushes.SlateBlue);
        var w = ActualWidth;
        var step = (w - 4) / (count - 1);
        for (var i = 0; i < count; i++)
        {
            var v = values[i];
            // each bar starts growing a little after its left neighbour
            var local = Math.Clamp(Grow * 1.6 - i / (double)count * 0.6, 0, 1);
            var h = double.IsFinite(v) ? 3 + (Math.Min(v, hi) - lo) / (hi - lo) * 23 : 2;
            h = 2 + (h - 2) * local;
            var last = i == count - 1 && double.IsFinite(v);
            dc.DrawRoundedRectangle(last ? accent : line2, null, new Rect(i * step, ActualHeight - h, 4, h), 1, 1);
        }
    }
}

/// <summary>Text that lifts + blurs out while the new value rises in (hero title, status line).</summary>
internal sealed class SwapText : Grid
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text), typeof(string), typeof(SwapText), new PropertyMetadata("", (d, e) => ((SwapText)d).Swap((string)e.OldValue, (string)e.NewValue)));

    public string Text { get => (string)GetValue(TextProperty); set => SetValue(TextProperty, value); }

    private TextBlock? shown;

    public SwapText() => ClipToBounds = false;

    // font family/size/weight/colour are inherited from the TextElement.* attached properties set on this panel
    private static TextBlock Make(string text) => new() { Text = text, TextTrimming = TextTrimming.CharacterEllipsis };

    private void Swap(string? oldValue, string newValue)
    {
        var next = Make(newValue);
        Children.Add(next);
        if (shown == null || !IsLoaded)
        {
            if (shown != null) Children.Remove(shown);
            shown = next;
            return;
        }
        var old = shown;
        shown = next;
        var fade = Motion.To(0, SpringKind.Snappy);
        fade.Completed += (_, _) => Children.Remove(old);
        old.BeginAnimation(OpacityProperty, fade);
        if (!Motion.Reduce)
        {
            var t = new TranslateTransform();
            old.RenderTransform = t;
            t.BeginAnimation(TranslateTransform.YProperty, Motion.To(-5, SpringKind.Snappy));
        }
        Motion.BlurShiftIn(next, 0, 5, 2, SpringKind.Snappy);
    }
}

/// <summary>Numbers roll digit by digit: each changed character slides up out of a clipped cell while the new one rises in.</summary>
internal sealed class RollingText : StackPanel
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text), typeof(string), typeof(RollingText), new PropertyMetadata("", (d, e) => ((RollingText)d).Roll((string)e.OldValue ?? "", (string)e.NewValue ?? "")));

    public string Text { get => (string)GetValue(TextProperty); set => SetValue(TextProperty, value); }

    public RollingText() => Orientation = Orientation.Horizontal;

    private void Roll(string oldText, string newText)
    {
        var animate = IsLoaded && !Motion.Reduce && oldText.Length > 0;
        var up = CompareNumbers(oldText, newText);
        // align from the right so units stay put and digits line up
        var cells = Children.OfType<Grid>().ToList();
        while (cells.Count < newText.Length)
        {
            var cell = new Grid { ClipToBounds = true };
            Children.Insert(0, cell);
            cells.Insert(0, cell);
        }
        while (cells.Count > newText.Length)
        {
            Children.Remove(cells[0]);
            cells.RemoveAt(0);
        }
        var oldPadded = oldText.PadLeft(newText.Length);
        for (var i = 0; i < newText.Length; i++)
        {
            var cell = cells[i];
            var ch = newText[i].ToString();
            var previous = cell.Children.OfType<TextBlock>().LastOrDefault();
            if (previous != null && previous.Text == ch) continue;
            var tb = new TextBlock { Text = ch };
            cell.Children.Add(tb);
            if (previous == null || !animate || oldPadded[i] == newText[i])
            {
                if (previous != null) cell.Children.Remove(previous);
                continue;
            }
            var dy = up ? 9 : -9;
            var outT = new TranslateTransform();
            previous.RenderTransform = outT;
            var outAnim = Motion.To(-dy, SpringKind.Smooth, i * 0.015);
            outAnim.Completed += (_, _) => cell.Children.Remove(previous);
            outT.BeginAnimation(TranslateTransform.YProperty, outAnim);
            previous.BeginAnimation(OpacityProperty, Motion.To(0, SpringKind.Smooth, i * 0.015));
            var inT = new TranslateTransform(0, dy);
            tb.RenderTransform = inT;
            inT.BeginAnimation(TranslateTransform.YProperty, Motion.FromTo(dy, 0, SpringKind.Smooth, i * 0.015));
            tb.BeginAnimation(OpacityProperty, Motion.FromTo(0, 1, SpringKind.Smooth, i * 0.015));
        }
    }

    private static bool CompareNumbers(string a, string b)
    {
        static double? N(string s) => double.TryParse(new string(s.Where(c => char.IsDigit(c) || c == '.').ToArray()), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var v) ? v : null;
        return (N(b) ?? 0) >= (N(a) ?? 0);
    }
}

/// <summary>6 px status dot; pulses while checking.</summary>
internal sealed class StatusDot : FrameworkElement
{
    public static readonly DependencyProperty BrushKeyProperty = DependencyProperty.Register(
        nameof(BrushKey), typeof(string), typeof(StatusDot), new FrameworkPropertyMetadata("T3Brush", FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty PulsingProperty = DependencyProperty.Register(
        nameof(Pulsing), typeof(bool), typeof(StatusDot), new PropertyMetadata(false, (d, _) => ((StatusDot)d).UpdatePulse()));

    public string BrushKey { get => (string)GetValue(BrushKeyProperty); set => SetValue(BrushKeyProperty, value); }
    public bool Pulsing { get => (bool)GetValue(PulsingProperty); set => SetValue(PulsingProperty, value); }

    public StatusDot()
    {
        Width = 6;
        Height = 6;
        VerticalAlignment = VerticalAlignment.Center;
        Loaded += (_, _) => UpdatePulse();
    }

    private void UpdatePulse()
    {
        if (Pulsing && !Motion.Reduce)
            BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0.35, TimeSpan.FromSeconds(0.45)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut } });
        else
        {
            BeginAnimation(OpacityProperty, null);
            Opacity = 1;
        }
    }

    protected override void OnRender(DrawingContext dc)
    {
        var brush = (Brush)(TryFindResource(BrushKey) ?? Brushes.Gray);
        dc.DrawEllipse(brush, null, new Point(3, 3), 3, 3);
    }
}

/// <summary>Small arc spinner (diagnostics, tests).</summary>
internal sealed class ArcSpinner : FrameworkElement
{
    private readonly RotateTransform rotation = new();

    public ArcSpinner()
    {
        Width = 12;
        Height = 12;
        VerticalAlignment = VerticalAlignment.Center;
        RenderTransformOrigin = new Point(0.5, 0.5);
        RenderTransform = rotation;
        Loaded += (_, _) =>
        {
            if (!Motion.Reduce)
                rotation.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0, 360, TimeSpan.FromSeconds(0.75)) { RepeatBehavior = RepeatBehavior.Forever });
        };
        Unloaded += (_, _) => rotation.BeginAnimation(RotateTransform.AngleProperty, null);
    }

    protected override void OnRender(DrawingContext dc)
    {
        var track = new Pen((Brush)(TryFindResource("Line2Brush") ?? Brushes.Gray), 1.5);
        var head = new Pen((Brush)(TryFindResource("T2Brush") ?? Brushes.Gray), 1.5) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        var r = Math.Min(ActualWidth, ActualHeight) / 2 - 0.75;
        var c = new Point(ActualWidth / 2, ActualHeight / 2);
        dc.DrawEllipse(null, track, c, r, r);
        var arc = new StreamGeometry();
        using (var ctx = arc.Open())
        {
            ctx.BeginFigure(new Point(c.X, c.Y - r), false, false);
            ctx.ArcTo(new Point(c.X + r, c.Y), new Size(r, r), 0, false, SweepDirection.Clockwise, true, false);
        }
        dc.DrawGeometry(null, head, arc);
    }
}

/// <summary>Row of 18 px keycaps from a space-separated string ("Ctrl K").</summary>
internal sealed class KeyCaps : StackPanel
{
    public static readonly DependencyProperty KeysProperty = DependencyProperty.Register(
        nameof(Keys), typeof(string), typeof(KeyCaps), new PropertyMetadata("", (d, _) => ((KeyCaps)d).Build()));
    public static readonly DependencyProperty OnAccentProperty = DependencyProperty.Register(
        nameof(OnAccent), typeof(bool), typeof(KeyCaps), new PropertyMetadata(false, (d, _) => ((KeyCaps)d).Build()));

    public string Keys { get => (string)GetValue(KeysProperty); set => SetValue(KeysProperty, value); }
    public bool OnAccent { get => (bool)GetValue(OnAccentProperty); set => SetValue(OnAccentProperty, value); }

    public KeyCaps()
    {
        Orientation = Orientation.Horizontal;
        VerticalAlignment = VerticalAlignment.Center;
    }

    private void Build()
    {
        Children.Clear();
        foreach (var key in (Keys ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            var text = new TextBlock
            {
                Text = key,
                FontSize = 11,
                FontWeight = FontWeights.Medium,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
            var cap = new Border
            {
                MinWidth = 18,
                Height = 18,
                Padding = new Thickness(key.Length > 1 ? 4 : 0, 0, key.Length > 1 ? 4 : 0, 0),
                CornerRadius = new CornerRadius(4),
                BorderThickness = new Thickness(OnAccent ? 0 : 1),
                Margin = new Thickness(Children.Count == 0 ? 0 : 3, 0, 0, 0),
                Child = text,
            };
            if (OnAccent)
            {
                cap.Background = new SolidColorBrush(Color.FromArgb(0x2E, 0xFF, 0xFF, 0xFF));
                text.Foreground = Brushes.White;
            }
            else
            {
                cap.SetResourceReference(Border.BackgroundProperty, "KbdBrush");
                cap.SetResourceReference(Border.BorderBrushProperty, "LineBrush");
                text.SetResourceReference(TextBlock.ForegroundProperty, "T2Brush");
            }
            Children.Add(cap);
        }
    }
}
