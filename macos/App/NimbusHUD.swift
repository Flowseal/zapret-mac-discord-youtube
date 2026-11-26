import AppKit
import Combine
import QuartzCore
import SwiftUI

// The Nimbus panel: near-black hairline panel under the menu-bar glyph,
// dense 32 pt rows, one accent, mono for technical data, ⌘K command bar, spring motion.

enum ServiceHealth {
    case off, unknown, checking, ok, bad

    var color: Color {
        switch self {
        case .ok: return NB.accent
        case .bad: return NB.warn
        default: return NB.t3
        }
    }
}

enum HUDPage: String {
    case main, more, logs, lists, editor, diagnostics

    var depth: Int {
        switch self {
        case .main: return 0
        case .more: return 1
        case .logs, .lists, .diagnostics: return 2
        case .editor: return 3
        }
    }
}

struct UserEntry: Identifiable, Equatable {
    let file: String
    let value: String
    var id: String { file + "\t" + value }
    var badge: String {
        switch file {
        case UserListIO.bypassDomains, UserListIO.bypassIpset: return "обход"
        default: return "исключение"
        }
    }
    var isBypass: Bool { badge == "обход" }
}

struct TestRow: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let score: String
    let isBest: Bool
}

struct ListInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let badge: String
    let external: Bool
    var lines: Int = 0
}

struct PaletteItem: Identifiable {
    let id: String
    let group: String
    let icon: String
    let title: String
    let keys: [String]
    var checked = false
    var enabled = true
    let run: () -> Void
}

struct EditorCaret: Equatable {
    var line = 1
    var column = 1
}

