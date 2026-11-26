using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using Nimbus.Core;

namespace Nimbus;

internal enum ServiceHealth { Off, Unknown, Checking, Ok, Bad }

internal enum HudPage { Main, More, Logs, Lists, Editor, Diagnostics }

internal sealed record TestRow(string Name, string Score, bool IsBest);

internal sealed record ListRow(ListInfo Info, bool ShowSeparator)
{
    public string Glyph => Info.External ? "\uE8A7" : "\uE8A5";
    public bool HasBadge => Info.Badge.Length > 0;
    public string CountText => LogParser.GroupThousands(Info.Lines);
    public string Tooltip => $"{ListCatalog.Title(Info.Id)} · {Info.Detail}";
}

internal sealed record UserEntryRow(string File, string Value)
{
    public string Badge => File is UserLists.BypassDomains or UserLists.BypassIpset ? "обход" : "исключение";
    public bool IsBypass => Badge == "обход";
}

internal sealed record DiagnosticViewRow(string Level, string Name, string Detail, bool ShowSeparator)
{
    public bool IsFail => Level == "FAIL";
    public bool IsWarn => Level == "WARN";
    public bool IsOk => !IsFail && !IsWarn;
    public string Glyph => IsFail ? "\uEA39" : IsWarn ? "\uE7BA" : "\uE73E";
    public string Value => Split().Value;
    public string More => Split().More;
    public bool HasMore => More.Length > 0;

    private (string Value, string More) Split()
    {
        var parts = Detail.Replace("\r\n", "\n").Split('\n', 2);
        var first = parts[0].Trim();
        var rest = parts.Length > 1 ? parts[1].Replace('\n', ' ').Trim() : "";
        if (rest.Length == 0 && !IsOk && first.Length > 34) return ("", first);
        return (first, rest);
    }
}

internal sealed record LogRow(LogLine Line)
{
    public string Time => Line.Time;
    public string Level => Line.Level;
    public string Source => Line.Source;
    public string Text => Line.Text;
    public bool IsWarn => Line.Level == "WRN";
    public bool IsErr => Line.Level == "ERR";
}

internal sealed class PaletteItem
{
    public PaletteItem(string id, string group, string glyph, string title, string keys, Action run, bool isChecked = false, bool enabled = true)
    {
        Id = id;
        Group = group;
        Glyph = glyph;
        Title = title;
        Keys = keys;
        Run = run;
        IsChecked = isChecked;
        Enabled = enabled;
    }

    public string Id { get; }
    public string Group { get; }
    public string Glyph { get; }
    public string Title { get; }
    public string Keys { get; }
    public Action Run { get; }
    public bool IsChecked { get; }
    public bool Enabled { get; }
    public bool ShowGroup { get; set; }
    public bool Selected { get; set; }
    public bool HasKeys => Keys.Length > 0 && !IsChecked;
    public string[] KeyCaps => Keys.Split(' ', StringSplitOptions.RemoveEmptyEntries);
}

