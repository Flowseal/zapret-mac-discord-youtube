using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using Nimbus.Core;

namespace Nimbus;

/// <summary>The panel shown from the notification area; WPF port of NimbusHUDView.</summary>
internal partial class HudWindow : Window
{
    private const double ShadowMargin = 18;
    private const double EdgeGap = 12;

    private readonly HudModel model;
    private readonly DispatcherTimer ticker = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly Dictionary<FrameworkElement, Thickness> filteredMargins = new();
    private DateTime hiddenAt = DateTime.MinValue;
    private HudPage shownPage = HudPage.Main;
    private bool hiding;

    public HudWindow(HudModel model)
    {
        this.model = model;
        InitializeComponent();
        AllowsTransparency = !Backdrop.UseComposition;
        if (!AllowsTransparency) SourceInitialized += (_, _) => Backdrop.Apply(this);
        DataContext = model;
        BuildSkeleton();
        model.PropertyChanged += OnModelChanged;
        Deactivated += (_, _) => { if (!model.PaletteOpen || !IsKeyboardFocusWithin) HideHud(); };
        SizeChanged += (_, _) =>
        {
            ClipPanel();
            if (IsVisible) { Reposition(); UpdateTestBar(); }
        };
        PreviewKeyDown += OnPreviewKeyDown;
        PreviewMouseDown += (_, e) =>
        {
            // the transparent shadow margin is part of the window: a click there counts as outside
            var p = e.GetPosition(Root);
            if (p.X < 0 || p.Y < 0 || p.X > Root.ActualWidth || p.Y > Root.ActualHeight)
            {
                e.Handled = true;
                HideHud();
            }
        };
        ticker.Tick += (_, _) => model.Tick();
        Loaded += (_, _) =>
        {
            ClipPanel();
            UpdateGutter();
            if (model.PaletteOpen) ShowPalette(animate: false);
            if (model.Page == HudPage.Diagnostics) ResolveDiagnostics(animate: false);
        };
    }

    public bool RecentlyHidden => (DateTime.UtcNow - hiddenAt).TotalMilliseconds < 350;