final class HUDModel: ObservableObject {
    /// Writes only real changes. Every @Published write re-renders the panel, even with the same value,
    /// and the once-a-second refresh used to restart the body mid-animation.
    func update<T: Equatable>(_ key: ReferenceWritableKeyPath<HUDModel, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    @Published var running = false
    @Published var busy = false
    @Published var testing = false
    @Published var cancellingTest = false
    @Published var updating = false
    @Published var strategyName = "—"
    @Published var selectedStrategyID = ""
    @Published var strategies: [Strategy] = []
    @Published var ipsetMode = "none"
    @Published var loginEnabled = false
    @Published var versionTitle = "Версия"
    @Published var appVersion = ""
    @Published var canInstallUpdate = false
    @Published var page: HUDPage = .main {
        didSet { if page != oldValue { forward = page.depth >= oldValue.depth } }
    }
    @Published var forward = true
    @Published var testTitle = "Тест стратегий"
    @Published var testEnabled = true
    @Published var testProgress = ""
    @Published var testRows: [TestRow] = []
    @Published var testBest = ""
    @Published var applyBestEnabled = false
    @Published var discord: ServiceHealth = .unknown
    @Published var youtube: ServiceHealth = .unknown
    @Published var discordMs: Int?
    @Published var youtubeMs: Int?
    @Published var latencySamples: [Double] = []
    @Published var lastProbe: Date?
    @Published var engineStarted: Date?
    @Published var networkInterface = ""
    @Published var networkAddress = ""
    @Published var logs = ""
    @Published var logLines: [LogLine] = []
    @Published var logSource = "all"
    @Published var logQuery = ""
    @Published var lists: [ListInfo] = []
    @Published var editorName = ""
    @Published var editorTitle = ""
    @Published var editorText = ""
    @Published var editorOriginal = ""
    @Published var editorCaret = EditorCaret()
    @Published var notice = ""
    @Published var noticeError = false
    @Published var vpnWarning = ""
    @Published var autoPauseVpn = false
    @Published var listInput = ""
    @Published var extraHost = ""
    @Published var userEntries: [UserEntry] = []
    @Published var diagnostics: [DiagnosticItem] = []
    @Published var diagnosticText = ""
    @Published var diagnosticsRunning = false
    @Published var diagnosticsElapsed: Double = 0
    @Published var updatingLists = false
    @Published var testIsSmart = false
    @Published var switchIntent: Bool?
    @Published var moreQuery = ""
    @Published var paletteOpen = false
    @Published var paletteQuery = ""
    @Published var paletteIndex = 0
    @Published var presented = true
    @Published var openEpoch = 0
    /// Height of the visible panel as SwiftUI laid it out; the window follows it (HUDController).
    var onPanelHeight: (CGFloat) -> Void = { _ in }

    var toggleService: () -> Void = {}
    var selectStrategy: (String) -> Void = { _ in }
    var selectIPSet: (String) -> Void = { _ in }
    var toggleLogin: () -> Void = {}
    var testStrategies: () -> Void = {}
    var applyBest: () -> Void = {}
    var applyTestRow: (String) -> Void = { _ in }
    var openLists: () -> Void = {}
    var openList: (String) -> Void = { _ in }
    var saveList: () -> Void = {}
    var openLogs: () -> Void = {}
    var copyLogs: () -> Void = {}
    var restartService: () -> Void = {}
    var openGitHub: () -> Void = {}
    var installUpdate: () -> Void = {}
    var quit: () -> Void = {}
    var onShown: () -> Void = {}
    var dismissNotice: () -> Void = {}
    var findAndApply: () -> Void = {}
    var updateLists: () -> Void = {}
    var openDiagnostics: () -> Void = {}
    var copyDiagnostics: () -> Void = {}
    var toggleAutoPause: () -> Void = {}
    var addBypass: () -> Void = {}
    var addExclude: () -> Void = {}
    var removeUserEntry: (UserEntry) -> Void = { _ in }
    var requestClose: () -> Void = {}

    var ipsetTitle: String {
        switch ipsetMode {
        case "loaded": return "Стандартный"
        case "any": return "Все"
        default: return "Нет"
        }
    }

    var statusTitle: String { running ? "Включён" : "Выключен" }
    var hasTestPanel: Bool { testing || !testRows.isEmpty || !testBest.isEmpty }
    var hasVpnWarning: Bool { !vpnWarning.isEmpty }
    var testFraction: Double { StrategyOrdering.progressFraction(testProgress) }
    var findTitle: String {
        if testing && testIsSmart {
            return cancellingTest ? "Остановка…" : "Остановить подбор"
        }
        return "Найти и применить"
    }
    var findEnabled: Bool {
        if testing && testIsSmart { return !cancellingTest }
        return !testing && !busy
    }
    var fullTestEnabled: Bool { testing ? (testEnabled && !testIsSmart) : testEnabled }
    var canUpdateLists: Bool { !busy && !testing && !updatingLists }
    var canSubmitList: Bool { !busy && !listInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var editorDirty: Bool { editorText != editorOriginal }
    var switchOn: Bool { switchIntent ?? running }

    var applyBestTitle: String {
        if let name = testRows.first(where: \.isBest)?.name {
            return "Применить \(name)"
        }
        return "Применить лучшую"
    }

    /// off · checking (starting, testing, probing) · on · problem (a probe failed).
    var phase: MarkState {
        if !running { return busy || switchIntent == true ? .checking : .off }
        if busy || testing { return .checking }
        if discord == .bad || youtube == .bad { return .problem }
        if discord == .checking || youtube == .checking { return .checking }
        return .on
    }

    var failingServices: [String] {
        var out: [String] = []
        if discord == .bad { out.append("Discord") }
        if youtube == .bad { out.append("YouTube") }
        return out
    }

    var heroTitle: String {
        switch phase {
        case .off: return "Обход выключен"
        case .checking:
            if testing { return testIsSmart ? "Подбор стратегии…" : "Тест стратегий…" }
            return running ? "Проверка сервисов…" : "Подключение…"
        case .on: return "Обход активен"
        case .problem:
            let bad = failingServices
            return bad.count == 1 ? "\(bad[0]) недоступен" : "Сервисы недоступны"
        }
    }

    var heroSubtitle: String {
        switch phase {
        case .off: return "⌘⏎ — включить"
        case .checking:
            if testing, !testProgress.isEmpty { return testProgress }
            return "\(strategyName) · проверка сервисов"
        case .on: return "\(strategyName) · ipset \(ipsetTitle.lowercased())"
        case .problem:
            let host = youtube == .bad ? "youtube.com" : "discord.com"
            return "\(strategyName) · \(host) timeout"
        }
    }

    var footerStatus: (text: String, color: Color, pulsing: Bool) {
        switch phase {
        case .off: return ("Не активен", NB.t3, false)
        case .checking: return (testing ? "Идёт тест…" : "Проверка…", NB.t3, true)
        case .on: return ("Все сервисы доступны", NB.accent, false)
        case .problem: return (failingServices.map { "\($0): timeout" }.joined(separator: " · "), NB.warn, false)
        }
    }

    var latencySummary: String {
        let finite = latencySamples.filter { $0.isFinite }
        guard finite.count >= 2 else { return "нет данных" }
        let p50 = LatencyStats.percentile(finite, 0.5)
        let p95 = LatencyStats.percentile(finite, 0.95)
        return "p50 \(Int(p50.rounded())) ms · p95 \(Int(p95.rounded())) ms"
    }

    var visibleLogLines: [LogLine] {
        let q = logQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return logLines.filter { line in
            (logSource == "all" || line.source == logSource) && LogParser.matches(line, query: q)
        }
    }

    func goBack() {
        switch page {
        case .editor: page = .lists
        case .logs, .lists, .diagnostics: page = .more
        case .more: page = .main
        case .main: break
        }
    }

    func performToggle() {
        guard !busy else { return }
        switchIntent = !running
        toggleService()
    }

    // MARK: command bar

    func paletteItems() -> [PaletteItem] {
        var items: [PaletteItem] = [
            PaletteItem(id: "toggle", group: "Nimbus", icon: "power", title: running ? "Выключить обход" : "Включить обход", keys: ["⌘", "⏎"], enabled: !busy) { [weak self] in self?.performToggle() },
            PaletteItem(id: "find", group: "Nimbus", icon: "bolt", title: testing && testIsSmart ? findTitle : "Подобрать стратегию", keys: ["⌘", "F"], enabled: findEnabled) { [weak self] in self?.findAndApply() },
            PaletteItem(id: "test", group: "Nimbus", icon: "flask", title: testing && !testIsSmart ? testTitle : "Тест всех стратегий", keys: ["⌘", "T"], enabled: fullTestEnabled) { [weak self] in
                self?.page = .more
                self?.testStrategies()
            },
            PaletteItem(id: "lists-update", group: "Nimbus", icon: "arrow.triangle.2.circlepath", title: updatingLists ? "Обновление списков…" : "Обновить списки", keys: ["⌘", "U"], enabled: canUpdateLists) { [weak self] in self?.updateLists() },
        ]
        if running {
            items.append(PaletteItem(id: "restart", group: "Nimbus", icon: "arrow.clockwise", title: "Перезапустить движок", keys: ["⌘", "R"], enabled: !busy) { [weak self] in self?.restartService() })
        }
        items += [
            PaletteItem(id: "go-more", group: "Перейти", icon: "ellipsis", title: "Ещё", keys: []) { [weak self] in self?.page = .more },
            PaletteItem(id: "go-lists", group: "Перейти", icon: "list.bullet", title: "Списки", keys: ["⌘", "L"]) { [weak self] in self?.openLists() },
            PaletteItem(id: "go-diag", group: "Перейти", icon: "waveform.path.ecg", title: "Диагностика", keys: ["⌘", "D"]) { [weak self] in self?.openDiagnostics() },
            PaletteItem(id: "go-logs", group: "Перейти", icon: "terminal", title: "Логи", keys: ["⌘", "J"]) { [weak self] in self?.openLogs() },
        ]
        for strategy in strategies {
            let id = strategy.id
            items.append(PaletteItem(id: "s:" + id, group: "Стратегия", icon: "arrow.turn.up.right", title: strategy.name, keys: [], checked: id == selectedStrategyID, enabled: !busy) { [weak self] in self?.selectStrategy(id) })
        }
        for preset in SegmentOption.presets {
            let id = preset.id, title = preset.title
            items.append(PaletteItem(id: "p:" + id, group: "Пресет", icon: "square.stack.3d.up", title: "Пресет: \(title)", keys: [], checked: ipsetMode == id, enabled: !busy) { [weak self] in self?.selectIPSet(id) })
        }
        items += [
            PaletteItem(id: "autopause", group: "Параметры", icon: "pause", title: "Автопауза при VPN", keys: [], checked: autoPauseVpn) { [weak self] in self?.toggleAutoPause() },
            PaletteItem(id: "login", group: "Параметры", icon: "rectangle.portrait.and.arrow.right", title: "Открывать при входе", keys: [], checked: loginEnabled) { [weak self] in self?.toggleLogin() },
            PaletteItem(id: "github", group: "Параметры", icon: "arrow.up.right", title: "GitHub", keys: []) { [weak self] in self?.openGitHub() },
            PaletteItem(id: "quit", group: "Параметры", icon: "xmark", title: "Выйти из Nimbus", keys: ["⌘", "Q"]) { [weak self] in self?.quit() },
        ]
        return items
    }

    /// Enabled items matching the query; with an empty query the long tail (presets, settings) is hidden.
    var filteredPalette: [PaletteItem] {
        let q = paletteQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let all = paletteItems().filter(\.enabled)
        if q.isEmpty {
            return all.filter { $0.group != "Пресет" && ($0.group != "Параметры" || $0.id == "quit") }
        }
        return all.filter { $0.title.lowercased().contains(q) || $0.group.lowercased().contains(q) }
    }

    func openPalette() {
        paletteQuery = ""
        paletteIndex = 0
        withAnimation(Motion.smooth) { paletteOpen = true }
    }

    func closePalette() {
        withAnimation(Motion.snappy) { paletteOpen = false }
    }

    func runPalette(_ index: Int? = nil) {
        let items = filteredPalette
        let i = index ?? paletteIndex
        guard items.indices.contains(i) else { return }
        let item = items[i]
        closePalette()
        withAnimation(Motion.smooth) { item.run() }
    }

    // MARK: keyboard

    /// Layout-independent key codes (ANSI positions) so shortcuts also work on the Russian layout.
    private enum Key {
        static let returnKey: UInt16 = 36, enter: UInt16 = 76, escape: UInt16 = 53, down: UInt16 = 125, up: UInt16 = 126
        static let k: UInt16 = 40, f: UInt16 = 3, t: UInt16 = 17, u: UInt16 = 32, r: UInt16 = 15, l: UInt16 = 37
        static let d: UInt16 = 2, j: UInt16 = 38, c: UInt16 = 8, s: UInt16 = 1, q: UInt16 = 12
    }

    /// Returns true when the key was consumed by the panel.
    func handleKey(_ event: NSEvent, textSelected: Bool, editingText: Bool) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let code = event.keyCode
        if paletteOpen {
            let count = filteredPalette.count
            switch code {
            case Key.escape:
                closePalette()
                return true
            case Key.down:
                if count > 0 { paletteIndex = min(count - 1, paletteIndex + 1) }
                return true
            case Key.up:
                paletteIndex = max(0, paletteIndex - 1)
                return true
            case Key.returnKey, Key.enter:
                runPalette()
                return true
            default:
                break
            }
            if cmd && code == Key.k {
                closePalette()
                return true
            }
            return false
        }
        if code == Key.escape {
            if page == .main {
                requestClose()
            } else {
                withAnimation(Motion.smooth) { goBack() }
            }
            return true
        }
        if cmd {
            switch code {
            case Key.k: openPalette()
            case Key.returnKey, Key.enter: performToggle()
            case Key.f: if findEnabled { findAndApply() }
            case Key.t:
                if fullTestEnabled {
                    page = .more
                    testStrategies()
                }
            case Key.u: if canUpdateLists { updateLists() }
            case Key.r:
                if page == .diagnostics {
                    if !diagnosticsRunning { openDiagnostics() }
                } else if running && !busy {
                    restartService()
                }
            case Key.l: openLists()
            case Key.d: openDiagnostics()
            case Key.j: openLogs()
            case Key.q: quit()
            case Key.s:
                guard page == .editor else { return false }
                if !busy {
                    saveList()
                    editorOriginal = editorText
                }
            case Key.c:
                guard !textSelected else { return false }
                if page == .logs {
                    copyLogs()
                } else if page == .diagnostics {
                    copyDiagnostics()
                } else {
                    return false
                }
            default:
                return false
            }
            return true
        }
        if code == Key.returnKey || code == Key.enter, page == .main, !editingText, phase == .problem, findEnabled {
            findAndApply()
            return true
        }
        return false
    }
}

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class HUDController {
    /// Transparent margin around the panel so the SwiftUI shadow is not clipped.
    static let margin: CGFloat = 18

    private let model: HUDModel
    private let panel: HUDPanel
    private let hosting: NSHostingController<NimbusHUDView>
    private var monitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?
    private var closing = false
    private var subscriptions = Set<AnyCancellable>()
    private weak var statusButton: NSStatusBarButton?
    /// Screen rect of the status item; set by show(relativeTo:) or show(below:) for the screenshot renderer.
    private var anchorRect: NSRect?
    private weak var anchorScreen: NSScreen?
    /// Last panel height reported by SwiftUI (without the shadow margin).
    private(set) var panelHeight: CGFloat = 0
    private var shrinkWork: DispatchWorkItem?
    /// Used before SwiftUI has reported a height: tall enough for every page, transparent below the panel.
    static let provisionalHeight: CGFloat = 720

    init(model: HUDModel) {
        self.model = model
        hosting = NSHostingController(rootView: NimbusHUDView(model: model))
        hosting.sizingOptions = []
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: NB.width + 2 * Self.margin, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.contentViewController = hosting
        model.requestClose = { [weak self] in self?.close() }
        model.onPanelHeight = { [weak self] height in
            guard let self, height > 1, abs(height - self.panelHeight) > 0.5 else { return }
            self.panelHeight = height
            // reported during a SwiftUI layout pass: resize the window right after it
            DispatchQueue.main.async { self.relayout() }
        }
    }

    /// The window that hosts the panel (for the screenshot renderer).
    var window: NSPanel { panel }

    var isVisible: Bool { panel.isVisible && !closing }

    func toggle(relativeTo button: NSStatusBarButton) {
        if isVisible {
            close()
        } else {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        statusButton = button
        if let buttonWindow = button.window {
            anchorRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            anchorScreen = buttonWindow.screen
        }
        present()
        button.highlight(true)
        startMonitors()
    }

    /// Shows the panel under a given screen rect, as if a status item were there (screenshot renderer).
    func show(below rect: NSRect, on screen: NSScreen?) {
        anchorRect = rect
        anchorScreen = screen
        present()
    }

    private func present() {
        let wasVisible = panel.isVisible && !closing
        closing = false
        model.onShown()
        model.paletteOpen = false
        if !wasVisible {
            // blur-in: content starts slightly small, transparent and blurred, then springs to rest
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.presented = false
                model.openEpoch += 1
            }
        }
        // measure the content in a tall window first so nothing is laid out squeezed
        if !wasVisible {
            panel.setContentSize(NSSize(width: NB.width + 2 * Self.margin, height: max(Self.provisionalHeight, panelHeight) + 2 * Self.margin))
            hosting.view.layoutSubtreeIfNeeded()
        }
        relayout(animated: false)
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            withAnimation(Motion.panel) { self.model.presented = true }
        }
    }

