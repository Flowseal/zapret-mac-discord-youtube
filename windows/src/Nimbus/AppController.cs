using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Nimbus.Core;

namespace Nimbus;

/// <summary>WPF counterpart of AppDelegate in macos/App/ZapretMacApp.swift.</summary>
internal sealed class AppController
{
    private readonly HudModel model = new();
    private readonly DispatcherTimer refreshTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly DispatcherTimer updateTimer = new() { Interval = TimeSpan.FromHours(1) };
    private readonly DispatcherTimer noticeTimer = new() { Interval = TimeSpan.FromSeconds(3.2) };
    private HudWindow hud = null!;
    private TrayIcon tray = null!;
    private IReadOnlyList<Strategy> strategies = Array.Empty<Strategy>();
    private bool busy, testing, checkingForUpdate, updating;
    private ReleaseInfo? availableRelease;
    private CancellationTokenSource? testCancel;
    private DateTime lastProbe = DateTime.MinValue;
    private readonly List<TestRow> liveRows = new();

    public void Start(bool showOnLaunch)
    {
        InitializeUserData();
        strategies = StrategyCatalog.Parse(Payload.ReadText("payload/strategies.tsv"));
        model.Strategies = strategies;
        Updater.CleanupOldBinary();

        hud = new HudWindow(model);
        tray = new TrayIcon();
        tray.Clicked += ToggleHud;
        Wire();
        Theme.Watch(() => Application.Current.Dispatcher.BeginInvoke(() =>
        {
            Theme.Apply(Application.Current.Resources);
            hud.RefreshThemeBrushes();
            tray.RebuildForTheme();
        }));

        Refresh();
        RefreshLogin();
        refreshTimer.Tick += (_, _) => Refresh();
        refreshTimer.Start();
        updateTimer.Tick += (_, _) => CheckForUpdate();
        updateTimer.Start();
        noticeTimer.Tick += (_, _) => { noticeTimer.Stop(); model.Notice = ""; };
        CheckForUpdate();
        ShowPendingUpdateError();

        if (Autostart.IsEnabled)
        {
            // keep the logon task pointing at this exe if it was moved
            Task.Run(() => { try { Autostart.Enable(); } catch (Exception ex) { Log.Write("autostart refresh: " + ex.Message); } });
        }

        // Resume after reboot/update, like the Mac LaunchDaemon that keeps running without the app
        if (State.Read(Paths.EngineEnabled) == "1" && !Engine.IsRunning)
        {
            RunEngineOperation(() => Engine.Start(SelectedStrategy, SelectedIpset));
        }
        if (showOnLaunch) hud.ShowHud();
    }

    public void ShowFromSecondInstance()
    {
        RefreshLogin();
        hud.ShowHud();
    }

    private void Wire()
    {
        model.ToggleService = ToggleService;
        model.SelectStrategy = SelectStrategy;
        model.SelectIpset = SelectIpset;
        model.ToggleLogin = ToggleLogin;
        model.TestStrategies = TestStrategies;
        model.ApplyBest = () =>
        {
            if (model.TestRows.FirstOrDefault(r => r.IsBest) is { } row) ApplyNamedStrategy(row.Name);
        };
        model.ApplyTestRow = ApplyNamedStrategy;
        model.OpenLists = () => { model.Lists = ListRows(); model.Page = HudPage.Lists; };
        model.OpenList = OpenList;
        model.SaveList = SaveList;
        model.OpenLogs = () => { model.Logs = LoadDiagnostics(90); model.Page = HudPage.Logs; };
        model.CopyLogs = () =>
        {
            try { Clipboard.SetText(model.Logs); ShowNotice("Логи скопированы"); }
            catch (Exception ex) { ShowError(ex.Message); }
        };
        model.RestartService = () => { if (Engine.IsRunning) RunEngineOperation(() => Engine.Start(SelectedStrategy, SelectedIpset)); };
        model.OpenGitHub = () => OpenShell(Updater.RepoUrl);
        model.InstallUpdate = InstallUpdate;
        model.Quit = () => Application.Current.Shutdown();
        model.DismissNotice = () => { noticeTimer.Stop(); model.Notice = ""; };
    }

