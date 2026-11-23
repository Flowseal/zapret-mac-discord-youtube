using System;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using Nimbus.Core;

namespace Nimbus;

/// <summary>The popover shown from the notification area; WPF port of NimbusHUDView.</summary>
internal partial class HudWindow : Window
{
    private readonly HudModel model;
    private readonly Geometry cloud = CloudShape.Build(36, 28);
    private DateTime hiddenAt = DateTime.MinValue;
    private bool? headerRunning;

    public HudWindow(HudModel model)
    {
        this.model = model;
        InitializeComponent();
        DataContext = model;
        HeaderCloud.Data = cloud;
        model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(HudModel.Running)) UpdateHeader(animate: true);
        };
        UpdateHeader(animate: false);
        Deactivated += (_, _) => HideHud();
        SizeChanged += (_, _) => { if (IsVisible) Reposition(); };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Escape) HideHud();
        };
    }

    public bool RecentlyHidden => (DateTime.UtcNow - hiddenAt).TotalMilliseconds < 350;

    public void ShowHud()
    {
        if (!IsVisible)
        {
            Opacity = 0;
            Show();
        }
        Reposition();
        Activate();
        BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(120)));
    }

    public void HideHud()
    {
        if (!IsVisible) return;
        hiddenAt = DateTime.UtcNow;
        Hide();
        if (!model.Testing) model.Page = HudPage.Main;
    }

    /// <summary>Anchors the popover to the corner of the work area next to the taskbar, like a flyout.</summary>
    public void Reposition()
    {
        var cursor = System.Windows.Forms.Control.MousePosition;
        var screen = System.Windows.Forms.Screen.FromPoint(cursor);
        var work = screen.WorkingArea;
        var bounds = screen.Bounds;
        var source = PresentationSource.FromVisual(this);
        var scaleX = source?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
        var scaleY = source?.CompositionTarget?.TransformToDevice.M22 ?? 1.0;
        var width = ActualWidth > 0 ? ActualWidth : Width;
        var height = ActualHeight > 0 ? ActualHeight : 400;
        const double gap = 4;

        double left = work.Right / scaleX - width - gap;
        double top = work.Bottom / scaleY - height - gap;
        if (work.Top > bounds.Top) top = work.Top / scaleY + gap;         // taskbar on top
        if (work.Left > bounds.Left) left = work.Left / scaleX + gap;     // taskbar on the left
        Left = Math.Max(work.Left / scaleX, left);
        Top = Math.Max(work.Top / scaleY, top);
    }

    private void UpdateHeader(bool animate)
    {
        if (headerRunning == model.Running) return;
        headerRunning = model.Running;
        var target = model.Running ? Theme.Blue : ((SolidColorBrush)FindResource("OffCircleBrush")).Color;
        if (HeaderCircle.Fill is not SolidColorBrush brush || brush.IsFrozen)
        {
            brush = new SolidColorBrush(target);
            HeaderCircle.Fill = brush;
        }
        if (animate) brush.BeginAnimation(SolidColorBrush.ColorProperty, new ColorAnimation(target, TimeSpan.FromMilliseconds(320)));
        else brush.Color = target;

        if (model.Running)
        {
            HeaderCloud.Fill = Brushes.White;
            HeaderCloud.Stroke = null;
            // SF Symbol .pulse effect
            var pulse = new DoubleAnimation(1, 0.55, TimeSpan.FromSeconds(1.4)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase() };
            HeaderCloud.BeginAnimation(OpacityProperty, pulse);
        }
        else
        {
            HeaderCloud.Fill = null;
            HeaderCloud.Stroke = Brushes.White;
            HeaderCloud.BeginAnimation(OpacityProperty, null);
            HeaderCloud.Opacity = 1;
        }
    }

    public void RefreshThemeBrushes()
    {
        headerRunning = null;
        UpdateHeader(animate: false);
    }

    private void ShowMenu(Button anchor, ContextMenu menu)
    {
        menu.PlacementTarget = anchor;
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
        menu.HorizontalOffset = anchor.ActualWidth - 200;
        menu.MinWidth = 200;
        menu.IsOpen = true;
    }

    private void StrategyRow_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu();
        foreach (var strategy in model.Strategies)
        {
            var item = new MenuItem { Header = strategy.Name, IsChecked = strategy.Id == model.SelectedStrategyId };
            var id = strategy.Id;
            item.Click += (_, _) => model.SelectStrategy(id);
            menu.Items.Add(item);
        }
        ShowMenu((Button)sender, menu);
    }

    private void PresetRow_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu();
        foreach (var (id, title) in new[] { (IpsetModes.None, "Нет"), (IpsetModes.Loaded, "Стандартный"), (IpsetModes.Any, "Все") })
        {
            var item = new MenuItem { Header = title, IsChecked = model.IpsetMode == id };
            item.Click += (_, _) => model.SelectIpset(id);
            menu.Items.Add(item);
        }
        ShowMenu((Button)sender, menu);
    }

    private void GameFilterRow_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu();
        foreach (var (id, title) in new[] { (GameFilterModes.Off, "Выкл"), (GameFilterModes.Games, "Игры"), (GameFilterModes.Wide, "Широкий") })
        {
            var item = new MenuItem { Header = title, IsChecked = model.GameFilterMode == id };
            item.Click += (_, _) => model.SelectGameFilter(id);
            menu.Items.Add(item);
        }
        ShowMenu((Button)sender, menu);
    }

    private void ToggleService_Click(object sender, RoutedEventArgs e) => model.ToggleService();
    private void ToggleLogin_Click(object sender, RoutedEventArgs e) => model.ToggleLogin();
    private void More_Click(object sender, RoutedEventArgs e) => model.Page = HudPage.More;
    private void Back_Click(object sender, RoutedEventArgs e) => model.GoBack();
    private void Quit_Click(object sender, RoutedEventArgs e) => model.Quit();
    private void DismissNotice_Click(object sender, RoutedEventArgs e) => model.DismissNotice();
    private void TestStrategies_Click(object sender, RoutedEventArgs e) => model.TestStrategies();
    private void ApplyBest_Click(object sender, RoutedEventArgs e) => model.ApplyBest();
    private void TestRow_Click(object sender, RoutedEventArgs e) => model.ApplyTestRow((string)((Button)sender).Tag);
    private void Lists_Click(object sender, RoutedEventArgs e) => model.OpenLists();
    private void ListRow_Click(object sender, RoutedEventArgs e) => model.OpenList((string)((Button)sender).Tag);
    private void SaveList_Click(object sender, RoutedEventArgs e) => model.SaveList();
    private void Logs_Click(object sender, RoutedEventArgs e)
    {
        model.OpenLogs();
        Dispatcher.BeginInvoke(DispatcherPriority.Background, () => LogsBox.ScrollToEnd());
    }
    private void CopyLogs_Click(object sender, RoutedEventArgs e) => model.CopyLogs();
    private void Restart_Click(object sender, RoutedEventArgs e) => model.RestartService();
    private void GitHub_Click(object sender, RoutedEventArgs e) => model.OpenGitHub();
    private void InstallUpdate_Click(object sender, RoutedEventArgs e) => model.InstallUpdate();
}