    func relayout() {
        relayout(animated: true)
    }

    func relayout(animated: Bool) {
        if let button = statusButton, let buttonWindow = button.window {
            anchorRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            anchorScreen = buttonWindow.screen
        }
        guard let anchor = anchorRect else { return }
        let screen = anchorScreen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: anchor.minY)
        let width = NB.width + 2 * Self.margin
        // the panel starts 6 pt under the menu bar; the window adds the transparent shadow margin
        let panelTop = min(anchor.minY, visible.maxY) - 6
        let maxPanelHeight = max(panelTop - visible.minY - 8, 120)
        let wanted = panelHeight > 1 ? min(panelHeight, maxPanelHeight) : min(Self.provisionalHeight, maxPanelHeight)
        var x = anchor.midX - width / 2
        x = min(max(x, visible.minX + 8 - Self.margin), visible.maxX - width + Self.margin - 8)
        let top = panelTop + Self.margin
        let target = NSRect(x: x, y: top - wanted - 2 * Self.margin, width: width, height: wanted + 2 * Self.margin)

        let current = panel.frame
        if panel.isVisible, animated, shrinkWork == nil, abs(current.minX - target.minX) < 0.5,
           abs(current.maxY - target.maxY) < 0.5, abs(current.height - target.height) < 0.5 {
            // already the right size: don't touch the window mid-animation
            return
        }
        shrinkWork?.cancel()
        shrinkWork = nil
        // while visible, let the next Core Animation commit draw the resized window instead of
        // forcing a synchronous redraw in the middle of a SwiftUI transition
        let display = !panel.isVisible || !animated
        if !panel.isVisible || !animated || target.height >= current.height - 0.5 {
            // growing (or first show): resize at once; the panel is top-aligned, so the extra room is transparent
            panel.setFrame(target, display: display)
        } else {
            // shrinking: keep the window until the page transition has played, then cut the empty space
            panel.setFrame(NSRect(x: target.minX, y: top - current.height, width: width, height: current.height), display: false)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.shrinkWork = nil
                guard self.panel.isVisible else { return }
                self.panel.setFrame(target, display: false)
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.reduce ? 0.05 : 0.36), execute: work)
        }
    }

    /// The drawn panel inside the window (excludes the shadow margin and any transparent space below).
    private var panelRect: NSRect {
        let frame = panel.frame
        let height = panelHeight > 1 ? min(panelHeight, frame.height - 2 * Self.margin) : frame.height - 2 * Self.margin
        return NSRect(x: frame.minX + Self.margin, y: frame.maxY - Self.margin - height, width: NB.width, height: height)
    }

    func close() {
        guard panel.isVisible, !closing else { return }
        closing = true
        stopMonitors()
        statusButton?.highlight(false)
        withAnimation(Motion.snappy) {
            model.presented = false
            model.paletteOpen = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.reduce ? 0.12 : 0.2)) { [weak self] in
            guard let self, self.closing else { return }
            self.closing = false
            self.panel.orderOut(nil)
            if !self.model.testing {
                self.model.page = .main
            }
        }
    }

    private func startMonitors() {
        stopMonitors()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.closeIfOutside(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.closeIfOutside(event)
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.panel.isVisible, event.window === self.panel else { return event }
            let textView = self.panel.firstResponder as? NSTextView
            let selected = (textView?.selectedRange().length ?? 0) > 0
            let editing = textView?.isEditable ?? false
            return self.model.handleKey(event, textSelected: selected, editingText: editing) ? nil : event
        }
    }

    private func stopMonitors() {
        for m in [monitor, localMonitor, keyMonitor] {
            if let m { NSEvent.removeMonitor(m) }
        }
        monitor = nil
        localMonitor = nil
        keyMonitor = nil
    }

    private func closeIfOutside(_ event: NSEvent) {
        guard panel.isVisible, !closing else { return }
        if event.window === panel { return }
        if event.window?.level == .popUpMenu { return }
        if let button = statusButton, event.window === button.window { return }
        let loc = NSEvent.mouseLocation
        if panelRect.contains(loc) { return }
        if let button = statusButton, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            if rect.contains(loc) { return }
        }
        close()
    }
}

// MARK: - Root

struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct NimbusHUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        // The panel always takes its own height and sticks to the top of the window. The window is
        // sized from the reported height, so a window that is briefly taller (while a page grows or
        // shrinks) is just transparent below the panel and nothing gets cut or centered.
        panel
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(PanelHeightKey.self) { height in
                model.onPanelHeight(height)
            }
            .scaleEffect(model.presented ? 1 : 0.96, anchor: .top)
            .opacity(model.presented ? 1 : 0)
            .offset(y: model.presented || Motion.reduce ? 0 : -6)
            .padding(HUDController.margin)
            .frame(width: NB.width + 2 * HUDController.margin)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            if !model.notice.isEmpty {
                NoticeBanner(model: model)
                    .transition(.textSwap)
            }
            ZStack(alignment: .top) {
                pageContent
                    .id(model.page)
                    .transition(.page(forward: model.forward))
            }
            .id(model.openEpoch)
            .animation(Motion.smooth, value: model.page)
        }
        // blur-in on the content only: blurring the material and shadow too meant an offscreen pass
        // over the whole window on every frame of the open animation
        .blur(radius: model.presented || Motion.reduce ? 0 : 8)
        .frame(width: NB.width)
        .overlay {
            if model.paletteOpen {
                NB.scrim
                    .contentShape(Rectangle())
                    .onTapGesture { model.closePalette() }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.paletteOpen {
                CommandBar(model: model)
                    .padding(.trailing, 8)
                    .padding(.bottom, NB.footerHeight + 8)
                    .transition(.paletteMorph)
            }
        }
        .animation(Motion.smooth, value: model.paletteOpen)
        .animation(Motion.snappy, value: model.notice)
        .background(
            ZStack {
                PanelMaterial()
                NB.panel
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: NB.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: NB.radius, style: .continuous).strokeBorder(NB.line2, lineWidth: 1))
        .background(ShapeShadow(cornerRadius: NB.radius, layers: [
            .init(opacity: 0.28, radius: 16, y: 10),
            .init(opacity: 0.12, radius: 3, y: 1),
        ]))
        .foregroundStyle(NB.t1)
        .font(NB.body)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch model.page {
        case .main: MainPage(model: model)
        case .more: MorePage(model: model)
        case .logs: LogsPage(model: model)
        case .lists: ListsPage(model: model)
        case .editor: EditorPage(model: model)
        case .diagnostics: DiagnosticsPage(model: model)
        }
    }
}

extension AnyTransition {
    static var paletteMorph: AnyTransition {
        if Motion.reduce { return .opacity }
        return .modifier(active: PaletteMorph(progress: 0), identity: PaletteMorph(progress: 1))
    }
}

private struct PaletteMorph: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.97 + 0.03 * progress, anchor: .bottomTrailing)
            .offset(y: 6 * (1 - progress))
            .blur(radius: 6 * (1 - progress))
            .opacity(progress)
    }
}

// MARK: - Shared chrome

struct PanelFooter<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 10) {
                HStack(spacing: 8) { leading() }
                    .font(NB.small)
                    .foregroundStyle(NB.t2)
                    .lineLimit(1)
                    .layoutPriority(-1)
                Spacer(minLength: 8)
                HStack(spacing: 10) { trailing() }
                    .fixedSize()
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(height: NB.footerHeight - 1)
            .background(NB.raised)
        }
    }
}

struct FooterAction: View {
    let title: String
    let keys: [String]
    var primary = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(primary ? .system(size: 12, weight: .medium) : NB.small)
                    .foregroundStyle(primary ? NB.t1 : NB.t2)
                    .lineLimit(1)
                    .fixedSize()
                Keycap(keys: keys)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

struct FooterSeparator: View {
    var body: some View {
        Rectangle().fill(NB.line2).frame(width: 1, height: 16)
    }
}

struct ActionsFooterButton: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        FooterAction(title: "Действия", keys: ["⌘", "K"]) { model.openPalette() }
    }
}

/// "‹ Nimbus / Title" header used by every sub page.
struct SubHeader<Trailing: View>: View {
    @ObservedObject var model: HUDModel
    let title: String
    var monoTitle = false
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(Motion.smooth) { model.goBack() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(NB.t2)
                            .frame(width: 16, height: 16)
                        Text("Nimbus").foregroundStyle(NB.t3)
                        Text("/").foregroundStyle(NB.t3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Назад (esc)")
                Text(title)
                    .font(monoTitle ? NB.mono(12.5, weight: .medium) : .system(size: 13, weight: .semibold))
                    .foregroundStyle(NB.t1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                trailing()
            }
            .font(NB.body)
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(height: NB.headerHeight - 1)
            Hairline()
        }
    }
}

extension SubHeader where Trailing == EmptyView {
    init(model: HUDModel, title: String, monoTitle: Bool = false) {
        self.init(model: model, title: title, monoTitle: monoTitle) { EmptyView() }
    }
}

struct NoticeBanner: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                RowIcon(name: model.noticeError ? "exclamationmark.triangle" : "checkmark", color: model.noticeError ? NB.err : NB.accent)
                Text(model.notice)
                    .font(NB.small)
                    .foregroundStyle(NB.t1)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(action: model.dismissNotice) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NB.t3)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(model.noticeError ? NB.err.opacity(0.08) : NB.accentSoft)
            Hairline()
        }
    }
}

/// 32 pt bordered input with leading icon (search / filter / domain field).
struct PanelInput<Trailing: View>: View {
    let placeholder: String
    @Binding var text: String
    var icon: String? = "magnifyingglass"
    var mono = false
    var onSubmit: () -> Void = {}
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                RowIcon(name: icon, color: NB.t3)
            }
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(NB.t3))
                .textFieldStyle(.plain)
                .font(mono ? NB.mono(12.5) : NB.body)
                .foregroundStyle(NB.t1)
                .onSubmit(onSubmit)
            trailing()
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(NB.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(NB.line2, lineWidth: 1))
    }
}

extension PanelInput where Trailing == EmptyView {
    init(placeholder: String, text: Binding<String>, icon: String? = "magnifyingglass", mono: Bool = false, onSubmit: @escaping () -> Void = {}) {
        self.init(placeholder: placeholder, text: text, icon: icon, mono: mono, onSubmit: onSubmit) { EmptyView() }
    }
}