    private string SelectedStrategy
    {
        get
        {
            var id = State.Read(Paths.SelectedStrategy);
            return StrategyCatalog.IsValidId(id) ? id : StrategyCatalog.DefaultId;
        }
    }

    private string SelectedIpset => IpsetModes.Normalize(State.Read(Paths.IpsetMode));

    private static void InitializeUserData()
    {
        Directory.CreateDirectory(Paths.UserLists);
        Payload.Extract("payload/default-lists/", Paths.UserLists, overwrite: false);
        if (!File.Exists(Paths.SelectedStrategy)) State.Write(Paths.SelectedStrategy, StrategyCatalog.DefaultId);
        if (!File.Exists(Paths.IpsetMode)) State.Write(Paths.IpsetMode, IpsetModes.None);
    }

    private void ToggleHud()
    {
        if (hud.IsVisible) hud.HideHud();
        else if (!hud.RecentlyHidden) { RefreshLogin(); ProbeServices(force: true); hud.ShowHud(); }
    }

    private void Refresh()
    {
        var running = Engine.IsRunning;
        tray.Update(running);
        var selected = State.Read(Paths.SelectedStrategy);
        model.Running = running;
        model.Busy = busy || testing; // the Mac app holds its privileged "busy" lock for the whole test
        model.Testing = testing;
        model.Updating = updating;
        model.SelectedStrategyId = selected;
        model.StrategyName = strategies.FirstOrDefault(s => s.Id == selected)?.Name ?? selected;
        model.IpsetMode = SelectedIpset;
        if (testing || hud.IsVisible) ProbeServices(force: false);
        model.ApplyBestEnabled = !testing && !busy && model.TestRows.Any(r => r.IsBest);
        if (testing)
        {
            model.TestTitle = model.CancellingTest ? "Остановка теста…" : model.TestProgress.Length == 0 ? "Остановить тест" : "Остановить";
            model.TestEnabled = !model.CancellingTest;
        }
        else
        {
            model.TestTitle = model.TestRows.Count == 0 ? "Тест стратегий" : "Повторить тест";
            model.TestEnabled = !busy;
        }
        if (model.Page == HudPage.Logs) model.Logs = LoadDiagnostics(90);
        if (updating)
        {
            model.VersionTitle = "Установка обновления…";
            model.CanInstallUpdate = false;
        }
        else if (availableRelease != null)
        {
            model.VersionTitle = $"Обновить до {Versioning.Display(availableRelease.Tag)}";
            model.CanInstallUpdate = !busy && !testing;
        }
        else
        {
            model.VersionTitle = $"Версия {Updater.CurrentVersion}";
            model.CanInstallUpdate = false;
        }
        if (!running)
        {
            model.Discord = ServiceHealth.Off;
            model.YouTube = ServiceHealth.Off;
        }
    }

    private void RefreshLogin()
    {
        Task.Run(() => Autostart.IsEnabled).ContinueWith(t => model.LoginEnabled = t.Result, TaskScheduler.FromCurrentSynchronizationContext());
    }

    private void ProbeServices(bool force)
    {
        if (!Engine.IsRunning)
        {
            model.Discord = ServiceHealth.Off;
            model.YouTube = ServiceHealth.Off;
            return;
        }
        if (!force && (DateTime.UtcNow - lastProbe).TotalSeconds < 12) return;
        lastProbe = DateTime.UtcNow;
        if (model.Discord is ServiceHealth.Off or ServiceHealth.Unknown) model.Discord = ServiceHealth.Checking;
        if (model.YouTube is ServiceHealth.Off or ServiceHealth.Unknown) model.YouTube = ServiceHealth.Checking;
        _ = ProbeOne("https://discord.com/", ok => model.Discord = ok ? ServiceHealth.Ok : ServiceHealth.Bad);
        _ = ProbeOne("https://www.youtube.com/", ok => model.YouTube = ok ? ServiceHealth.Ok : ServiceHealth.Bad);
    }

