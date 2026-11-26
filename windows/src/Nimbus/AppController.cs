using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
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
    private DateTime lastVpnProbe = DateTime.MinValue;
    private bool vpnProbing;
    private bool pausedByVpn, startingSmartTest;
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
            RunEngineOperation(() => Engine.Start(SelectedStrategy, SelectedIpset, gameFilterMode: SelectedGameFilter));
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
        model.SelectGameFilter = SelectGameFilter;
        model.ToggleLogin = ToggleLogin;
        model.TestStrategies = TestStrategies;
        model.ApplyBest = () =>
        {
            if (model.TestRows.FirstOrDefault(r => r.IsBest) is { } row) ApplyNamedStrategy(row.Name);
        };
        model.ApplyTestRow = ApplyNamedStrategy;
        model.OpenLists = () => { model.Lists = ListRows(); model.UserEntries = LoadUserEntries(); model.Page = HudPage.Lists; };
        model.OpenList = OpenList;
        model.SaveList = SaveList;
        model.OpenLogs = () => { LoadLogs(); model.Page = HudPage.Logs; };
        model.CopyLogs = () =>
        {
            var visible = model.VisibleLogRows;
            var text = visible.Count == 0 ? model.Logs : string.Join("\n", visible.Select(r => $"{r.Time} {r.Level} {r.Source} {r.Text}"));
            try { Clipboard.SetText(text); ShowNotice("Логи скопированы"); }
            catch (Exception ex) { ShowError(ex.Message); }
        };
        model.RestartService = () => { if (Engine.IsRunning) RunEngineOperation(() => Engine.Start(SelectedStrategy, SelectedIpset, gameFilterMode: SelectedGameFilter)); };
        model.OpenGitHub = () => OpenShell(Updater.RepoUrl);
        model.InstallUpdate = InstallUpdate;
        model.Quit = () => Application.Current.Shutdown();
        model.DismissNotice = () => { noticeTimer.Stop(); model.Notice = ""; };
        model.FindAndApply = FindAndApply;
        model.UpdateLists = UpdateLists;
        model.OpenDiagnostics = OpenDiagnostics;
        model.CopyDiagnostics = CopyDiagnostics;
        model.ToggleAutoPause = ToggleAutoPause;
        model.LeaveAlone = State.Read(Paths.LeaveAlone);
        model.LeaveAloneChanged = SaveLeaveAlone;
        model.AddBypass = () => AddListEntry(exclude: false);
        model.AddExclude = () => AddListEntry(exclude: true);
        model.RemoveUserEntry = RemoveListEntry;
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

    private string SelectedGameFilter => GameFilterModes.Normalize(State.Read(Paths.GameFilterMode));

    private static void InitializeUserData()
    {
        Directory.CreateDirectory(Paths.UserLists);
        Payload.Extract("payload/default-lists/", Paths.UserLists, overwrite: false);
        if (!File.Exists(Paths.SelectedStrategy)) State.Write(Paths.SelectedStrategy, StrategyCatalog.DefaultId);
        if (!File.Exists(Paths.IpsetMode)) State.Write(Paths.IpsetMode, IpsetModes.None);
        if (!File.Exists(Paths.GameFilterMode)) State.Write(Paths.GameFilterMode, GameFilterModes.Off);
        if (!File.Exists(Paths.VpnAutoPause)) State.Write(Paths.VpnAutoPause, "0");
    }

    private void ToggleHud()
    {
        if (hud.IsVisible) hud.HideHud();
        else if (!hud.RecentlyHidden) { RefreshLogin(); ProbeServices(force: true); hud.ShowHud(); }
    }

    private void Refresh()
    {
        var running = Engine.IsRunning;
        var selected = State.Read(Paths.SelectedStrategy);
        model.Running = running;
        model.Busy = busy || testing; // the Mac app holds its privileged "busy" lock for the whole test
        if (!model.Busy) model.SwitchIntent = null;
        model.AppVersion = Updater.CurrentVersion;
        if (running != engineWasRunning || (running && model.EngineStarted == null))
        {
            engineWasRunning = running;
            model.EngineStarted = running ? (EngineStartTime() ?? DateTime.Now) : null;
            if (!running) model.LatencySamples = Array.Empty<double>();
        }
        model.Testing = testing;
        model.Updating = updating;
        model.SelectedStrategyId = selected;
        model.StrategyName = strategies.FirstOrDefault(s => s.Id == selected)?.Name ?? selected;
        model.IpsetMode = SelectedIpset;
        model.GameFilterMode = SelectedGameFilter;
        if (testing || hud.IsVisible) ProbeServices(force: false, running);
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
        if (model.Page == HudPage.Logs) LoadLogs();
        if (model.Page == HudPage.Lists) { model.Lists = ListRows(); model.UserEntries = LoadUserEntries(); }
        model.AutoPauseVpn = State.Read(Paths.VpnAutoPause) == "1";
        RefreshVpn();
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
            model.DiscordMs = null;
            model.YouTubeMs = null;
        }
        UpdateTray();
    }

    private bool engineWasRunning;

    private void UpdateTray() => tray.Update(model.Phase, model.HeroTitle.ToLowerInvariant());

    private static DateTime? EngineStartTime()
    {
        try
        {
            return Process.GetProcessesByName("winws").Select(p => { using (p) return p.StartTime; }).OrderBy(t => t).FirstOrDefault() is { } t && t != default ? t : null;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>nimbus.log (source "nimbus") and engine.log (source "engine") for the Логи page.</summary>
    private void LoadLogs()
    {
        model.Logs = LoadDiagnostics(90);
        var rows = new List<LogLine>();
        foreach (var (file, source) in new[] { (Paths.AppLog, "nimbus"), (Paths.EngineLog, "engine") })
            rows.AddRange(LogParser.Parse(Log.Tail(file, 400), source, rows.Count));
        if (!rows.SequenceEqual(model.LogLines)) model.LogLines = rows;
    }

    private void RefreshLogin()
    {
        Task.Run(() => Autostart.IsEnabled).ContinueWith(t => model.LoginEnabled = t.Result, TaskScheduler.FromCurrentSynchronizationContext());
    }

    private void ProbeServices(bool force, bool? running = null)
    {
        if (!(running ?? Engine.IsRunning))
        {
            model.Discord = ServiceHealth.Off;
            model.YouTube = ServiceHealth.Off;
            return;
        }
        if (!force && (DateTime.UtcNow - lastProbe).TotalSeconds < 12) return;
        lastProbe = DateTime.UtcNow;
        if (model.Discord is ServiceHealth.Off or ServiceHealth.Unknown) model.Discord = ServiceHealth.Checking;
        if (model.YouTube is ServiceHealth.Off or ServiceHealth.Unknown) model.YouTube = ServiceHealth.Checking;
        UpdateTray();
        _ = ProbeOne("https://discord.com/", (ok, ms) =>
        {
            model.Discord = ok ? ServiceHealth.Ok : ServiceHealth.Bad;
            model.DiscordMs = ok ? ms : null;
            model.LastProbe = DateTime.Now;
            UpdateTray();
        });
        _ = ProbeOne("https://www.youtube.com/", (ok, ms) =>
        {
            model.YouTube = ok ? ServiceHealth.Ok : ServiceHealth.Bad;
            model.YouTubeMs = ok ? ms : null;
            model.LastProbe = DateTime.Now;
            // the history chart follows the slower, video side of the bypass
            model.LatencySamples = model.LatencySamples.Append(ok ? ms : double.NaN).TakeLast(40).ToArray();
            UpdateTray();
        });
    }

    private static async Task ProbeOne(string url, Action<bool, int> done)
    {
        var watch = Stopwatch.StartNew();
        var ok = await Net.ProbeAsync(url);
        done(ok, (int)Math.Round(watch.Elapsed.TotalMilliseconds));
    }

    private void ToggleService()
    {
        pausedByVpn = false;
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
                Engine.Start(SelectedStrategy, SelectedIpset, gameFilterMode: SelectedGameFilter);
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

    private void SelectGameFilter(string mode)
    {
        if (testing) return;
        try
        {
            mode = GameFilterModes.Normalize(mode);
            var switchedPreset = false;
            if (GameFilterModes.IsOn(mode) && SelectedIpset == IpsetModes.None)
            {
                State.Write(Paths.IpsetMode, IpsetModes.Loaded);
                switchedPreset = true;
            }
            State.Write(Paths.GameFilterMode, mode);
            Refresh();
            ApplyIfRunning();
            if (switchedPreset)
            {
                ShowNotice("Пресет переключён на «Стандартный»: без списка IP игровой фильтр не сработает.");
            }
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
    }

    private void ApplyIfRunning()
    {
        if (Engine.IsRunning) RunEngineOperation(() => Engine.Start(SelectedStrategy, SelectedIpset, gameFilterMode: SelectedGameFilter));
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

    private void FindAndApply()
    {
        if (busy) return;
        if (testing)
        {
            if (model.TestIsSmart) TestStrategies();
            return;
        }
        model.TestIsSmart = true;
        startingSmartTest = true;
        TestStrategies();
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
        if (!startingSmartTest) model.TestIsSmart = false;
        startingSmartTest = false;
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
        string? autoId = null, autoName = null;
        try
        {
            var ordered = model.TestIsSmart
                ? StrategyOrder.ForSmart(strategies, SelectedStrategy, StrategyOrder.ParseWinners(model.TestBest))
                : strategies;
            var report = await tester.RunAsync(ordered, SelectedStrategy, SelectedIpset, SelectedGameFilter, Engine.IsRunning, testCancel.Token, model.TestIsSmart, model.ExtraHost);
            summary = report.Summary;
            autoId = report.AutoApplyId;
            autoName = report.AutoApplyName;
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
        if (autoId != null)
        {
            SelectStrategy(autoId);
            if (autoName != null) ShowNotice("Стратегия: " + autoName);
        }
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
        model.EditorOriginal = model.EditorText;
        model.CaretText = "Ln 1, Col 1";
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
                    if (wasRunning) Engine.Start(SelectedStrategy, SelectedIpset, gameFilterMode: SelectedGameFilter);
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

    private void RefreshVpn()
    {
        if (vpnProbing || (DateTime.UtcNow - lastVpnProbe).TotalSeconds < 4) return;
        lastVpnProbe = DateTime.UtcNow;
        vpnProbing = true;
        // walking adapters and processes takes tens of ms: keep it off the UI thread so animations don't stall
        Task.Run(() =>
        {
            var snapshot = Tunnels.Capture();
            // new VPN servers and edits to the user's list reach winws through the file it watches
            if (Engine.IsRunning) Tunnels.WriteLeaveAloneFile(snapshot.Endpoints);
            return (Match: SystemDiagnostics.DetectVpn(), Nic: LocalNetwork.Primary(), Snapshot: snapshot);
        }).ContinueWith(t =>
        {
            vpnProbing = false;
            if (t.IsCompletedSuccessfully) ApplyVpn(t.Result.Match, t.Result.Nic.Name, t.Result.Nic.Address, t.Result.Snapshot);
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    private string pendingPlan = "";
    private DateTime lastPlanRestart = DateTime.MinValue;

    /// <summary>
    /// The WinDivert interface filter is fixed when winws starts, so the engine restarts when the physical
    /// interface or the presence of a VPN adapter changes. A change has to hold for two probes to count.
    /// </summary>
    private void FollowNetwork(NetworkSnapshot snapshot)
    {
        var running = Engine.RunningPlan;
        var wanted = snapshot.Plan.Signature;
        if (!Engine.IsRunning || running.Length == 0 || running == wanted) { pendingPlan = ""; return; }
        if (busy || testing || updating || pausedByVpn) return;
        if (pendingPlan != wanted) { pendingPlan = wanted; return; }
        if ((DateTime.UtcNow - lastPlanRestart).TotalSeconds < 15) return;
        pendingPlan = "";
        lastPlanRestart = DateTime.UtcNow;
        Log.Write($"network changed ({running} → {wanted}), restarting the engine");
        RunEngineOperation(() => Engine.Start(SelectedStrategy, SelectedIpset, gameFilterMode: SelectedGameFilter, network: snapshot));
    }

    private void SaveLeaveAlone(string text)
    {
        var parsed = LeaveAlone.Parse(text);
        var normalized = string.Join(", ", parsed.Entries);
        try
        {
            State.Write(Paths.LeaveAlone, normalized);
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
            return;
        }
        if (parsed.Invalid.Count > 0) ShowNotice("Не распознал: " + string.Join(", ", parsed.Invalid.Take(3)), error: true);
        if (normalized != text) model.LeaveAlone = normalized;
        if (Engine.IsRunning) Task.Run(() => Tunnels.WriteLeaveAloneFile(Tunnels.Capture().Endpoints));
    }

    private void ApplyVpn(VpnMatch match, string nicName, string nicAddress, NetworkSnapshot snapshot)
    {
        var fullTunnel = match.IsVpn && VpnSignatures.IsFullTunnelClient(match.Reason);
        // VPN traffic is left alone now, so a VPN is a note, not a warning; only a client that takes over every connection is
        model.VpnWarning = fullTunnel ? (match.Reason ?? "WARP") + " · обход не сработает" : "";
        model.VpnNote = match.IsVpn && !fullTunnel ? (match.Reason ?? "VPN") + " · не трогаем" : "";
        model.NetworkInterface = nicName;
        model.NetworkAddress = nicAddress;
        FollowNetwork(snapshot);
        var auto = model.AutoPauseVpn;
        if (auto && match.IsVpn && Engine.IsRunning && !testing && !busy && !updating)
        {
            pausedByVpn = true;
            RunEngineOperation(() =>
            {
                Engine.Stop();
                State.Write(Paths.EngineEnabled, "0");
            }, failure =>
            {
                if (failure == null) ShowNotice("Nimbus на паузе: активен VPN");
            });
            return;
        }
        if (auto && !match.IsVpn && pausedByVpn && !Engine.IsRunning && !testing && !busy && !updating)
        {
            pausedByVpn = false;
            RunEngineOperation(() =>
            {
                Engine.Start(SelectedStrategy, SelectedIpset, gameFilterMode: SelectedGameFilter);
                State.Write(Paths.EngineEnabled, "1");
            }, failure =>
            {
                if (failure == null) ShowNotice("VPN выключен, Nimbus снова включён");
            });
            return;
        }
        if (!match.IsVpn && Engine.IsRunning) pausedByVpn = false;
    }

    private void ToggleAutoPause()
    {
        var next = State.Read(Paths.VpnAutoPause) != "1";
        State.Write(Paths.VpnAutoPause, next ? "1" : "0");
        if (!next) pausedByVpn = false;
        Refresh();
    }

    private async void UpdateLists()
    {
        if (busy || testing || model.UpdatingLists) return;
        model.UpdatingLists = true;
        try
        {
            var files = await Task.Run(DownloadUpstreamLists);
            var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
            var backup = Path.Combine(Paths.UserLists, "backup-" + stamp);
            ListUpdater.Apply(Paths.UserLists, files, backup);
            ShowNotice($"Списки обновлены ({files.Count})");
            ApplyIfRunning();
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
        model.UpdatingLists = false;
        if (model.Page == HudPage.Lists) { model.Lists = ListRows(); model.UserEntries = LoadUserEntries(); }
    }

    private static IReadOnlyDictionary<string, string> DownloadUpstreamLists()
    {
        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Nimbus");
        var files = new Dictionary<string, string>();
        foreach (var name in ListUpdater.UpstreamFiles)
        {
            var bytes = client.GetByteArrayAsync(ListUpdater.FileUrl(name)).GetAwaiter().GetResult();
            var text = ListUpdater.Decode(bytes);
            var check = ListUpdater.Validate(name, text);
            if (!check.Ok) throw new InvalidOperationException(check.Reason);
            files[name] = text;
        }
        return files;
    }

    private async void OpenDiagnostics()
    {
        model.Page = HudPage.Diagnostics;
        if (model.DiagnosticsRunning) return;
        model.Diagnostics = Array.Empty<DiagnosticViewRow>();
        model.DiagnosticsElapsed = 0;
        model.DiagnosticsRunning = true;
        var watch = Stopwatch.StartNew();
        IReadOnlyList<DiagnosticRow> rows;
        try
        {
            rows = await Task.Run(SystemDiagnostics.Collect);
        }
        catch (Exception ex)
        {
            rows = new[] { new DiagnosticRow("Диагностика", DiagnosticLevel.Fail, ex.Message) };
        }
        model.DiagnosticsElapsed = watch.Elapsed.TotalSeconds;
        model.DiagnosticsRunning = false;
        model.Diagnostics = rows.Select((r, i) => new DiagnosticViewRow(r.LevelText, r.Name, r.Detail, i > 0)).ToList();
        model.DiagnosticText = SystemDiagnostics.Format(rows);
    }

    private void CopyDiagnostics()
    {
        try
        {
            if (model.DiagnosticText.Length == 0) return;
            Clipboard.SetText(model.DiagnosticText);
            ShowNotice("Отчёт скопирован");
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
    }

    private void AddListEntry(bool exclude)
    {
        var parsed = HostEntry.Parse(model.ListInput);
        if (parsed == null)
        {
            ShowError("Не получилось распознать домен или IP");
            return;
        }
        try
        {
            var name = UserLists.FileFor(parsed.Kind, exclude);
            var path = Path.Combine(Paths.UserLists, name);
            Directory.CreateDirectory(Paths.UserLists);
            var current = File.Exists(path) ? File.ReadAllText(path) : "";
            File.WriteAllText(path, UserLists.Add(current, parsed.Value));
            model.ListInput = "";
            model.UserEntries = LoadUserEntries();
            model.Lists = ListRows();
            ShowNotice((exclude ? "Исключено: " : "Добавлено в обход: ") + parsed.Value);
            ApplyIfRunning();
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
    }

    private void RemoveListEntry(UserEntryRow entry)
    {
        try
        {
            var path = Path.Combine(Paths.UserLists, entry.File);
            var current = File.Exists(path) ? File.ReadAllText(path) : "";
            File.WriteAllText(path, UserLists.Remove(current, entry.Value));
            model.UserEntries = LoadUserEntries();
            model.Lists = ListRows();
            ApplyIfRunning();
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
    }

    private static IReadOnlyList<UserEntryRow> LoadUserEntries()
    {
        var rows = new List<UserEntryRow>();
        foreach (var name in new[] { UserLists.BypassDomains, UserLists.BypassIpset, UserLists.ExcludeDomains, UserLists.ExcludeIpset })
        {
            var path = Path.Combine(Paths.UserLists, name);
            if (!File.Exists(path)) continue;
            foreach (var value in UserLists.ReadEntries(File.ReadAllText(path)))
            {
                rows.Add(new UserEntryRow(name, value));
            }
        }
        return rows;
    }

        public void Shutdown()
    {
        testCancel?.Cancel();
        tray.Dispose();
    }
}