struct Tag: View {
    let text: String
    var accent = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(accent ? NB.accent : NB.t2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(accent ? NB.accentSoft : NB.sel, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct PanelButton: View {
    let title: String
    var primary = false
    var keys: [String] = []
    var height: CGFloat = 26
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                if !keys.isEmpty {
                    if primary {
                        ForEach(keys, id: \.self) { key in
                            Text(key)
                                .font(.system(size: 11, weight: .medium))
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    } else {
                        Keycap(keys: keys)
                    }
                }
            }
            .foregroundStyle(primary ? Color.white : NB.t1)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(primary ? NB.accent : NB.raised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(primary ? Color.clear : NB.line2, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

struct SegmentOption: Identifiable {
    let id: String
    let title: String

    static let presets = [
        SegmentOption(id: "none", title: "Нет"),
        SegmentOption(id: "loaded", title: "Стандартный"),
        SegmentOption(id: "any", title: "Все"),
    ]
}

struct Segmented: View {
    let options: [SegmentOption]
    @Binding var selection: String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let on = option.id == selection
                Button {
                    withAnimation(Motion.snappy) { selection = option.id }
                } label: {
                    Text(option.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(on ? NB.t1 : NB.t2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(NB.sel)
                                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(NB.line, lineWidth: 1))
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(NB.kbd, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(NB.line, lineWidth: 1))
    }
}

/// A row that opens a native menu: the visible chrome is ours, the hit target is an invisible Menu on top.
struct MenuRow<Items: View>: View {
    let icon: String
    let title: String
    let value: String
    var monoValue = false
    var enabled = true
    @ViewBuilder let items: () -> Items

    var body: some View {
        RowChrome {
            RowIcon(name: icon)
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .font(monoValue ? NB.mono(12.5) : NB.body)
                .foregroundStyle(monoValue ? NB.t1 : NB.t2)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(NB.t3)
        }
        .overlay {
            Menu { items() } label: { Color.clear }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .opacity(0.02)
                .padding(.horizontal, 6)
                .disabled(!enabled)
        }
        .opacity(enabled ? 1 : 0.5)
    }
}

/// Plain clickable row: icon, title, trailing accessory.
struct ActionRow<Trailing: View>: View {
    let icon: String
    let title: String
    var iconColor: Color = NB.t2
    var titleColor: Color = NB.t1
    var enabled = true
    var selected = false
    let action: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        Button(action: action) {
            RowIcon(name: icon, color: iconColor)
            Text(title).foregroundStyle(titleColor).lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 8) { trailing() }
        }
        .buttonStyle(RowButtonStyle(selected: selected))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

extension ActionRow where Trailing == EmptyView {
    init(icon: String, title: String, iconColor: Color = NB.t2, titleColor: Color = NB.t1, enabled: Bool = true, selected: Bool = false, action: @escaping () -> Void) {
        self.init(icon: icon, title: title, iconColor: iconColor, titleColor: titleColor, enabled: enabled, selected: selected, action: action) { EmptyView() }
    }
}

struct MetaText: View {
    let text: String
    var body: some View {
        Text(text).font(NB.mono(11.5)).foregroundStyle(NB.t3).lineLimit(1)
    }
}

// MARK: - Главная

struct UptimeText: View {
    let started: Date?
    let running: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(running ? (started.map { EngineClock.format(context.date.timeIntervalSince($0)) } ?? "—") : "—")
                .font(NB.mono(11))
                .foregroundStyle(NB.t3)
                .monospacedDigit()
        }
    }
}

struct SinceText: View {
    let date: Date?
    let checking: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(label(now: context.date))
                .font(NB.mono(11))
                .foregroundStyle(NB.t3)
                .lineLimit(1)
        }
    }

    private func label(now: Date) -> String {
        if checking { return "проверка…" }
        guard let date else { return "" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "проверено \(s) с назад" }
        return "проверено \(s / 60) мин назад"
    }
}

struct MainPage: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 0) {
                hero.reveal(0)
                latency.reveal(1)
                SectionLabel(title: "Сервисы").overlay(alignment: .bottomTrailing) {
                    SinceText(date: model.lastProbe, checking: model.discord == .checking || model.youtube == .checking)
                        .padding(.trailing, 16)
                        .padding(.bottom, 4)
                }
                .reveal(2)
                ServiceRow(name: "Discord", icon: "bubble.left.and.bubble.right.fill", host: "discord.com:443", health: model.discord, ms: model.discordMs)
                    .reveal(3)
                ServiceRow(name: "YouTube", icon: "play.rectangle.fill", host: "youtube.com:443", health: model.youtube, ms: model.youtubeMs)
                    .reveal(4)
                if model.testing {
                    ActionRow(icon: "flask", title: model.testProgress.isEmpty ? "Идёт тест" : model.testProgress, iconColor: NB.accent, action: { model.page = .more }) {
                        ArcSpinner()
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(NB.t3)
                    }
                    .transition(.textSwap)
                }
                SectionLabel(title: "Конфигурация").reveal(5)
                MenuRow(icon: "arrow.turn.up.right", title: "Стратегия", value: model.strategyName, monoValue: true, enabled: !model.busy) {
                    ForEach(model.strategies, id: \.id) { strategy in
                        Button {
                            model.selectStrategy(strategy.id)
                        } label: {
                            if strategy.id == model.selectedStrategyID {
                                Label(strategy.name, systemImage: "checkmark")
                            } else {
                                Text(strategy.name)
                            }
                        }
                    }
                }
                .reveal(6)
                MenuRow(icon: "square.stack.3d.up", title: "Пресет", value: model.ipsetTitle, enabled: !model.busy) {
                    ForEach(SegmentOption.presets) { option in
                        Button {
                            model.selectIPSet(option.id)
                        } label: {
                            if model.ipsetMode == option.id {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                }
                .reveal(7)
                RowChrome {
                    RowIcon(name: "wifi")
                    Text("Сеть")
                    Spacer(minLength: 8)
                    Text(networkLabel).font(NB.mono(12.5)).foregroundStyle(NB.t2).lineLimit(1)
                }
                .reveal(8)
                RowChrome {
                    RowIcon(name: "point.3.connected.trianglepath.dotted", color: model.hasVpnWarning ? NB.warn : NB.t2)
                    Text("VPN")
                    Spacer(minLength: 8)
                    Text(model.hasVpnWarning ? model.vpnWarning : "не обнаружен")
                        .foregroundStyle(model.hasVpnWarning ? NB.warn : NB.t2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .help(model.vpnWarning)
                .reveal(9)
            }
            .padding(.bottom, 6)
            .animation(Motion.smooth, value: model.testing)
            footer
        }
    }

    private var networkLabel: String {
        let parts = [model.networkInterface, model.networkAddress].filter { !$0.isEmpty }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                MarkView(state: model.phase, size: 16, color: NB.t1)
                Text("Nimbus").font(.system(size: 13, weight: .semibold))
                if !model.appVersion.isEmpty {
                    Text(model.appVersion).font(NB.mono(11.5)).foregroundStyle(NB.t3).padding(.leading, 2)
                }
                Spacer(minLength: 8)
                Button {
                    withAnimation(Motion.smooth) { model.page = .more }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NB.t2)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Ещё")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: NB.headerHeight - 1)
            Hairline()
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                SwapText(text: model.heroTitle, font: NB.hero, color: NB.t1)
                    .frame(height: 24, alignment: .leading)
                SwapText(text: model.heroSubtitle, font: NB.mono(12), color: model.phase == .off ? NB.t3 : NB.t2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                NimbusSwitch(isOn: model.switchOn, large: true, enabled: !model.busy, action: model.performToggle)
                    .help(model.running ? "Выключить (⌘⏎)" : "Включить (⌘⏎)")
                UptimeText(started: model.engineStarted, running: model.running)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var latency: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Задержка · 30 мин").font(.system(size: 11.5)).foregroundStyle(NB.t3)
                Spacer()
                RollingText(text: model.running ? model.latencySummary : "нет данных", font: NB.mono(11.5), color: NB.t2)
            }
            LatencyBars(samples: model.running ? model.latencySamples : [], alert: model.phase == .problem)
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private var footer: some View {
        let status = model.footerStatus
        return PanelFooter {
            StatusDot(color: status.color, pulsing: status.pulsing)
            SwapText(text: status.text, font: NB.small, color: NB.t2)
        } trailing: {
            if model.phase == .problem && model.findEnabled {
                FooterAction(title: "Подобрать", keys: ["↵"], primary: true, action: model.findAndApply)
                FooterSeparator()
            }
            ActionsFooterButton(model: model)
        }
    }
}

struct ServiceRow: View {
    let name: String
    let icon: String
    let host: String
    let health: ServiceHealth
    let ms: Int?

    var body: some View {
        RowChrome {
            RowIcon(name: icon)
            Text(name)
            Text(host).font(NB.mono(11.5)).foregroundStyle(NB.t3).lineLimit(1)
            Spacer(minLength: 8)
            value
            Circle().fill(health.color).frame(width: 6, height: 6)
                .animation(Motion.snappy, value: health)
        }
    }

    @ViewBuilder
    private var value: some View {
        switch health {
        case .ok:
            HStack(spacing: 0) {
                RollingText(text: ms.map(String.init) ?? "—", font: NB.mono(12.5), color: NB.t1)
                Text(" ms").font(NB.mono(12.5)).foregroundStyle(NB.t3)
            }
        case .bad:
            Text("timeout").font(NB.mono(12.5)).foregroundStyle(NB.warn)
        case .checking:
            Text("— ms").font(NB.mono(12.5)).foregroundStyle(NB.t3)
        default:
            Text("—").font(NB.mono(12.5)).foregroundStyle(NB.t3)
        }
    }
}

// MARK: - Ещё

struct MorePage: View {
    @ObservedObject var model: HUDModel

    private func visible(_ title: String) -> Bool {
        let q = model.moreQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || title.lowercased().contains(q)
    }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader(model: model, title: "Ещё")
            VStack(spacing: 0) {
                PanelInput(placeholder: "Поиск действий…", text: $model.moreQuery, trailing: {
                    Button { model.openPalette() } label: { Keycap("⌘", "K") }.buttonStyle(.plain)
                })
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .reveal(0)

                if model.hasTestPanel {
                    TestPanel(model: model)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                        .transition(.textSwap)
                }

                actions
                sections
                settings
            }
            .padding(.bottom, 6)
            .animation(Motion.smooth, value: model.moreQuery)
            .animation(Motion.smooth, value: model.hasTestPanel)
            PanelFooter {
                Text(footerVersion).font(NB.mono(11.5))
            } trailing: {
                ActionsFooterButton(model: model)
            }
        }
    }

    private var footerVersion: String {
        let v = model.appVersion.isEmpty ? model.versionTitle : model.appVersion
        return "\(v) · Flowseal · bol-van/zapret"
    }

    @ViewBuilder
    private var actions: some View {
        let showFind = visible(model.findTitle) || visible("подобрать")
        let showTest = visible(model.testTitle) || visible("тест")
        let showLists = visible("Обновить списки")
        let showRestart = model.running && visible("Перезапустить движок")
        if showFind || showTest || showLists || showRestart {
            SectionLabel(title: "Действия").reveal(1)
            if showFind {
                ActionRow(icon: "bolt", title: model.findTitle,
                          iconColor: model.testing && model.testIsSmart ? NB.warn : NB.t2,
                          enabled: model.findEnabled, action: model.findAndApply) {
                    Keycap("⌘", "F")
                }
                .reveal(2)
            }
            if showTest {
                ActionRow(icon: "flask", title: model.testTitle,
                          iconColor: model.testing && !model.testIsSmart ? NB.warn : NB.t2,
                          enabled: model.fullTestEnabled, action: model.testStrategies) {
                    MetaText(text: "\(model.strategies.count) стратегий")
                    Keycap("⌘", "T")
                }
                .reveal(3)
                if !model.testing {
                    PanelInput(placeholder: "Доп. домен для проверки", text: $model.extraHost, icon: "globe", mono: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .reveal(4)
                }
            }
            if showLists {
                ActionRow(icon: "arrow.triangle.2.circlepath", title: model.updatingLists ? "Обновление списков…" : "Обновить списки",
                          enabled: model.canUpdateLists, action: model.updateLists) {
                    if model.updatingLists { ArcSpinner() }
                    Keycap("⌘", "U")
                }
                .reveal(5)
            }
            if showRestart {
                ActionRow(icon: "power", title: "Перезапустить движок", enabled: !model.busy, action: model.restartService) {
                    Keycap("⌘", "R")
                }
                .reveal(6)
            }
        }
    }

    @ViewBuilder
    private var sections: some View {
        let showLists = visible("Списки")
        let showDiag = visible("Диагностика")
        let showLogs = visible("Логи")
        if showLists || showDiag || showLogs {
            SectionLabel(title: "Разделы").reveal(7)
            if showLists {
                ActionRow(icon: "list.bullet", title: "Списки", action: model.openLists) {
                    if !model.lists.isEmpty { MetaText(text: "\(model.lists.count)") }
                    Keycap("⌘", "L")
                }
                .reveal(8)
            }
            if showDiag {
                ActionRow(icon: "waveform.path.ecg", title: "Диагностика", action: model.openDiagnostics) {
                    if model.diagnostics.contains(where: \.isFail) {
                        Circle().fill(NB.err).frame(width: 6, height: 6)
                    } else if model.diagnostics.contains(where: \.isWarn) || model.hasVpnWarning {
                        Circle().fill(NB.warn).frame(width: 6, height: 6)
                    }
                    Keycap("⌘", "D")
                }
                .reveal(9)
            }
            if showLogs {
                ActionRow(icon: "terminal", title: "Логи", action: model.openLogs) {
                    Keycap("⌘", "J")
                }
                .reveal(10)
            }
        }
    }

    @ViewBuilder
    private var settings: some View {
        let showLogin = visible("Открывать при входе") || visible("автозапуск")
        let showPause = visible("Автопауза при VPN")
        let showUpdate = (model.canInstallUpdate || model.updating) && visible("Обновить")
        let showGit = visible("GitHub")
        let showQuit = visible("Выйти")
        if showLogin || showPause || showUpdate || showGit || showQuit {
            SectionLabel(title: "Параметры").reveal(11)
            if showLogin {
                SwitchRow(icon: "rectangle.portrait.and.arrow.right", title: "Открывать при входе", isOn: model.loginEnabled, action: model.toggleLogin)
                    .reveal(12)
            }
            if showPause {
                SwitchRow(icon: "pause", title: "Автопауза при VPN", isOn: model.autoPauseVpn, action: model.toggleAutoPause)
                    .reveal(13)
            }
            if showUpdate {
                ActionRow(icon: "arrow.down.to.line", title: model.updating ? "Установка…" : model.versionTitle,
                          enabled: model.canInstallUpdate && !model.updating, action: model.installUpdate) {
                    if model.updating { ArcSpinner() } else { Tag(text: "новое", accent: true) }
                }
                .reveal(14)
            }
            if showGit {
                ActionRow(icon: "arrow.up.right", title: "GitHub", action: model.openGitHub)
                    .reveal(15)
            }
            if showQuit {
                ActionRow(icon: "xmark", title: "Выйти из Nimbus", action: model.quit) {
                    Keycap("⌘", "Q")
                }
                .reveal(16)
            }
        }
    }
}

struct SwitchRow: View {
    let icon: String
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RowIcon(name: icon)
            Text(title)
            Spacer(minLength: 8)
            NimbusSwitch(isOn: isOn, action: action)
        }
        .buttonStyle(RowButtonStyle())
    }
}

struct TestPanel: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.testProgress.isEmpty {
                HStack(spacing: 8) {
                    if model.testing { ArcSpinner() }
                    RollingText(text: model.testProgress, font: NB.mono(11.5), color: NB.t2)
                    Spacer(minLength: 0)
                }
            }
            if model.testing {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(NB.line2)
                        Capsule().fill(NB.accent)
                            .frame(width: max(4, geo.size.width * model.testFraction))
                    }
                }
                .frame(height: 2)
                .animation(Motion.smooth, value: model.testFraction)
            }
            if !model.testRows.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.testRows.enumerated()), id: \.element.id) { index, row in
                            Button {
                                model.applyTestRow(row.name)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(row.name)
                                        .font(NB.mono(12))
                                        .foregroundStyle(row.isBest ? NB.t1 : NB.t2)
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    RollingText(text: row.score, font: NB.mono(12, weight: row.isBest ? .semibold : .regular), color: row.isBest ? NB.accent : NB.t2)
                                    if row.isBest {
                                        Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(NB.accent)
                                    }
                                }
                                .frame(height: 22)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.testing || model.busy)
                            .reveal(index)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
            if !model.testBest.isEmpty {
                Text(model.testBest)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NB.t1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.applyBestEnabled {
                PanelButton(title: model.applyBestTitle, primary: true, height: 28, enabled: !model.busy, action: model.applyBest)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NB.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(NB.line, lineWidth: 1))
    }
}