/// <summary>Mirror of HUDModel in macos/App/NimbusHUD.swift.</summary>
internal sealed class HudModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    private bool running, busy, testing, cancellingTest, updating, loginEnabled, canInstallUpdate, testEnabled = true, applyBestEnabled, noticeError, autoPauseVpn, updatingLists, testIsSmart;
    private string strategyName = "—", selectedStrategyId = "", ipsetMode = "none", gameFilterMode = "off", versionTitle = "Версия", testTitle = "Тест стратегий";
    private string testProgress = "", testBest = "", logs = "", editorName = "", editorTitle = "", editorText = "", notice = "", vpnWarning = "", vpnNote = "", leaveAlone = "", listInput = "", extraHost = "", diagnosticText = "";
    private HudPage page = HudPage.Main;
    private ServiceHealth discord = ServiceHealth.Unknown, youtube = ServiceHealth.Unknown;
    private IReadOnlyList<TestRow> testRows = Array.Empty<TestRow>();
    private IReadOnlyList<ListRow> lists = Array.Empty<ListRow>();
    private IReadOnlyList<UserEntryRow> userEntries = Array.Empty<UserEntryRow>();
    private IReadOnlyList<DiagnosticViewRow> diagnostics = Array.Empty<DiagnosticViewRow>();
    private int? discordMs, youTubeMs;
    private IReadOnlyList<double> latencySamples = Array.Empty<double>();
    private DateTime? lastProbe, engineStarted;
    private string networkInterface = "", networkAddress = "", appVersion = "", logSource = "all", logQuery = "", editorOriginal = "", moreQuery = "", paletteQuery = "", caretText = "Ln 1, Col 1";
    private IReadOnlyList<LogLine> logLines = Array.Empty<LogLine>();
    private bool diagnosticsRunning, paletteOpen;
    private double diagnosticsElapsed;
    private bool? switchIntent;
    private int paletteIndex;

    public IReadOnlyList<Strategy> Strategies { get; set; } = Array.Empty<Strategy>();

    public bool Running { get => running; set { if (Set(ref running, value)) Raise(nameof(StatusTitle), nameof(ShowRestart)); } }
    public bool Busy { get => busy; set { if (Set(ref busy, value)) Raise(nameof(NotBusy), nameof(CanRestart), nameof(CanApplyRow), nameof(CanSubmitList), nameof(CanUpdateLists), nameof(FindEnabled), nameof(FullTestEnabled)); } }
    public bool NotBusy => !busy;
    public bool Testing { get => testing; set { if (Set(ref testing, value)) Raise(nameof(HasTestPanel), nameof(CanApplyRow), nameof(FindTitle), nameof(FindEnabled), nameof(FullTestEnabled), nameof(CanUpdateLists), nameof(ShowTestBar)); } }
    public bool CancellingTest { get => cancellingTest; set { if (Set(ref cancellingTest, value)) Raise(nameof(FindTitle)); } }
    public bool Updating { get => updating; set { if (Set(ref updating, value)) Raise(nameof(ShowUpdateRow), nameof(UpdateRowTitle), nameof(UpdateRowEnabled)); } }
    public string StrategyName { get => strategyName; set => Set(ref strategyName, value); }
    public string SelectedStrategyId { get => selectedStrategyId; set => Set(ref selectedStrategyId, value); }
    public string IpsetMode { get => ipsetMode; set { if (Set(ref ipsetMode, value)) Raise(nameof(IpsetTitle)); } }
    public string GameFilterMode { get => gameFilterMode; set { if (Set(ref gameFilterMode, value)) Raise(nameof(GameFilterTitle)); } }
    public bool LoginEnabled { get => loginEnabled; set => Set(ref loginEnabled, value); }
    public string VersionTitle { get => versionTitle; set { if (Set(ref versionTitle, value)) Raise(nameof(UpdateRowTitle), nameof(FooterVersion)); } }
    public bool CanInstallUpdate { get => canInstallUpdate; set { if (Set(ref canInstallUpdate, value)) Raise(nameof(ShowUpdateRow), nameof(UpdateRowEnabled), nameof(FooterVersion)); } }
    public HudPage Page
    {
        get => page;
        set
        {
            if (Set(ref page, value))
                Raise(nameof(IsMain), nameof(IsMore), nameof(IsLogs), nameof(IsLists), nameof(IsEditor), nameof(IsDiagnostics));
        }
    }
    public string TestTitle { get => testTitle; set => Set(ref testTitle, value); }
    public bool TestEnabled { get => testEnabled; set => Set(ref testEnabled, value); }
    public string TestProgress { get => testProgress; set { if (Set(ref testProgress, value)) Raise(nameof(HasTestProgress), nameof(LiveTestText), nameof(HasTestPanel), nameof(TestFraction), nameof(ShowTestBar)); } }
    public IReadOnlyList<TestRow> TestRows { get => testRows; set { if (Set(ref testRows, value)) Raise(nameof(HasTestRows), nameof(HasTestPanel), nameof(ApplyBestTitle)); } }
    public string TestBest { get => testBest; set { if (Set(ref testBest, value)) Raise(nameof(HasTestBest), nameof(HasTestPanel)); } }
    public bool ApplyBestEnabled { get => applyBestEnabled; set => Set(ref applyBestEnabled, value); }
    public ServiceHealth Discord { get => discord; set => Set(ref discord, value); }
    public ServiceHealth YouTube { get => youtube; set => Set(ref youtube, value); }
    public string Logs { get => logs; set { if (Set(ref logs, value)) Raise(nameof(LogsText), nameof(HasLogs)); } }
    public IReadOnlyList<ListRow> Lists { get => lists; set => Set(ref lists, value); }
    public string EditorName { get => editorName; set => Set(ref editorName, value); }
    public string EditorTitle { get => editorTitle; set => Set(ref editorTitle, value); }
    public string EditorText { get => editorText; set => Set(ref editorText, value); }
    public string Notice { get => notice; set { if (Set(ref notice, value)) Raise(nameof(HasNotice)); } }
    public bool NoticeError { get => noticeError; set { if (Set(ref noticeError, value)) Raise(nameof(NoticeGlyph)); } }
    public string VpnWarning { get => vpnWarning; set { if (Set(ref vpnWarning, value)) Raise(nameof(HasVpnWarning)); } }
    /// <summary>Neutral VPN line ("WireGuard · не трогаем"): VPN traffic is left alone, so it is no warning.</summary>
    public string VpnNote { get => vpnNote; set => Set(ref vpnNote, value); }
    public bool AutoPauseVpn { get => autoPauseVpn; set => Set(ref autoPauseVpn, value); }
    /// <summary>"Не трогать адреса": committed when the field loses focus.</summary>
    public string LeaveAlone { get => leaveAlone; set { if (Set(ref leaveAlone, value)) LeaveAloneChanged(value); } }
    public string ListInput { get => listInput; set { if (Set(ref listInput, value)) Raise(nameof(CanSubmitList)); } }
    public string ExtraHost { get => extraHost; set => Set(ref extraHost, value); }
    public IReadOnlyList<UserEntryRow> UserEntries { get => userEntries; set { if (Set(ref userEntries, value)) Raise(nameof(HasUserEntries)); } }
    public IReadOnlyList<DiagnosticViewRow> Diagnostics { get => diagnostics; set => Set(ref diagnostics, value); }
    public string DiagnosticText { get => diagnosticText; set { if (Set(ref diagnosticText, value)) Raise(nameof(HasDiagnosticText)); } }
    public bool UpdatingLists { get => updatingLists; set { if (Set(ref updatingLists, value)) Raise(nameof(UpdateListsTitle), nameof(CanUpdateLists)); } }
    public bool TestIsSmart { get => testIsSmart; set { if (Set(ref testIsSmart, value)) Raise(nameof(FindTitle), nameof(FindEnabled), nameof(FullTestEnabled)); } }
    public int? DiscordMs { get => discordMs; set => Set(ref discordMs, value); }
    public int? YouTubeMs { get => youTubeMs; set => Set(ref youTubeMs, value); }
    public IReadOnlyList<double> LatencySamples { get => latencySamples; set => Set(ref latencySamples, value); }
    public DateTime? LastProbe { get => lastProbe; set => Set(ref lastProbe, value); }
    public DateTime? EngineStarted { get => engineStarted; set => Set(ref engineStarted, value); }
    public string NetworkInterface { get => networkInterface; set => Set(ref networkInterface, value); }
    public string NetworkAddress { get => networkAddress; set => Set(ref networkAddress, value); }
    public string AppVersion { get => appVersion; set => Set(ref appVersion, value); }
    public IReadOnlyList<LogLine> LogLines { get => logLines; set => Set(ref logLines, value); }
    public string LogSource { get => logSource; set => Set(ref logSource, value); }
    public string LogQuery { get => logQuery; set => Set(ref logQuery, value); }
    public string EditorOriginal { get => editorOriginal; set => Set(ref editorOriginal, value); }
    public string CaretText { get => caretText; set => Set(ref caretText, value); }
    public bool DiagnosticsRunning { get => diagnosticsRunning; set => Set(ref diagnosticsRunning, value); }
    public double DiagnosticsElapsed { get => diagnosticsElapsed; set => Set(ref diagnosticsElapsed, value); }
    public bool? SwitchIntent { get => switchIntent; set => Set(ref switchIntent, value); }
    public string MoreQuery { get => moreQuery; set => Set(ref moreQuery, value); }
    public bool PaletteOpen { get => paletteOpen; set => Set(ref paletteOpen, value); }
    public string PaletteQuery { get => paletteQuery; set { if (Set(ref paletteQuery, value)) PaletteIndex = 0; } }
    public int PaletteIndex { get => paletteIndex; set => Set(ref paletteIndex, value); }

    // ---- derived state ----
    public MarkState Phase => PanelPhase.Resolve(running, busy, switchIntent, testing,
        discord == ServiceHealth.Bad || youtube == ServiceHealth.Bad,
        discord == ServiceHealth.Checking || youtube == ServiceHealth.Checking);
    public bool SwitchOn => switchIntent ?? running;
    public bool IsProblem => Phase == MarkState.Problem;
    public bool IsOff => Phase == MarkState.Off;
    private string[] FailingServices => new[] { discord == ServiceHealth.Bad ? "Discord" : null, youtube == ServiceHealth.Bad ? "YouTube" : null }.OfType<string>().ToArray();
    public string HeroTitle => Phase switch
    {
        MarkState.Off => "Обход выключен",
        MarkState.Checking => testing ? (testIsSmart ? "Подбор стратегии…" : "Тест стратегий…") : running ? "Проверка сервисов…" : "Подключение…",
        MarkState.On => "Обход активен",
        _ => FailingServices.Length == 1 ? $"{FailingServices[0]} недоступен" : "Сервисы недоступны",
    };
    public string HeroSubtitle => Phase switch
    {
        MarkState.Off => "Ctrl+Enter — включить",
        MarkState.Checking => testing && testProgress.Length > 0 ? testProgress : $"{strategyName} · проверка сервисов",
        MarkState.On => $"{strategyName} · ipset {IpsetTitle.ToLowerInvariant()}",
        _ => $"{strategyName} · {(youtube == ServiceHealth.Bad ? "youtube.com" : "discord.com")} timeout",
    };
    public string UptimeText => running && engineStarted is { } start ? EngineClock.Format(DateTime.Now - start) : "—";
    public string LatencySummary => running ? LatencyStats.Summary(latencySamples) : "нет данных";
    public IReadOnlyList<double> ChartSamples => running ? latencySamples : Array.Empty<double>();
    public string ProbeSince => discord == ServiceHealth.Checking || youtube == ServiceHealth.Checking ? "проверка…" : lastProbe is { } at && running ? EngineClock.Since(DateTime.Now - at) : "";
    public string DiscordValue => ServiceValue(discord, discordMs);
    public string YouTubeValue => ServiceValue(youtube, youTubeMs);
    public bool DiscordOk => discord == ServiceHealth.Ok;
    public bool YouTubeOk => youtube == ServiceHealth.Ok;
    public string NetworkLabel => string.Join(" · ", new[] { networkInterface, networkAddress }.Where(x => x.Length > 0)) is { Length: > 0 } n ? n : "—";
    public string VpnLabel => vpnWarning.Length > 0 ? vpnWarning : vpnNote.Length > 0 ? vpnNote : "не обнаружен";
    public string FooterStatusText => Phase switch
    {
        MarkState.Off => "Не активен",
        MarkState.Checking => testing ? "Идёт тест…" : "Проверка…",
        MarkState.On => "Все сервисы доступны",
        _ => string.Join(" · ", FailingServices.Select(x => x + ": timeout")),
    };
    public string FooterStatusBrush => Phase switch { MarkState.On => "AccentBrush", MarkState.Problem => "WarnBrush", _ => "T3Brush" };
    public bool FooterPulsing => Phase == MarkState.Checking;
    public bool ShowFindFooter => Phase == MarkState.Problem && FindEnabled;
    public string FooterVersionLine => $"{(appVersion.Length > 0 ? appVersion : versionTitle)} · Flowseal · bol-van/zapret";
    public string StrategyCountText => $"{Strategies.Count} стратегий";
    public string ListsCountText => lists.Count.ToString(System.Globalization.CultureInfo.InvariantCulture);
    public bool DiagnosticsHaveFail => diagnostics.Any(d => d.IsFail);
    public bool DiagnosticsHaveWarn => !DiagnosticsHaveFail && (diagnostics.Any(d => d.IsWarn) || vpnWarning.Length > 0);
    public IReadOnlyList<LogRow> VisibleLogRows => logLines
        .Where(l => (logSource == "all" || l.Source == logSource) && LogParser.Matches(l, logQuery))
        .Select(l => new LogRow(l)).ToList();
    public string LogCountText => $"{LogParser.GroupThousands(VisibleLogRows.Count)} строк";
    public bool LogsEmpty => VisibleLogRows.Count == 0;
    public string LogsEmptyText => logLines.Count == 0 ? "Лог пуст" : "Нет совпадений";
    public bool ShowLogHint => logQuery.Length == 0;
    public string ListsTotalText => $"{LogParser.GroupThousands(lists.Sum(l => (long)l.Info.Lines))} записей";
    public string UserEntriesCountText => userEntries.Count.ToString(System.Globalization.CultureInfo.InvariantCulture);
    public bool EditorDirty => editorText != editorOriginal;
    public string EditorHeader => editorName.Length > 0 ? editorName : editorTitle;
    public bool CanSave => !busy && EditorDirty;
    public int OkCount => diagnostics.Count(d => d.IsOk);
    public int WarnCount => diagnostics.Count(d => d.IsWarn);
    public int FailCount => diagnostics.Count(d => d.IsFail);
    public string OkCountText => diagnosticsRunning && diagnostics.Count == 0 ? "–" : OkCount.ToString(System.Globalization.CultureInfo.InvariantCulture);
    public string WarnCountText => diagnosticsRunning && diagnostics.Count == 0 ? "–" : WarnCount.ToString(System.Globalization.CultureInfo.InvariantCulture);
    public string FailCountText => diagnosticsRunning && diagnostics.Count == 0 ? "–" : FailCount.ToString(System.Globalization.CultureInfo.InvariantCulture);
    public string DiagnosticsElapsedText => diagnosticsElapsed > 0 ? diagnosticsElapsed.ToString("0.00 s", System.Globalization.CultureInfo.InvariantCulture) : "";
    public bool ShowSkeleton => diagnosticsRunning && diagnostics.Count == 0;
    public bool NotDiagnosticsRunning => !diagnosticsRunning;
    public string SystemSummary => $"Windows {Environment.OSVersion.Version.Major}.{Environment.OSVersion.Version.Build} · {System.Runtime.InteropServices.RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant()}";

    private static string ServiceValue(ServiceHealth health, int? ms) => health switch
    {
        ServiceHealth.Ok => ms is { } v ? v.ToString(System.Globalization.CultureInfo.InvariantCulture) : "—",
        ServiceHealth.Bad => "timeout",
        ServiceHealth.Checking => "— ms",
        _ => "—",
    };

    /// <summary>Called once a second so the uptime and "checked N s ago" labels tick.</summary>
    public void Tick() => Raise(nameof(UptimeText), nameof(ProbeSince));

    public void PerformToggle()
    {
        if (busy) return;
        SwitchIntent = !running;
        ToggleService();
    }

    // ---- ⌘K / Ctrl+K command bar ----
    public IReadOnlyList<PaletteItem> PaletteItems()
    {
        var items = new List<PaletteItem>
        {
            new("toggle", "Nimbus", "\uE7E8", running ? "Выключить обход" : "Включить обход", "Ctrl ⏎", PerformToggle, enabled: !busy),
            new("find", "Nimbus", "\uE945", testing && testIsSmart ? FindTitle : "Подобрать стратегию", "Ctrl F", () => FindAndApply(), enabled: FindEnabled),
            new("test", "Nimbus", "\uE9D9", testing && !testIsSmart ? testTitle : "Тест всех стратегий", "Ctrl T", () => { Page = HudPage.More; TestStrategies(); }, enabled: FullTestEnabled),
            new("lists-update", "Nimbus", "\uE895", UpdateListsTitle, "Ctrl U", () => UpdateLists(), enabled: CanUpdateLists),
        };
        if (running) items.Add(new("restart", "Nimbus", "\uE72C", "Перезапустить движок", "Ctrl R", () => RestartService(), enabled: !busy));
        items.Add(new("go-more", "Перейти", "\uE712", "Ещё", "", () => Page = HudPage.More));
        items.Add(new("go-lists", "Перейти", "\uEA37", "Списки", "Ctrl L", () => OpenLists()));
        items.Add(new("go-diag", "Перейти", "\uE9D2", "Диагностика", "Ctrl D", () => OpenDiagnostics()));
        items.Add(new("go-logs", "Перейти", "\uE756", "Логи", "Ctrl J", () => OpenLogs()));
        foreach (var strategy in Strategies)
        {
            var id = strategy.Id;
            items.Add(new("s:" + id, "Стратегия", "\uE8AB", strategy.Name, "", () => SelectStrategy(id), id == selectedStrategyId, !busy));
        }
        foreach (var (id, title) in new[] { (IpsetModes.None, "Нет"), (IpsetModes.Loaded, "Стандартный"), (IpsetModes.Any, "Все") })
            items.Add(new("p:" + id, "Пресет", "\uE81E", "Пресет: " + title, "", () => SelectIpset(id), ipsetMode == id, !busy));
        foreach (var (id, title) in new[] { (GameFilterModes.Off, "Выкл"), (GameFilterModes.Games, "Игры"), (GameFilterModes.Wide, "Широкий") })
            items.Add(new("g:" + id, "Игровой фильтр", "\uE7FC", "Игровой фильтр: " + title, "", () => SelectGameFilter(id), gameFilterMode == id, !busy));
        items.Add(new("autopause", "Параметры", "\uE769", "Автопауза при VPN", "", () => ToggleAutoPause(), autoPauseVpn));
        items.Add(new("login", "Параметры", "\uE8FA", "Открывать при входе", "", () => ToggleLogin(), loginEnabled));
        items.Add(new("github", "Параметры", "\uE8A7", "GitHub", "", () => OpenGitHub()));
        items.Add(new("quit", "Параметры", "\uE711", "Выйти из Nimbus", "Ctrl Q", () => Quit()));
        return items;
    }

    /// <summary>Enabled items matching the query; with an empty query the long tail (presets, settings) is hidden.</summary>
    public IReadOnlyList<PaletteItem> FilteredPalette
    {
        get
        {
            var q = paletteQuery.Trim().ToLowerInvariant();
            var all = PaletteItems().Where(i => i.Enabled);
            var list = (q.Length == 0
                ? all.Where(i => i.Group is not ("Пресет" or "Игровой фильтр") && (i.Group != "Параметры" || i.Id == "quit"))
                : all.Where(i => i.Title.ToLowerInvariant().Contains(q) || i.Group.ToLowerInvariant().Contains(q))).ToList();
            for (var i = 0; i < list.Count; i++)
            {
                list[i].ShowGroup = i == 0 || list[i - 1].Group != list[i].Group;
                list[i].Selected = i == paletteIndex;
            }
            return list;
        }
    }

    public bool PaletteEmpty => FilteredPalette.Count == 0;

    public void OpenPalette()
    {
        paletteQuery = "";
        paletteIndex = 0;
        Raise(nameof(PaletteQuery), nameof(PaletteIndex));
        PaletteOpen = true;
    }

    public void ClosePalette() => PaletteOpen = false;

    public void RunPalette(int? index = null)
    {
        var items = FilteredPalette;
        var i = index ?? paletteIndex;
        if (i < 0 || i >= items.Count) return;
        ClosePalette();
        items[i].Run();
    }

    public string IpsetTitle => IpsetModes.Title(ipsetMode);
    public string GameFilterTitle => GameFilterModes.Title(gameFilterMode);
    public string StatusTitle => running ? "Включён" : "Выключен";
    public bool HasTestPanel => testing || testRows.Count > 0 || testBest.Length > 0;
    public bool HasTestProgress => testProgress.Length > 0;
    public bool HasTestRows => testRows.Count > 0;
    public bool HasTestBest => testBest.Length > 0;
    public bool CanApplyRow => !testing && !busy;
    public string LiveTestText => testProgress.Length == 0 ? "Идёт тест" : testProgress;
    public bool HasVpnWarning => vpnWarning.Length > 0;
    public bool HasUserEntries => userEntries.Count > 0;
    public bool HasDiagnosticText => diagnosticText.Length > 0;
    public bool CanSubmitList => !busy && listInput.Trim().Length > 0;
    public bool CanUpdateLists => !busy && !testing && !updatingLists;
    public string UpdateListsTitle => updatingLists ? "Обновление списков…" : "Обновить списки";
    public string FindTitle => testing && testIsSmart ? (cancellingTest ? "Остановка…" : "Остановить подбор") : "Найти и применить";
    public bool FindEnabled => testing && testIsSmart ? !cancellingTest : !testing && !busy;
    public bool FullTestEnabled => testing ? (testEnabled && !testIsSmart) : testEnabled;
    public double TestFraction => StrategyOrder.ProgressFraction(testProgress);
    public bool ShowTestBar => testing;
    public string ApplyBestTitle => testRows.FirstOrDefault(r => r.IsBest) is { } row ? $"Применить {row.Name}" : "Применить лучшую";
    public bool ShowRestart => running;
    public bool CanRestart => !busy;
    public bool ShowUpdateRow => canInstallUpdate || updating;
    public string UpdateRowTitle => updating ? "Установка…" : versionTitle;
    public bool UpdateRowEnabled => canInstallUpdate && !updating;
    public string FooterVersion => canInstallUpdate ? "Доступно обновление" : versionTitle;
    public string LogsText => logs.Length == 0 ? "Логов пока нет" : logs;
    public bool HasLogs => logs.Length > 0;
    public bool HasNotice => notice.Length > 0;
    public string NoticeGlyph => noticeError ? "\uE7BA" : "\uE930";

    public bool IsMain => page == HudPage.Main;
    public bool IsMore => page == HudPage.More;
    public bool IsLogs => page == HudPage.Logs;
    public bool IsLists => page == HudPage.Lists;
    public bool IsEditor => page == HudPage.Editor;
    public bool IsDiagnostics => page == HudPage.Diagnostics;

    public Action ToggleService = () => { };
    public Action<string> SelectStrategy = _ => { };
    public Action<string> SelectIpset = _ => { };
    public Action<string> SelectGameFilter = _ => { };
    public Action ToggleLogin = () => { };
    public Action TestStrategies = () => { };
    public Action ApplyBest = () => { };
    public Action<string> ApplyTestRow = _ => { };
    public Action OpenLists = () => { };
    public Action<string> OpenList = _ => { };
    public Action SaveList = () => { };
    public Action OpenLogs = () => { };
    public Action CopyLogs = () => { };
    public Action RestartService = () => { };
    public Action OpenGitHub = () => { };
    public Action InstallUpdate = () => { };
    public Action Quit = () => { };
    public Action DismissNotice = () => { };
    public Action FindAndApply = () => { };
    public Action UpdateLists = () => { };
    public Action OpenDiagnostics = () => { };
    public Action CopyDiagnostics = () => { };
    public Action ToggleAutoPause = () => { };
    public Action<string> LeaveAloneChanged = _ => { };
    public Action AddBypass = () => { };
    public Action AddExclude = () => { };
    public Action<UserEntryRow> RemoveUserEntry = _ => { };

    public void GoBack()
    {
        Page = page switch
        {
            HudPage.Editor => HudPage.Lists,
            HudPage.Logs or HudPage.Lists or HudPage.Diagnostics => HudPage.More,
            _ => HudPage.Main,
        };
    }

    private static readonly string[] Derived =
    {
        nameof(Phase), nameof(SwitchOn), nameof(IsProblem), nameof(IsOff), nameof(HeroTitle), nameof(HeroSubtitle), nameof(UptimeText),
        nameof(LatencySummary), nameof(ChartSamples), nameof(ProbeSince), nameof(DiscordValue), nameof(YouTubeValue), nameof(DiscordOk), nameof(YouTubeOk),
        nameof(NetworkLabel), nameof(VpnLabel), nameof(FooterStatusText), nameof(FooterStatusBrush), nameof(FooterPulsing), nameof(ShowFindFooter),
        nameof(FooterVersionLine), nameof(StrategyCountText), nameof(ListsCountText), nameof(DiagnosticsHaveFail), nameof(DiagnosticsHaveWarn),
        nameof(VisibleLogRows), nameof(LogCountText), nameof(LogsEmpty), nameof(LogsEmptyText), nameof(ShowLogHint), nameof(ListsTotalText),
        nameof(UserEntriesCountText), nameof(EditorDirty), nameof(EditorHeader), nameof(CanSave), nameof(OkCountText), nameof(WarnCountText),
        nameof(FailCountText), nameof(DiagnosticsElapsedText), nameof(ShowSkeleton), nameof(NotDiagnosticsRunning), nameof(FilteredPalette), nameof(PaletteEmpty),
    };

    private static readonly HashSet<string> Heavy = new() { nameof(VisibleLogRows), nameof(LogCountText), nameof(LogsEmpty), nameof(FilteredPalette), nameof(PaletteEmpty) };
    private static readonly HashSet<string> LogInputs = new() { nameof(LogLines), nameof(LogSource), nameof(LogQuery) };
    private static readonly HashSet<string> PaletteInputs = new() { nameof(PaletteQuery), nameof(PaletteIndex), nameof(PaletteOpen), nameof(Running), nameof(Busy), nameof(Testing), nameof(SelectedStrategyId), nameof(IpsetMode), nameof(GameFilterMode), nameof(AutoPauseVpn), nameof(LoginEnabled), nameof(UpdatingLists), nameof(TestIsSmart), nameof(CancellingTest) };

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        foreach (var d in Derived)
        {
            if (Heavy.Contains(d))
            {
                var isLog = d is nameof(VisibleLogRows) or nameof(LogCountText) or nameof(LogsEmpty);
                if (isLog ? !LogInputs.Contains(name!) : !(PaletteInputs.Contains(name!) && paletteOpen || name == nameof(PaletteOpen) || name == nameof(PaletteQuery) || name == nameof(PaletteIndex))) continue;
            }
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(d));
        }
        return true;
    }

    private void Raise(params string[] names)
    {
        foreach (var n in names) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }
}