    private static int Depth(HudPage page) => page switch
    {
        HudPage.Main => 0,
        HudPage.More => 1,
        HudPage.Editor => 3,
        _ => 2,
    };

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(HudModel.Page):
                MorphToPage(model.Page);
                break;
            case nameof(HudModel.PaletteOpen):
                if (model.PaletteOpen) ShowPalette(animate: true);
                else HidePalette();
                break;
            case nameof(HudModel.PaletteIndex):
                ScrollPaletteSelection();
                break;
            case nameof(HudModel.Diagnostics):
                Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () => ResolveDiagnostics(animate: IsVisible));
                break;
            case nameof(HudModel.TestFraction):
            case nameof(HudModel.ShowTestBar):
                UpdateTestBar();
                break;
            case nameof(HudModel.VisibleLogRows):
                if (model.Page == HudPage.Logs) Dispatcher.BeginInvoke(DispatcherPriority.Background, ScrollLogsToEnd);
                break;
            case nameof(HudModel.EditorText):
                UpdateGutter();
                break;
            case nameof(HudModel.Testing):
            case nameof(HudModel.Running):
            case nameof(HudModel.CanInstallUpdate):
            case nameof(HudModel.Updating):
                ApplyMoreFilter();
                break;
        }
    }

    // ---------------- open / close ----------------

    public void ShowHud()
    {
        hiding = false;
        var wasVisible = IsVisible;
        if (!wasVisible)
        {
            Root.Opacity = 0;
            Show();
        }
        UpdateLayout();
        Reposition();
        Activate();
        ticker.Start();
        model.Tick();
        if (!wasVisible)
        {
            // blur-in: the panel rises from the taskbar slightly small, transparent and blurred, then springs to rest
            Root.RenderTransformOrigin = new Point(0.5, TaskbarOnTop ? 0 : 1);
            Motion.BlurShiftIn(Root, 0, TaskbarOnTop ? -6 : 6, 8, SpringKind.Panel, 0, 0.96);
            RevealPage(model.Page, 0.04);
        }
        UpdateTestBar();
    }

    public void HideHud()
    {
        if (!IsVisible || hiding) return;
        hiding = true;
        hiddenAt = DateTime.UtcNow;
        ticker.Stop();
        model.PaletteOpen = false;
        var fade = Motion.To(0, SpringKind.Snappy);
        fade.Duration = TimeSpan.FromMilliseconds(Motion.Reduce ? 110 : 180);
        fade.Completed += (_, _) =>
        {
            if (!hiding) return;
            Hide();
            hiding = false;
            Root.BeginAnimation(OpacityProperty, null);
            Root.Opacity = 1;
            Root.RenderTransform = Transform.Identity;
            Root.Effect = null;
            if (!model.Testing) model.Page = HudPage.Main;
        };
        if (!Motion.Reduce)
        {
            var scale = new ScaleTransform(1, 1);
            Root.RenderTransform = scale;
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, Motion.To(0.98, SpringKind.Snappy));
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, Motion.To(0.98, SpringKind.Snappy));
        }
        Root.BeginAnimation(OpacityProperty, fade);
    }

    private static bool TaskbarOnTop
    {
        get
        {
            var screen = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Control.MousePosition);
            return screen.WorkingArea.Top > screen.Bounds.Top;
        }
    }

    /// <summary>Anchors the panel to the work-area corner next to the taskbar, like a flyout.</summary>
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
        var inset = EdgeGap - ShadowMargin;

        double left = work.Right / scaleX - width - inset;
        double top = work.Bottom / scaleY - height - inset;
        if (work.Top > bounds.Top) top = work.Top / scaleY + inset;
        if (work.Left > bounds.Left) left = work.Left / scaleX + inset;
        Left = Math.Max(work.Left / scaleX - ShadowMargin, left);
        Top = Math.Max(work.Top / scaleY - ShadowMargin, top);
    }

    private void ClipPanel()
    {
        var w = PanelClip.ActualWidth;
        var h = PanelClip.ActualHeight;
        if (w <= 0 || h <= 0) return;
        PanelClip.Clip = new RectangleGeometry(new Rect(0, 0, w, h), 8, 8);
    }

    public void RefreshThemeBrushes()
    {
        foreach (var element in new FrameworkElement[] { Chart })
            element.InvalidateVisual();
    }

    // ---------------- page morphs ----------------

    private FrameworkElement PageElement(HudPage page) => page switch
    {
        HudPage.More => MorePage,
        HudPage.Logs => LogsPage,
        HudPage.Lists => ListsPage,
        HudPage.Editor => EditorPage,
        HudPage.Diagnostics => DiagnosticsPage,
        _ => MainPage,
    };

    private Panel? PageRows(HudPage page) => page switch
    {
        HudPage.More => MoreRows,
        HudPage.Logs => LogsRows,
        HudPage.Lists => ListsRows,
        HudPage.Editor => EditorRows,
        HudPage.Diagnostics => DiagnosticsRows,
        _ => MainRows,
    };

    private void MorphToPage(HudPage page)
    {
        var forward = Depth(page) >= Depth(shownPage);
        shownPage = page;
        if (page != HudPage.More && model.MoreQuery.Length > 0) model.MoreQuery = "";
        var element = PageElement(page);
        if (IsVisible) Motion.BlurShiftIn(element, forward ? 20 : -20, 0, 4, SpringKind.Smooth);
        RevealPage(page, 0.03);
        Dispatcher.BeginInvoke(DispatcherPriority.Input, () =>
        {
            if (page == HudPage.Logs) ScrollLogsToEnd();
            if (page == HudPage.Editor) { EditorBox.Focus(); EditorBox.CaretIndex = 0; UpdateGutter(); }
            if (page == HudPage.Lists) ListInputBox.Focus();
            if (page == HudPage.More) ApplyMoreFilter();
        });
    }

    private void RevealPage(HudPage page, double start)
    {
        if (!IsVisible) return;
        Motion.Stagger(PageRows(page), start);
        if (page == HudPage.Main) Chart.Replay();
    }

    // ---------------- keyboard ----------------

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        var ctrl = (Keyboard.Modifiers & ModifierKeys.Control) != 0;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var inText = Keyboard.FocusedElement is TextBox;

        if (model.PaletteOpen)
        {
            var count = model.FilteredPalette.Count;
            switch (key)
            {
                case Key.Escape:
                    model.ClosePalette();
                    e.Handled = true;
                    return;
                case Key.Down:
                    if (count > 0) model.PaletteIndex = Math.Min(count - 1, model.PaletteIndex + 1);
                    e.Handled = true;
                    return;
                case Key.Up:
                    model.PaletteIndex = Math.Max(0, model.PaletteIndex - 1);
                    e.Handled = true;
                    return;
                case Key.Enter:
                    model.RunPalette();
                    e.Handled = true;
                    return;
                case Key.K when ctrl:
                    model.ClosePalette();
                    e.Handled = true;
                    return;
            }
            return;
        }

        if (key == Key.Escape)
        {
            if (model.Page == HudPage.Editor) CancelEdit();
            else if (model.Page == HudPage.Main) HideHud();
            else model.GoBack();
            e.Handled = true;
            return;
        }

        if (ctrl)
        {
            e.Handled = true;
            switch (key)
            {
                case Key.K: model.OpenPalette(); break;
                case Key.Enter: model.PerformToggle(); break;
                case Key.F: if (model.FindEnabled) model.FindAndApply(); break;
                case Key.T:
                    if (model.FullTestEnabled) { model.Page = HudPage.More; model.TestStrategies(); }
                    break;
                case Key.U: if (model.CanUpdateLists) model.UpdateLists(); break;
                case Key.R:
                    if (model.Page == HudPage.Diagnostics) { if (!model.DiagnosticsRunning) model.OpenDiagnostics(); }
                    else if (model.Running && model.CanRestart) model.RestartService();
                    break;
                case Key.L: model.OpenLists(); break;
                case Key.D: model.OpenDiagnostics(); break;
                case Key.J: model.OpenLogs(); break;
                case Key.Q: model.Quit(); break;
                case Key.S:
                    if (model.Page == HudPage.Editor) Save();
                    else e.Handled = false;
                    break;
                case Key.C:
                    if (Keyboard.FocusedElement is TextBox box && box.SelectionLength > 0) { e.Handled = false; break; }
                    if (model.Page == HudPage.Logs) model.CopyLogs();
                    else if (model.Page == HudPage.Diagnostics) model.CopyDiagnostics();
                    else e.Handled = false;
                    break;
                default:
                    e.Handled = false;
                    break;
            }
            return;
        }

        if (key == Key.OemQuestion && !inText && model.Page == HudPage.Logs)
        {
            LogFilter.Focus();
            e.Handled = true;
            return;
        }
        if (key == Key.Enter && !inText && model.Page == HudPage.Main && model.IsProblem && model.FindEnabled)
        {
            model.FindAndApply();
            e.Handled = true;
        }
    }

    // ---------------- command bar ----------------

    private void ShowPalette(bool animate)
    {
        Scrim.Visibility = Visibility.Visible;
        Palette.Visibility = Visibility.Visible;
        if (animate)
        {
            Scrim.BeginAnimation(OpacityProperty, Motion.FromTo(0, 1, SpringKind.Smooth));
            Motion.BlurShiftIn(Palette, 0, 6, 6, SpringKind.Smooth, 0, 0.97);
        }
        Dispatcher.BeginInvoke(DispatcherPriority.Input, () => { PaletteBox.Focus(); Keyboard.Focus(PaletteBox); });
    }

    private void HidePalette()
    {
        if (Palette.Visibility != Visibility.Visible) return;
        var fade = Motion.To(0, SpringKind.Snappy);
        fade.Duration = TimeSpan.FromMilliseconds(140);
        fade.Completed += (_, _) =>
        {
            if (model.PaletteOpen) return;
            Scrim.Visibility = Visibility.Collapsed;
            Palette.Visibility = Visibility.Collapsed;
            Palette.BeginAnimation(OpacityProperty, null);
            Scrim.BeginAnimation(OpacityProperty, null);
        };
        Palette.BeginAnimation(OpacityProperty, fade);
        Scrim.BeginAnimation(OpacityProperty, Motion.To(0, SpringKind.Snappy));
    }

    private void ScrollPaletteSelection()
    {
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
        {
            if (PaletteList.ItemContainerGenerator.ContainerFromIndex(model.PaletteIndex) is FrameworkElement item)
                item.BringIntoView();
        });
    }

    private void Palette_Click(object sender, RoutedEventArgs e) => model.OpenPalette();
    private void Scrim_MouseDown(object sender, MouseButtonEventArgs e) => model.ClosePalette();

    private void PaletteItem_Click(object sender, MouseButtonEventArgs e)
    {
        if (((FrameworkElement)sender).Tag is PaletteItem item)
        {
            var index = model.FilteredPalette.Select((p, i) => (p, i)).FirstOrDefault(x => x.p.Id == item.Id).i;
            model.RunPalette(index);
        }
    }

    private void PaletteItem_Enter(object sender, MouseEventArgs e)
    {
        if (((FrameworkElement)sender).Tag is PaletteItem item)
        {
            var index = model.FilteredPalette.Select((p, i) => (p, i)).FirstOrDefault(x => x.p.Id == item.Id).i;
            if (index != model.PaletteIndex) model.PaletteIndex = index;
        }
    }

    // ---------------- Ещё: search filter ----------------

    private void MoreSearch_TextChanged(object sender, TextChangedEventArgs e) => ApplyMoreFilter();

    private void ApplyMoreFilter()
    {
        var q = model.MoreQuery.Trim().ToLowerInvariant();
        DockPanel? section = null;
        var sectionHasRows = false;
        void CloseSection()
        {
            if (section != null) SetFiltered(section, q.Length > 0 && !sectionHasRows);
        }
        foreach (UIElement child in MoreRows.Children)
        {
            if (child is DockPanel dp && dp.Tag is string)
            {
                CloseSection();
                section = dp;
                sectionHasRows = false;
                continue;
            }
            if (child is not FrameworkElement fe) continue;
            var keywords = Search.GetKeywords(fe);
            if (keywords == null) continue;
            var match = q.Length == 0 || keywords.Contains(q) || (fe is Button b && ButtonText(b).ToLowerInvariant().Contains(q));
            SetFiltered(fe, !match);
            if (match && fe.Visibility == Visibility.Visible) sectionHasRows = true;
        }
        CloseSection();
    }

    private static string ButtonText(DependencyObject root)
    {
        var parts = new List<string>();
        void Walk(DependencyObject d)
        {
            if (d is TextBlock tb && tb.FontFamily.Source.IndexOf("Icons", StringComparison.Ordinal) < 0 && tb.FontFamily.Source.IndexOf("MDL2", StringComparison.Ordinal) < 0) parts.Add(tb.Text);
            foreach (var c in LogicalTreeHelper.GetChildren(d).OfType<DependencyObject>()) Walk(c);
        }
        Walk(root);
        return string.Join(" ", parts);
    }

    /// <summary>Hide without touching Visibility (which is data-bound on several rows).</summary>
    private void SetFiltered(FrameworkElement fe, bool hidden)
    {
        if (hidden)
        {
            if (!filteredMargins.ContainsKey(fe)) filteredMargins[fe] = fe.Margin;
            fe.MaxHeight = 0;
            fe.Margin = new Thickness(fe.Margin.Left, 0, fe.Margin.Right, 0);
            fe.IsHitTestVisible = false;
        }
        else if (filteredMargins.TryGetValue(fe, out var margin))
        {
            fe.MaxHeight = double.PositiveInfinity;
            fe.Margin = margin;
            fe.IsHitTestVisible = true;
            filteredMargins.Remove(fe);
        }
    }

    // ---------------- Логи ----------------

    private void LogSource_Checked(object sender, RoutedEventArgs e)
    {
        if (sender is RadioButton { Tag: string source } && model != null) model.LogSource = source;
    }

    private void ScrollLogsToEnd()
    {
        if (LogsList.Items.Count > 0) LogsList.ScrollIntoView(LogsList.Items[^1]);
    }

    // ---------------- Списки / Редактор ----------------

    private void ListInput_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && model.CanSubmitList)
        {
            model.AddBypass();
            e.Handled = true;
        }
    }

    private void LeaveAlone_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        // commit the binding; the text box keeps focus until the user leaves it
        ((System.Windows.Controls.TextBox)sender).GetBindingExpression(System.Windows.Controls.TextBox.TextProperty)?.UpdateSource();
        e.Handled = true;
    }

    private int gutterLines = -1;

    private void UpdateGutter()
    {
        var lines = Math.Max(1, (model.EditorText ?? "").Count(c => c == '\n') + 1);
        if (lines == gutterLines) return;
        gutterLines = lines;
        Gutter.Text = string.Join("\n", Enumerable.Range(1, lines));
    }

    private void Editor_TextChanged(object sender, TextChangedEventArgs e) => UpdateGutter();

    private void Editor_ScrollChanged(object sender, ScrollChangedEventArgs e) => Canvas.SetTop(Gutter, 8 - e.VerticalOffset);

    private void Editor_SelectionChanged(object sender, RoutedEventArgs e)
    {
        var index = EditorBox.CaretIndex;
        var line = EditorBox.GetLineIndexFromCharacterIndex(index);
        if (line < 0) line = 0;
        var start = EditorBox.GetCharacterIndexFromLineIndex(line);
        model.CaretText = $"Ln {line + 1}, Col {index - Math.Max(0, start) + 1}";
    }

    private void Save()
    {
        if (!model.CanSave) return;
        model.SaveList();
        model.EditorOriginal = model.EditorText;
    }

    private void CancelEdit()
    {
        model.EditorText = model.EditorOriginal;
        model.GoBack();
    }

    private void CancelEdit_Click(object sender, RoutedEventArgs e) => CancelEdit();

    // ---------------- Диагностика ----------------

    private void BuildSkeleton()
    {
        foreach (var width in new[] { 96.0, 84, 52, 70, 76, 60 })
        {
            var row = new DockPanel { Height = 32, Margin = new Thickness(16, 0, 16, 0) };
            var spinner = new ArcSpinner { Margin = new Thickness(2, 0, 12, 0) };
            DockPanel.SetDock(spinner, Dock.Left);
            row.Children.Add(spinner);
            var meta = new Rectangle { Width = 64, Height = 8, RadiusX = 3, RadiusY = 3 };
            meta.SetResourceReference(Shape.FillProperty, "LineBrush");
            DockPanel.SetDock(meta, Dock.Right);
            row.Children.Add(meta);
            var bar = new Rectangle { Width = width, Height = 8, RadiusX = 3, RadiusY = 3, HorizontalAlignment = HorizontalAlignment.Left };
            bar.SetResourceReference(Shape.FillProperty, "Line2Brush");
            row.Children.Add(bar);
            row.Loaded += (_, _) =>
            {
                if (!Motion.Reduce)
                    row.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0.55, TimeSpan.FromSeconds(0.8)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever });
            };
            Skeleton.Children.Add(row);
        }
    }

    /// <summary>Each check starts as a spinner and resolves into its icon, one after another.</summary>
    private void ResolveDiagnostics(bool animate)
    {
        for (var i = 0; i < DiagnosticsList.Items.Count; i++)
        {
            if (DiagnosticsList.ItemContainerGenerator.ContainerFromIndex(i) is not ContentPresenter presenter) continue;
            presenter.ApplyTemplate();
            var spin = presenter.ContentTemplate?.FindName("Spin", presenter) as FrameworkElement;
            var icon = presenter.ContentTemplate?.FindName("Icon", presenter) as FrameworkElement;
            if (spin == null || icon == null) continue;
            if (!animate || Motion.Reduce)
            {
                spin.Visibility = Visibility.Collapsed;
                icon.BeginAnimation(OpacityProperty, null);
                icon.Opacity = 1;
                continue;
            }
            spin.Visibility = Visibility.Visible;
            icon.Opacity = 0;
            var delay = 0.3 + i * 0.12;
            var reveal = Motion.FromTo(0, 1, SpringKind.Snappy, delay);
            reveal.Completed += (_, _) => spin.Visibility = Visibility.Collapsed;
            icon.BeginAnimation(OpacityProperty, reveal);
            spin.BeginAnimation(OpacityProperty, Motion.FromTo(1, 0, SpringKind.Snappy, delay));
            var scale = new ScaleTransform(0.6, 0.6);
            icon.RenderTransformOrigin = new Point(0.5, 0.5);
            icon.RenderTransform = scale;
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, Motion.FromTo(0.6, 1, SpringKind.Snappy, delay));
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, Motion.FromTo(0.6, 1, SpringKind.Snappy, delay));
            presenter.BeginAnimation(OpacityProperty, Motion.FromTo(0, 1, SpringKind.Smooth, Math.Min(i, 14) * Motion.StaggerStep));
        }
    }

    // ---------------- menus ----------------

    private void ShowMenu(Button anchor, ContextMenu menu)
    {
        menu.PlacementTarget = anchor;
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
        menu.HorizontalOffset = anchor.ActualWidth - 220;
        menu.MinWidth = 220;
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

    // ---------------- buttons ----------------

    private void ToggleService_Click(object sender, RoutedEventArgs e) => model.PerformToggle();
    private void ToggleLogin_Click(object sender, RoutedEventArgs e) => model.ToggleLogin();
    private void More_Click(object sender, RoutedEventArgs e) => model.Page = HudPage.More;
    private void Back_Click(object sender, RoutedEventArgs e)
    {
        if (model.Page == HudPage.Editor) CancelEdit();
        else model.GoBack();
    }
    private void Quit_Click(object sender, RoutedEventArgs e) => model.Quit();
    private void DismissNotice_Click(object sender, RoutedEventArgs e) => model.DismissNotice();
    private void TestStrategies_Click(object sender, RoutedEventArgs e) => model.TestStrategies();
    private void ApplyBest_Click(object sender, RoutedEventArgs e) => model.ApplyBest();
    private void TestRow_Click(object sender, RoutedEventArgs e) => model.ApplyTestRow((string)((Button)sender).Tag);
    private void Lists_Click(object sender, RoutedEventArgs e) => model.OpenLists();
    private void ListRow_Click(object sender, RoutedEventArgs e) => model.OpenList((string)((Button)sender).Tag);
    private void SaveList_Click(object sender, RoutedEventArgs e) => Save();
    private void Logs_Click(object sender, RoutedEventArgs e) => model.OpenLogs();
    private void CopyLogs_Click(object sender, RoutedEventArgs e) => model.CopyLogs();
    private void Restart_Click(object sender, RoutedEventArgs e) => model.RestartService();
    private void GitHub_Click(object sender, RoutedEventArgs e) => model.OpenGitHub();
    private void InstallUpdate_Click(object sender, RoutedEventArgs e) => model.InstallUpdate();
    private void FindAndApply_Click(object sender, RoutedEventArgs e) => model.FindAndApply();
    private void UpdateLists_Click(object sender, RoutedEventArgs e) => model.UpdateLists();
    private void Diagnostics_Click(object sender, RoutedEventArgs e) => model.OpenDiagnostics();
    private void CopyDiagnostics_Click(object sender, RoutedEventArgs e) => model.CopyDiagnostics();
    private void ToggleAutoPause_Click(object sender, RoutedEventArgs e) => model.ToggleAutoPause();
    private void AddBypass_Click(object sender, RoutedEventArgs e) => model.AddBypass();
    private void AddExclude_Click(object sender, RoutedEventArgs e) => model.AddExclude();
    private void RemoveUserEntry_Click(object sender, RoutedEventArgs e)
    {
        if (((Button)sender).Tag is UserEntryRow row) model.RemoveUserEntry(row);
    }

    private void UpdateTestBar()
    {
        if (TestBarFill == null) return;
        var width = TestBarFill.ActualWidth;
        if (width <= 0)
        {
            // just made visible: measure first
            if (model.ShowTestBar) Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () => { if (TestBarFill.ActualWidth > 0) UpdateTestBar(); });
            return;
        }
        // scale, not Width: the fill moves without a layout pass per frame
        var target = Math.Max(4 / width, Math.Clamp(model.TestFraction, 0, 1));
        TestBarScale.BeginAnimation(ScaleTransform.ScaleXProperty, Motion.To(target, SpringKind.Smooth));
    }
}