// MARK: - Логи

struct LogsPage: View {
    @ObservedObject var model: HUDModel
    @FocusState private var filterFocused: Bool

    var body: some View {
        let lines = model.visibleLogLines
        VStack(spacing: 0) {
            SubHeader(model: model, title: "Логи") {
                Segmented(options: [
                    SegmentOption(id: "all", title: "Все"),
                    SegmentOption(id: "nimbus", title: "nimbus"),
                    SegmentOption(id: "engine", title: "engine"),
                ], selection: $model.logSource)
            }
            PanelInput(placeholder: "Фильтр", text: $model.logQuery, icon: "line.3.horizontal.decrease", trailing: {
                if model.logQuery.isEmpty {
                    Text("level:wrn+").font(NB.mono(11)).foregroundStyle(NB.t3)
                }
            })
            .focused($filterFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .reveal(0)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if lines.isEmpty {
                            Text(model.logLines.isEmpty ? "Лог пуст" : "Нет совпадений")
                                .font(NB.mono(11))
                                .foregroundStyle(NB.t3)
                                .padding(.horizontal, 16)
                                .frame(height: 24)
                        }
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            LogRow(line: line, query: model.logQuery)
                                .id(line.id)
                                .reveal(max(0, index - max(0, lines.count - 18)))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 10)
                    .textSelection(.enabled)
                }
                .frame(height: 340)
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: lines.count) { _, _ in
                    withAnimation(Motion.smooth) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            PanelFooter {
                Text("\(LogParser.groupThousands(lines.count)) строк").font(NB.mono(11.5))
            } trailing: {
                FooterAction(title: "Копировать", keys: ["⌘", "C"], primary: true, action: model.copyLogs)
                FooterSeparator()
                ActionsFooterButton(model: model)
            }
        }
        .background {
            // "/" focuses the filter
            Button("") { filterFocused = true }
                .keyboardShortcut("/", modifiers: [])
                .disabled(filterFocused)
                .opacity(0)
        }
    }
}

struct LogRow: View {
    let line: LogLine
    var query = ""

