using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using Nimbus.Core;

namespace Nimbus;

internal enum ServiceHealth { Off, Unknown, Checking, Ok, Bad }

internal enum HudPage { Main, More, Logs, Lists, Editor }

internal sealed record TestRow(string Name, string Score, bool IsBest);

internal sealed record ListRow(ListInfo Info, bool ShowSeparator)
{
    public string Glyph => Info.External ? "\uE8A7" : "\uE70F";
    public bool HasBadge => Info.Badge.Length > 0;
}

/// <summary>Mirror of HUDModel in macos/App/NimbusHUD.swift.</summary>
internal sealed class HudModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    private bool running, busy, testing, cancellingTest, updating, loginEnabled, canInstallUpdate, testEnabled = true, applyBestEnabled, noticeError;
    private string strategyName = "—", selectedStrategyId = "", ipsetMode = "none", versionTitle = "Версия", testTitle = "Тест стратегий";
    private string testProgress = "", testBest = "", logs = "", editorName = "", editorTitle = "", editorText = "", notice = "";
    private HudPage page = HudPage.Main;
    private ServiceHealth discord = ServiceHealth.Unknown, youtube = ServiceHealth.Unknown;
    private IReadOnlyList<TestRow> testRows = Array.Empty<TestRow>();
    private IReadOnlyList<ListRow> lists = Array.Empty<ListRow>();

    public IReadOnlyList<Strategy> Strategies { get; set; } = Array.Empty<Strategy>();

    public bool Running { get => running; set { if (Set(ref running, value)) Raise(nameof(StatusTitle), nameof(ShowRestart)); } }
    public bool Busy { get => busy; set { if (Set(ref busy, value)) Raise(nameof(NotBusy), nameof(CanRestart), nameof(CanApplyRow)); } }
    public bool NotBusy => !busy;
    public bool Testing { get => testing; set { if (Set(ref testing, value)) Raise(nameof(HasTestPanel), nameof(CanApplyRow)); } }
    public bool CancellingTest { get => cancellingTest; set => Set(ref cancellingTest, value); }
    public bool Updating { get => updating; set { if (Set(ref updating, value)) Raise(nameof(ShowUpdateRow), nameof(UpdateRowTitle), nameof(UpdateRowEnabled)); } }
    public string StrategyName { get => strategyName; set => Set(ref strategyName, value); }
    public string SelectedStrategyId { get => selectedStrategyId; set => Set(ref selectedStrategyId, value); }
    public string IpsetMode { get => ipsetMode; set { if (Set(ref ipsetMode, value)) Raise(nameof(IpsetTitle)); } }
    public bool LoginEnabled { get => loginEnabled; set => Set(ref loginEnabled, value); }
    public string VersionTitle { get => versionTitle; set { if (Set(ref versionTitle, value)) Raise(nameof(UpdateRowTitle), nameof(FooterVersion)); } }
    public bool CanInstallUpdate { get => canInstallUpdate; set { if (Set(ref canInstallUpdate, value)) Raise(nameof(ShowUpdateRow), nameof(UpdateRowEnabled), nameof(FooterVersion)); } }
    public HudPage Page
    {
        get => page;
        set
        {
            if (Set(ref page, value))
                Raise(nameof(IsMain), nameof(IsMore), nameof(IsLogs), nameof(IsLists), nameof(IsEditor));
        }
    }
    public string TestTitle { get => testTitle; set => Set(ref testTitle, value); }
    public bool TestEnabled { get => testEnabled; set => Set(ref testEnabled, value); }
    public string TestProgress { get => testProgress; set { if (Set(ref testProgress, value)) Raise(nameof(HasTestProgress), nameof(LiveTestText), nameof(HasTestPanel)); } }
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

    public string IpsetTitle => IpsetModes.Title(ipsetMode);
    public string StatusTitle => running ? "Включён" : "Выключен";
    public bool HasTestPanel => testing || testRows.Count > 0 || testBest.Length > 0;
    public bool HasTestProgress => testProgress.Length > 0;
    public bool HasTestRows => testRows.Count > 0;
    public bool HasTestBest => testBest.Length > 0;
    public bool CanApplyRow => !testing && !busy;
    public string LiveTestText => testProgress.Length == 0 ? "Идёт тест" : testProgress;
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

    public Action ToggleService = () => { };
    public Action<string> SelectStrategy = _ => { };
    public Action<string> SelectIpset = _ => { };
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

    public void GoBack()
    {
        Page = page switch
        {
            HudPage.Editor => HudPage.Lists,
            HudPage.Logs or HudPage.Lists => HudPage.More,
            _ => HudPage.Main,
        };
    }

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        return true;
    }

    private void Raise(params string[] names)
    {
        foreach (var n in names) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }
}