    private static async Task ProbeOne(string url, Action<bool> done)
    {
        var ok = await Net.ProbeAsync(url);
        done(ok);
    }

    private void ToggleService()
    {
        if (Engine.IsRunning)
        {
            RunEngineOperation(() =>
            {
                Engine.Stop();
                State.Write(Paths.EngineEnabled, "0");
            });
        }
        else
        {
            RunEngineOperation(() =>
            {
                Engine.Start(SelectedStrategy, SelectedIpset);
                State.Write(Paths.EngineEnabled, "1");
            });
        }
    }

    private void SelectStrategy(string id)
    {
        if (testing) return;
        try
        {
            State.Write(Paths.SelectedStrategy, id);
            Refresh();
            ApplyIfRunning();
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
    }

    private void SelectIpset(string mode)
    {
        if (testing) return;
        try
        {
            State.Write(Paths.IpsetMode, mode);
            Refresh();
            ApplyIfRunning();
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
    }

    private void ApplyIfRunning()
    {
        if (Engine.IsRunning) RunEngineOperation(() => Engine.Start(SelectedStrategy, SelectedIpset));
    }

    private void ToggleLogin()
    {
        var enable = !model.LoginEnabled;
        Task.Run(() =>
        {
            if (enable) Autostart.Enable();
            else Autostart.Disable();
        }).ContinueWith(t =>
        {
            if (t.Exception != null) ShowError("Не удалось изменить автозапуск: " + t.Exception.GetBaseException().Message);
            RefreshLogin();
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    private void RunEngineOperation(Action operation, Action<string?>? completion = null)
    {
        if (busy || testing) return;
        busy = true;
        Refresh();
        Task.Run(operation).ContinueWith(t =>
        {
            busy = false;
            string? failure = null;
            if (t.Exception != null)
            {
                failure = t.Exception.GetBaseException().Message;
                Log.Write("operation failed: " + failure);
                ShowError(failure);
            }
            lastProbe = DateTime.MinValue;
            Refresh();
            completion?.Invoke(failure);
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    private void ApplyNamedStrategy(string name)
    {
        var strategy = strategies.FirstOrDefault(s => s.Name == name);
        if (strategy == null)
        {
            ShowError($"Не нашёл стратегию {name}");
            return;
        }
        SelectStrategy(strategy.Id);
        ShowNotice($"Стратегия: {name}");
    }

    private async void TestStrategies()
    {
        if (busy) return;
        if (testing)
        {
            model.CancellingTest = true;
            testCancel?.Cancel();
            Refresh();
            return;
        }
        testing = true;
        model.CancellingTest = false;
        liveRows.Clear();
        model.TestRows = Array.Empty<TestRow>();
        model.TestBest = "";
        model.TestProgress = "Подготовка";
        model.Page = HudPage.More;
        Refresh();
        if (!hud.IsVisible) hud.ShowHud();

        testCancel = new CancellationTokenSource();
        var tester = new StrategyTester();
        var dispatcher = Application.Current.Dispatcher;
        tester.Progress += text => dispatcher.BeginInvoke(() => { model.TestProgress = text; Refresh(); });
        tester.Result += result => dispatcher.BeginInvoke(() =>
        {
            liveRows.Add(new TestRow(result.Name, result.ScoreText, false));
            model.TestRows = liveRows.ToList();
        });
        string summary;
        try
        {
            summary = await tester.RunAsync(strategies, SelectedStrategy, SelectedIpset, Engine.IsRunning, testCancel.Token);
        }
        catch (Exception ex)
        {
            summary = "";
            ShowError(ex.Message);
        }
        await dispatcher.InvokeAsync(() => { }, DispatcherPriority.Background); // flush queued rows
        testing = false;
        model.CancellingTest = false;
        model.TestProgress = "";
        model.TestBest = summary;
        model.TestRows = liveRows.Select(r => r with { IsBest = BestTracker.IsBestInSummary(summary, r.Name) }).ToList();
        model.Page = HudPage.More;
        lastProbe = DateTime.MinValue;
        Refresh();
        if (!hud.IsVisible) hud.ShowHud();
    }

    private IReadOnlyList<ListRow> ListRows()
    {
        var rows = new List<ListRow>();
        foreach (var name in ListCatalog.Names)
        {
            var path = Path.Combine(Paths.UserLists, name);
            if (!File.Exists(path)) continue;
            var size = new FileInfo(path).Length;
            var text = size > 5_000_000 ? "" : File.ReadAllText(path);
            rows.Add(new ListRow(ListCatalog.Describe(name, size, text), rows.Count > 0));
        }
        return rows;
    }

    private void OpenList(string name)
    {
        var path = Path.Combine(Paths.UserLists, name);
        if (!ListCatalog.Names.Contains(name) || !File.Exists(path)) return;
        if (new FileInfo(path).Length > ListCatalog.ExternalThreshold)
        {
            OpenShell("notepad.exe", path);
            return;
        }
        model.EditorName = name;
        model.EditorTitle = ListCatalog.Title(name);
        model.EditorText = File.ReadAllText(path);
        model.Page = HudPage.Editor;
    }

    private void SaveList()
    {
        var name = model.EditorName;
        if (name.Length == 0 || !ListCatalog.Names.Contains(name)) return;
        try
        {
            File.WriteAllText(Path.Combine(Paths.UserLists, name), ListCatalog.NormalizeForSave(model.EditorText));
            ShowNotice("Сохранено");
            ApplyIfRunning();
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
    }

    private static string LoadDiagnostics(int limit)
    {
        var chunks = new List<string>();
        foreach (var file in new[] { Paths.AppLog, Paths.EngineLog })
        {
            var tail = Log.Tail(file, limit);
            if (tail.Length > 0) chunks.Add($"— {Path.GetFileName(file)} —\n{tail}");
        }
        return string.Join("\n\n", chunks);
    }

    private async void CheckForUpdate()
    {
        if (checkingForUpdate || updating) return;
        checkingForUpdate = true;
        try
        {
            availableRelease = await Updater.CheckAsync();
        }
        catch (Exception ex)
        {
            Log.Write("update check: " + ex.Message); // keep the previous result, like the Mac app
        }
        checkingForUpdate = false;
        Refresh();
    }

    private async void InstallUpdate()
    {
        if (availableRelease is not { } release || updating) return;
        updating = true;
        Refresh();
        try
        {
            var wasRunning = Engine.IsRunning;
            if (wasRunning)
            {
                // the new exe extracts its own winws; it restarts the engine on launch (engine-enabled=1)
                State.Write(Paths.EngineEnabled, "1");
            }
            await Task.Run(async () =>
            {
                if (wasRunning) Engine.Stop();
                try
                {
                    await Updater.InstallAsync(release);
                }
                catch
                {
                    if (wasRunning) Engine.Start(SelectedStrategy, SelectedIpset);
                    throw;
                }
            });
            Application.Current.Shutdown();
        }
        catch (Exception ex)
        {
            updating = false;
            Log.Write("update: " + ex.Message);
            Refresh();
            ShowError(ex.Message);
        }
    }

    private void ShowPendingUpdateError()
    {
        var message = State.Read(Paths.UpdateError);
        if (message.Length == 0) return;
        try { File.Delete(Paths.UpdateError); } catch { }
        ShowError(message);
    }

    private void ShowNotice(string message, bool error = false)
    {
        model.Notice = message;
        model.NoticeError = error;
        noticeTimer.Stop();
        if (!error) noticeTimer.Start();
    }

    private void ShowError(string message)
    {
        var compact = string.Join("\n", message.Replace("\r\n", "\n").Split('\n').Take(6));
        ShowNotice(compact, error: true);
        if (!hud.IsVisible) hud.ShowHud();
    }

    private void OpenShell(string target, string? argument = null)
    {
        try
        {
            var psi = new ProcessStartInfo(target) { UseShellExecute = true };
            if (argument != null) psi.ArgumentList.Add(argument);
            Process.Start(psi)?.Dispose();
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
    }

    public void Shutdown()
    {
        testCancel?.Cancel();
        tray.Dispose();
    }
}