    private var levelColor: Color {
        switch line.level {
        case "WRN": return NB.warn
        case "ERR": return NB.err
        default: return NB.t3
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(line.time).foregroundStyle(NB.t3).frame(width: 58, alignment: .leading)
            Text(line.level).foregroundStyle(levelColor).frame(width: 22, alignment: .leading)
            Text(line.source).foregroundStyle(NB.t2).frame(width: 44, alignment: .leading)
            Text(line.text)
                .foregroundStyle(line.level == "INF" ? NB.t1 : levelColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(NB.mono(11))
        .frame(height: 19)
        .padding(.horizontal, 16)
        .help(line.text)
    }
}

// MARK: - Списки

struct ListsPage: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(spacing: 0) {
            SubHeader(model: model, title: "Списки")
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    PanelInput(placeholder: "домен или IP", text: $model.listInput, icon: nil, mono: true, onSubmit: {
                        if model.canSubmitList { model.addBypass() }
                    })
                    PanelButton(title: "Обход", primary: true, keys: ["⏎"], height: 32, enabled: model.canSubmitList, action: model.addBypass)
                    PanelButton(title: "Исключить", height: 32, enabled: model.canSubmitList, action: model.addExclude)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .reveal(0)

                if !model.userEntries.isEmpty {
                    SectionLabel(title: "Мои домены", trailing: "\(model.userEntries.count)").reveal(1)
                    ForEach(Array(model.userEntries.enumerated()), id: \.element.id) { index, entry in
                        RowChrome {
                            Text(entry.value).font(NB.mono(12.5)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Tag(text: entry.badge, accent: entry.isBypass)
                            Button {
                                withAnimation(Motion.smooth) { model.removeUserEntry(entry) }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(NB.t3)
                                    .frame(width: 16, height: 16)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.busy)
                            .help("Удалить")
                        }
                        .transition(.textSwap)
                        .reveal(2 + index)
                    }
                }

                SectionLabel(title: "Списки").reveal(2 + model.userEntries.count)
                ForEach(Array(model.lists.enumerated()), id: \.element.id) { index, item in
                    Button {
                        model.openList(item.id)
                    } label: {
                        RowIcon(name: item.external ? "arrow.up.right.square" : "doc")
                        Text(item.title).font(NB.mono(12.5)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        if !item.badge.isEmpty { MetaText(text: item.badge) }
                        RollingText(text: LogParser.groupThousands(item.lines), font: NB.mono(12.5), color: NB.t2)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(NB.t3)
                    }
                    .buttonStyle(RowButtonStyle())
                    .help(item.detail)
                    .reveal(3 + model.userEntries.count + index)
                }
            }
            .padding(.bottom, 6)
            .animation(Motion.smooth, value: model.userEntries)
            PanelFooter {
                Text("\(LogParser.groupThousands(model.lists.reduce(0) { $0 + $1.lines })) записей").font(NB.mono(11.5))
            } trailing: {
                ActionsFooterButton(model: model)
            }
        }
    }
}

// MARK: - Редактор

struct EditorPage: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(spacing: 0) {
            SubHeader(model: model, title: model.editorName.isEmpty ? model.editorTitle : model.editorName, monoTitle: true) {
                if model.editorDirty {
                    HStack(spacing: 6) {
                        Circle().fill(NB.accent).frame(width: 6, height: 6)
                        Text("изменён").font(NB.small).foregroundStyle(NB.t2)
                    }
                    .transition(.textSwap)
                }
            }
            .animation(Motion.snappy, value: model.editorDirty)
            LineNumberedEditor(text: $model.editorText, caret: $model.editorCaret)
                .frame(height: 380)
                .reveal(0)
            PanelFooter {
                Text("Ln \(model.editorCaret.line), Col \(model.editorCaret.column)").font(NB.mono(11.5)).monospacedDigit()
            } trailing: {
                FooterAction(title: "Отмена", keys: ["esc"]) {
                    model.editorText = model.editorOriginal
                    withAnimation(Motion.smooth) { model.goBack() }
                }
                FooterSeparator()
                FooterAction(title: "Сохранить", keys: ["⌘", "S"], primary: true, enabled: !model.busy && model.editorDirty) {
                    model.saveList()
                    model.editorOriginal = model.editorText
                }
            }
        }
    }
}

/// NSTextView with a gutter: mono 12, dimmed comments and TLDs, current line highlight, caret reporting.
struct LineNumberedEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var caret: EditorCaret

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor.nimbus(light: NSColor(hex: 0x17181B), dark: NSColor(hex: 0xEDEEF0))
        textView.insertionPointColor = NSColor.nimbus(light: NSColor(hex: 0x5E6AD2), dark: NSColor(hex: 0x7C84FF))
        textView.textContainerInset = NSSize(width: 4, height: 8)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 20
        paragraph.maximumLineHeight = 20
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes[.paragraphStyle] = paragraph
        textView.string = text
        let ruler = LineNumberRuler(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.restyle(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.restyle(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LineNumberedEditor

        init(_ parent: LineNumberedEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            restyle(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let location = textView.selectedRange().location
            let prefix = (textView.string as NSString).substring(to: min(location, (textView.string as NSString).length))
            let lines = prefix.components(separatedBy: "\n")
            let caret = EditorCaret(line: lines.count, column: (lines.last?.count ?? 0) + 1)
            if caret != parent.caret {
                DispatchQueue.main.async { self.parent.caret = caret }
            }
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        /// Comments go tertiary, the trailing TLD secondary, everything else primary.
        func restyle(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let string = storage.string as NSString
            let t1 = NSColor.nimbus(light: NSColor(hex: 0x17181B), dark: NSColor(hex: 0xEDEEF0))
            let t2 = NSColor.nimbus(light: NSColor(hex: 0x686C74), dark: NSColor(hex: 0x8A8F98))
            let t3 = NSColor.nimbus(light: NSColor(hex: 0x9A9DA4), dark: NSColor(hex: 0x5B5F67))
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: t1, range: NSRange(location: 0, length: string.length))
            string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
                let line = string.substring(with: range)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") {
                    storage.addAttribute(.foregroundColor, value: t3, range: range)
                } else if let dot = line.range(of: ".", options: .backwards) {
                    let tld = NSRange(dot, in: line)
                    if tld.location != NSNotFound, line[dot.upperBound...].allSatisfy(\.isLetter), !line[dot.upperBound...].isEmpty {
                        storage.addAttribute(.foregroundColor, value: t2, range: NSRange(location: range.location + tld.location, length: range.length - tld.location))
                    }
                }
            }
            storage.endEditing()
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}

final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func refresh() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let string = textView.string as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let t2 = NSColor.nimbus(light: NSColor(hex: 0x686C74), dark: NSColor(hex: 0x8A8F98))
        let t3 = NSColor.nimbus(light: NSColor(hex: 0x9A9DA4), dark: NSColor(hex: 0x5B5F67))
        let caretLocation = textView.selectedRange().location
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var lineNumber = 1
        if chars.location > 0 {
            lineNumber += string.substring(to: chars.location).filter { $0 == "\n" }.count
        }
        var index = chars.location
        let inset = textView.textContainerInset.height
        let relative = convert(NSPoint.zero, from: textView)
        while index <= NSMaxRange(chars) {
            let lineRange = string.lineRange(for: NSRange(location: min(index, max(0, string.length - 1)), length: 0))
            let glyphRange = layout.glyphRange(forCharacterRange: NSRange(location: lineRange.location, length: 0), actualCharacterRange: nil)
            var lineRect = layout.lineFragmentRect(forGlyphAt: min(glyphRange.location, max(0, layout.numberOfGlyphs - 1)), effectiveRange: nil)
            if string.length == 0 { lineRect = NSRect(x: 0, y: 0, width: 0, height: 20) }
            let current = caretLocation >= lineRange.location && (caretLocation < NSMaxRange(lineRange) || NSMaxRange(lineRange) == string.length)
            let label = "\(lineNumber)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: current ? t2 : t3]
            let size = label.size(withAttributes: attrs)
            let y = relative.y + lineRect.minY + inset + (lineRect.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - 12 - size.width, y: y), withAttributes: attrs)
            lineNumber += 1
            let next = NSMaxRange(lineRange)
            if next <= index || next > string.length || lineRange.length == 0 { break }
            index = next
            if index == string.length { break }
        }
    }
}