/// <summary>Keywords a row of the Ещё page matches in its search field.</summary>
internal static class Search
{
    public static readonly DependencyProperty KeywordsProperty = DependencyProperty.RegisterAttached(
        "Keywords", typeof(string), typeof(Search), new PropertyMetadata(null));

    public static string? GetKeywords(DependencyObject d) => (string?)d.GetValue(KeywordsProperty);
    public static void SetKeywords(DependencyObject d, string? value) => d.SetValue(KeywordsProperty, value);
}

/// <summary>Palette title with the matched part in primary semibold and the rest secondary.</summary>
internal sealed class HighlightText : TextBlock
{
    public static new readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text), typeof(string), typeof(HighlightText), new PropertyMetadata("", (d, _) => ((HighlightText)d).Build()));
    public static readonly DependencyProperty QueryProperty = DependencyProperty.Register(
        nameof(Query), typeof(string), typeof(HighlightText), new PropertyMetadata("", (d, _) => ((HighlightText)d).Build()));

    public new string Text { get => (string)GetValue(TextProperty); set => SetValue(TextProperty, value); }
    public string Query { get => (string)GetValue(QueryProperty); set => SetValue(QueryProperty, value); }

    public HighlightText() => TextTrimming = TextTrimming.CharacterEllipsis;

    private void Build()
    {
        Inlines.Clear();
        var text = Text ?? "";
        var q = (Query ?? "").Trim();
        var at = q.Length == 0 ? -1 : text.IndexOf(q, StringComparison.CurrentCultureIgnoreCase);
        if (at < 0)
        {
            var run = new Run(text);
            run.SetResourceReference(TextElement.ForegroundProperty, q.Length == 0 ? "T1Brush" : "T2Brush");
            Inlines.Add(run);
            return;
        }
        Add(text[..at], "T2Brush", FontWeights.Normal);
        Add(text.Substring(at, q.Length), "T1Brush", FontWeights.SemiBold);
        Add(text[(at + q.Length)..], "T2Brush", FontWeights.Normal);
    }

    private void Add(string part, string brush, FontWeight weight)
    {
        if (part.Length == 0) return;
        var run = new Run(part) { FontWeight = weight };
        run.SetResourceReference(TextElement.ForegroundProperty, brush);
        Inlines.Add(run);
    }
}

internal sealed class InverseVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

internal sealed class EmptyToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        string.IsNullOrEmpty(value as string) ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>Service health → dot colour (accent ok, amber failing, tertiary otherwise); parameter "text" for the ms value.</summary>
internal sealed class HealthBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        var text = parameter as string == "text";
        var key = value switch
        {
            ServiceHealth.Ok => text ? "T1Brush" : "AccentBrush",
            ServiceHealth.Bad => "WarnBrush",
            _ => "T3Brush",
        };
        return Application.Current.TryFindResource(key) ?? Brushes.Gray;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}