internal sealed class InverseVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

internal sealed class HealthBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        var key = value switch
        {
            ServiceHealth.Ok => "GreenBrush",
            ServiceHealth.Bad => "RedBrush",
            ServiceHealth.Checking => "AccentBrush",
            _ => "OffDotBrush",
        };
        return Application.Current.TryFindResource(key) ?? Brushes.Gray;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>Small indeterminate spinner (SwiftUI ProgressView, mini size).</summary>
internal sealed class Spinner : FrameworkElement
{
    private readonly RotateTransform rotation = new();

    public Spinner()
    {
        RenderTransformOrigin = new Point(0.5, 0.5);
        RenderTransform = rotation;
        Loaded += (_, _) => rotation.BeginAnimation(RotateTransform.AngleProperty,
            new DoubleAnimation(0, 360, TimeSpan.FromSeconds(0.9)) { RepeatBehavior = RepeatBehavior.Forever });
        Unloaded += (_, _) => rotation.BeginAnimation(RotateTransform.AngleProperty, null);
    }

    protected override void OnRender(DrawingContext dc)
    {
        var brush = (Brush?)TryFindResource("SecondaryBrush") ?? Brushes.Gray;
        var r = Math.Min(ActualWidth, ActualHeight) / 2;
        var c = new Point(ActualWidth / 2, ActualHeight / 2);
        for (var i = 0; i < 8; i++)
        {
            var angle = i * Math.PI / 4;
            var pen = new Pen(brush.CloneCurrentValue(), 1.6) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
            pen.Brush.Opacity = 0.25 + 0.75 * i / 7.0;
            dc.DrawLine(pen,
                new Point(c.X + Math.Cos(angle) * r * 0.45, c.Y + Math.Sin(angle) * r * 0.45),
                new Point(c.X + Math.Cos(angle) * r * 0.95, c.Y + Math.Sin(angle) * r * 0.95));
        }
    }
}