// MARK: - Диагностика

struct DiagnosticsPage: View {
    @ObservedObject var model: HUDModel

    private var okCount: Int { model.diagnostics.filter { !$0.isFail && !$0.isWarn }.count }
    private var warnCount: Int { model.diagnostics.filter(\.isWarn).count }
    private var failCount: Int { model.diagnostics.filter(\.isFail).count }
    private static let skeletonWidths: [CGFloat] = [96, 84, 52, 70, 76, 60]

    var body: some View {
        VStack(spacing: 0) {
            SubHeader(model: model, title: "Диагностика") {
                PanelButton(title: "Повторить", keys: ["⌘", "R"], height: 24, enabled: !model.diagnosticsRunning, action: model.openDiagnostics)
            }
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    counter(okCount, "в норме", NB.accent)
                    counter(warnCount, "внимание", NB.warn)
                    counter(failCount, "ошибка", NB.err)
                    Spacer(minLength: 8)
                    if model.diagnosticsRunning {
                        ArcSpinner()
                    } else if model.diagnosticsElapsed > 0 {
                        RollingText(text: String(format: "%.2f s", model.diagnosticsElapsed), font: NB.mono(11), color: NB.t3)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)
                .reveal(0)

                if model.diagnosticsRunning && model.diagnostics.isEmpty {
                    ForEach(0..<6, id: \.self) { i in
                        SkeletonRow(width: Self.skeletonWidths[i]).reveal(1 + i)
                    }
                } else {
                    VStack(spacing: 2) {
                        ForEach(Array(model.diagnostics.enumerated()), id: \.element.id) { index, item in
                            DiagnosticRow(item: item, index: index, epoch: model.openEpoch)
                        }
                    }
                }
                if !model.diagnosticText.isEmpty && model.diagnostics.isEmpty && !model.diagnosticsRunning {
                    Text(model.diagnosticText)
                        .font(NB.mono(11))
                        .foregroundStyle(NB.t2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 8)
            .animation(Motion.smooth, value: model.diagnosticsRunning)
            PanelFooter {
                Text(SystemInfo.summary)
            } trailing: {
                FooterAction(title: "Скопировать отчёт", keys: ["⌘", "C"], primary: true, enabled: !model.diagnosticText.isEmpty, action: model.copyDiagnostics)
            }
        }
    }

    private func counter(_ value: Int, _ title: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            RollingText(text: model.diagnosticsRunning && model.diagnostics.isEmpty ? "–" : "\(value)", font: NB.mono(12), color: NB.t1)
            Text(title).font(NB.small).foregroundStyle(NB.t2).lineLimit(1)
        }
        .fixedSize()
    }
}

struct SkeletonRow: View {
    let width: CGFloat
    @State private var dim = false

    var body: some View {
        HStack(spacing: 10) {
            ArcSpinner()
            RoundedRectangle(cornerRadius: 3).fill(NB.line2).frame(width: width, height: 8)
            Spacer()
            RoundedRectangle(cornerRadius: 3).fill(NB.line).frame(width: 64, height: 8)
        }
        .opacity(dim ? 0.55 : 1)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .padding(.horizontal, 6)
        .onAppear {
            guard !Motion.reduce else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
        }
    }
}

/// Each check starts as a spinner and resolves into its icon, one after another.
struct DiagnosticRow: View {
    let item: DiagnosticItem
    let index: Int
    let epoch: Int
    @State private var resolved = false

    private var color: Color { item.isFail ? NB.err : item.isWarn ? NB.warn : NB.accent }
    private var icon: String { item.isFail ? "xmark.circle" : item.isWarn ? "exclamationmark.triangle" : "checkmark" }

    /// "Name: detail · hint" → (value on the right, optional second line)
    private var parts: (value: String, more: String) {
        let pieces = item.detail.components(separatedBy: "\n")
        let first = pieces.first ?? ""
        let rest = pieces.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if rest.isEmpty, (item.isFail || item.isWarn), first.count > 34 {
            return ("", first)
        }
        return (first, rest)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                ZStack {
                    if resolved {
                        RowIcon(name: icon, color: color)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    } else {
                        ArcSpinner().transition(.opacity)
                    }
                }
                .frame(width: 16, height: 16)
                Text(item.name).font(NB.body)
                Spacer(minLength: 8)
                Text(parts.value).font(NB.mono(12)).foregroundStyle(NB.t2).lineLimit(1).truncationMode(.middle)
            }
            if !parts.more.isEmpty {
                Text(parts.more)
                    .font(item.isFail ? NB.mono(12) : NB.small)
                    .foregroundStyle(NB.t2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(item.isFail || item.isWarn ? NB.raised : Color.clear)
        )
        .padding(.horizontal, 6)
        .reveal(index + 1)
        .help(item.detail)
        .onAppear {
            guard !resolved else { return }
            if Motion.reduce {
                resolved = true
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(index) * 0.12) {
                withAnimation(Motion.snappy) { resolved = true }
            }
        }
    }
}

// MARK: - ⌘K

struct CommandBar: View {
    @ObservedObject var model: HUDModel
    @FocusState private var focused: Bool

    /// Rows are 30 pt, group headers 26 pt; capped so the bar never covers the whole panel.
    static func listHeight(_ items: [PaletteItem]) -> CGFloat {
        guard !items.isEmpty else { return 40 }
        var groups = 0
        var last = ""
        for item in items where item.group != last {
            groups += 1
            last = item.group
        }
        return min(300, CGFloat(items.count) * 30 + CGFloat(groups) * 26 + 10)
    }

    var body: some View {
        let items = model.filteredPalette
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if items.isEmpty {
                            Text("Ничего не найдено")
                                .font(NB.small)
                                .foregroundStyle(NB.t3)
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                        }
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || items[index - 1].group != item.group {
                                Text(item.group)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(NB.t3)
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 5)
                                    .frame(height: 26, alignment: .bottom)
                            }
                            PaletteRow(item: item, query: model.paletteQuery, selected: index == model.paletteIndex)
                                .id(item.id)
                                .onTapGesture { model.runPalette(index) }
                                .onHover { if $0 { model.paletteIndex = index } }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                }
                .frame(height: Self.listHeight(items))
                .onChange(of: model.paletteIndex) { _, newValue in
                    guard items.indices.contains(newValue) else { return }
                    proxy.scrollTo(items[newValue].id)
                }
            }
            Hairline()
            HStack(spacing: 8) {
                RowIcon(name: "magnifyingglass", color: NB.t3)
                TextField("", text: $model.paletteQuery, prompt: Text("Поиск действий…").foregroundColor(NB.t3))
                    .textFieldStyle(.plain)
                    .font(NB.body)
                    .focused($focused)
                    .onChange(of: model.paletteQuery) { _, _ in model.paletteIndex = 0 }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
        }
        .frame(width: 300)
        .background(NB.solid)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(NB.line2, lineWidth: 1))
        .background(ShapeShadow(cornerRadius: 10, layers: [.init(opacity: 0.35, radius: 18, y: 12)]))
        .animation(Motion.snappy, value: model.paletteQuery)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

struct PaletteRow: View {
    let item: PaletteItem
    let query: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            RowIcon(name: item.icon, color: selected ? NB.t1 : NB.t2)
            highlighted
                .lineLimit(1)
            Spacer(minLength: 8)
            if item.checked {
                RowIcon(name: "checkmark", color: NB.accent)
            } else if !item.keys.isEmpty {
                Keycap(keys: item.keys)
            }
        }
        .font(NB.body)
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? NB.sel : Color.clear)
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.08), value: selected)
    }

    /// Matched part of the title in primary semibold, the rest secondary.
    private var highlighted: Text {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let range = item.title.range(of: q, options: .caseInsensitive) else {
            return Text(item.title).foregroundColor(q.isEmpty ? NB.t1 : NB.t2)
        }
        return Text(item.title[..<range.lowerBound]).foregroundColor(NB.t2)
            + Text(item.title[range]).foregroundColor(NB.t1).fontWeight(.semibold)
            + Text(item.title[range.upperBound...]).foregroundColor(NB.t2)
    }
}
