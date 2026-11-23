import AppKit
import QuartzCore
import SwiftUI

let nimbusBlue = Color(red: 10 / 255, green: 132 / 255, blue: 1)
let nimbusNSBlue = NSColor(srgbRed: 10 / 255, green: 132 / 255, blue: 1, alpha: 1)

enum ServiceHealth {
    case off, unknown, checking, ok, bad

    var color: Color {
        switch self {
        case .ok: return Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
        case .bad: return Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)
        case .checking: return nimbusBlue
        default: return Color.secondary.opacity(0.55)
        }
    }
}

enum HUDPage: String {
    case main, more, logs, lists, editor, diagnostics
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
}

final class HUDModel: ObservableObject {
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
    @Published var canInstallUpdate = false
    @Published var page: HUDPage = .main
    @Published var testTitle = "Тест стратегий"
    @Published var testEnabled = true
    @Published var testProgress = ""
    @Published var testRows: [TestRow] = []
    @Published var testBest = ""
    @Published var applyBestEnabled = false
    @Published var discord: ServiceHealth = .unknown
    @Published var youtube: ServiceHealth = .unknown
    @Published var logs = ""
    @Published var lists: [ListInfo] = []
    @Published var editorName = ""
    @Published var editorTitle = ""
    @Published var editorText = ""
    @Published var notice = ""
    @Published var noticeError = false
    @Published var vpnWarning = ""
    @Published var autoPauseVpn = false
    @Published var listInput = ""
    @Published var extraHost = ""
    @Published var userEntries: [UserEntry] = []
    @Published var diagnostics: [DiagnosticItem] = []
    @Published var diagnosticText = ""
    @Published var updatingLists = false
    @Published var testIsSmart = false

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

    var applyBestTitle: String {
        if let name = testRows.first(where: \.isBest)?.name {
            return "Применить \(name)"
        }
        return "Применить лучшую"
    }

    func goBack() {
        switch page {
        case .editor: page = .lists
        case .logs, .lists, .diagnostics: page = .more
        case .more: page = .main
        case .main: break
        }
    }
}

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class HUDController {
    private let model: HUDModel
    private let panel: HUDPanel
    private let hosting: NSHostingController<NimbusHUDView>
    private var monitor: Any?
    private var localMonitor: Any?
    private weak var statusButton: NSStatusBarButton?

    init(model: HUDModel) {
        self.model = model
        hosting = NSHostingController(rootView: NimbusHUDView(model: model))
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 280),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.contentViewController = hosting
    }

    var isVisible: Bool { panel.isVisible }

    func toggle(relativeTo button: NSStatusBarButton) {
        if panel.isVisible {
            close()
        } else {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        statusButton = button
        model.onShown()
        relayout(animated: false)
        panel.alphaValue = 0
        if !MotionSettings.reduceMotion, let layer = hosting.view.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let frame = hosting.view.frame
            layer.anchorPoint = CGPoint(x: 0.5, y: 1)
            layer.position = CGPoint(x: frame.midX, y: frame.maxY)
            layer.transform = CATransform3DConcat(
                CATransform3DMakeTranslation(0, 6, 0),
                CATransform3DMakeScale(0.97, 0.97, 1)
            )
            CATransaction.commit()
        }
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MotionSettings.reduceMotion ? 0.12 : 0.20
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
            hosting.view.layer?.transform = CATransform3DIdentity
        }
        startMonitors()
    }

    func relayout() {
        relayout(animated: true)
    }

    func relayout(animated: Bool) {
        guard let button = statusButton else { return }
        hosting.view.layoutSubtreeIfNeeded()
        var size = hosting.view.fittingSize
        if size.width < 280 { size.width = 292 }
        if size.height < 180 { size.height = 240 }
        if size.height > 560 { size.height = 560 }
        guard let buttonWindow = button.window else {
            panel.setContentSize(size)
            return
        }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? buttonRect
        var x = buttonRect.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = buttonRect.minY - size.height - 6
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        if animated, panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = MotionSettings.reduceMotion ? 0.12 : 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    func close() {
        stopMonitors()
        let finish = {
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.hosting.view.layer?.transform = CATransform3DIdentity
            if !self.model.testing {
                self.model.page = .main
            }
        }
        if !panel.isVisible {
            finish()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            panel.animator().alphaValue = 0
        }, completionHandler: finish)
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
    }

    private func stopMonitors() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        monitor = nil
        localMonitor = nil
    }

    private func closeIfOutside(_ event: NSEvent) {
        guard panel.isVisible else { return }
        if event.window === panel { return }
        if event.window?.level == .popUpMenu { return }
        if let button = statusButton, event.window === button.window { return }
        let loc = NSEvent.mouseLocation
        if panel.frame.contains(loc) { return }
        if let button = statusButton, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            if rect.contains(loc) { return }
        }
        close()
    }
}

struct NimbusHUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.notice.isEmpty {
                noticeBanner
                    .padding(.bottom, 8)
            }
            pageContent
                .id(model.page)
                .transition(pageTransition)
        }
        .animation(pageAnimation, value: model.page)
        .padding(12)
        .frame(width: 276)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .padding(8)
    }

    private var pageAnimation: Animation {
        MotionSettings.reduceMotion
            ? .easeInOut(duration: 0.12)
            : .spring(response: 0.28, dampingFraction: 0.82)
    }

    private var pageTransition: AnyTransition {
        if MotionSettings.reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .offset(x: 14).combined(with: .opacity),
            removal: .offset(x: -14).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private var pageContent: some View {
        switch model.page {
        case .main: mainPage
        case .more: morePage
        case .logs: logsPage
        case .lists: listsPage
        case .editor: editorPage
        case .diagnostics: diagnosticsPage
        }
    }

    private var noticeBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: model.noticeError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.noticeError ? Color.red : nimbusBlue)
            Text(model.notice)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: model.dismissNotice) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            (model.noticeError ? Color.red : nimbusBlue).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            group {
                servicesRow
                hairline
                rowMenu(title: "Стратегия", icon: "slider.horizontal.3", value: model.strategyName) {
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
                hairline
                toggleRow(title: "Автозапуск", icon: "power", isOn: model.loginEnabled, action: model.toggleLogin)
                hairline
                rowMenu(title: "Пресет", icon: "square.stack.3d.up", value: model.ipsetTitle) {
                    presetButton("none", "Нет")
                    presetButton("loaded", "Стандартный")
                    presetButton("any", "Все")
                }
            }

            if model.testing {
                liveTestBanner
            }

            HStack {
                Button {
                    model.page = .more
                } label: {
                    Text("Ещё")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(nimbusBlue)
                Spacer()
                Button("Выход", action: model.quit)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            .padding(.horizontal, 4)
        }
    }

    private var morePage: some View {
        VStack(alignment: .leading, spacing: 10) {
            backButton("Ещё")

            if model.hasTestPanel {
                testPanel
            }

            group {
                settingsRow(
                    model.findTitle,
                    icon: "wand.and.stars",
                    enabled: model.findEnabled,
                    destructive: model.testing && model.testIsSmart,
                    action: model.findAndApply
                )
                hairline
                settingsRow(
                    model.testTitle,
                    icon: "flask",
                    enabled: model.testing ? (model.testEnabled && !model.testIsSmart) : model.testEnabled,
                    destructive: model.testing && !model.testIsSmart,
                    action: model.testStrategies
                )
                if !model.testing {
                    TextField("Доп. домен для проверки", text: Binding(
                        get: { model.extraHost },
                        set: { model.extraHost = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .padding(.vertical, 6)
                    .foregroundStyle(.secondary)
                }
                hairline
                settingsRow(model.updatingLists ? "Обновление списков…" : "Обновить списки", icon: "arrow.triangle.2.circlepath", enabled: !model.busy && !model.testing && !model.updatingLists, action: model.updateLists)
                hairline
                settingsRow("Списки", icon: "list.bullet.rectangle", enabled: true) {
                    model.openLists()
                }
                hairline
                settingsRow("Диагностика", icon: "stethoscope", enabled: true) {
                    model.openDiagnostics()
                }
                hairline
                settingsRow("Логи", icon: "text.alignleft", enabled: true) {
                    model.openLogs()
                }
                if model.running {
                    hairline
                    settingsRow("Перезапустить", icon: "arrow.clockwise", enabled: !model.busy, action: model.restartService)
                }
            }

            group {
                toggleRow(title: "Автопауза при VPN", icon: "pause.circle", isOn: model.autoPauseVpn, action: model.toggleAutoPause)
            }

            group {
                if model.canInstallUpdate || model.updating {
                    settingsRow(
                        model.updating ? "Установка…" : model.versionTitle,
                        icon: "arrow.down.app",
                        enabled: model.canInstallUpdate && !model.updating,
                        action: model.installUpdate
                    )
                    hairline
                }
                settingsRow("GitHub", icon: "link", enabled: true, action: model.openGitHub)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.canInstallUpdate ? "Доступно обновление" : model.versionTitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("На основе Flowseal · bol-van/zapret")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
        }
    }

    private var logsPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                backButton("Логи")
                Spacer()
                Button("Копировать", action: model.copyLogs)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(nimbusBlue)
                    .disabled(model.logs.isEmpty)
            }

            ScrollView {
                Text(model.logs.isEmpty ? "Логов пока нет" : model.logs)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(model.logs.isEmpty ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 280)
            .padding(8)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var listsPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            backButton("Списки")

            group {
                TextField("Домен, ссылка или IP", text: Binding(
                    get: { model.listInput },
                    set: { model.listInput = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.subheadline)
                .padding(.vertical, 8)
                HStack(spacing: 8) {
                    Button("Добавить в обход", action: model.addBypass)
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(nimbusBlue)
                        .disabled(model.busy || model.listInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Исключить", action: model.addExclude)
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .disabled(model.busy || model.listInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.bottom, 8)
            }

            if !model.userEntries.isEmpty {
                group {
                    ForEach(Array(model.userEntries.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.value)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(entry.badge)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Button {
                                model.removeUserEntry(entry)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.busy)
                        }
                        .padding(.vertical, 6)
                        if index < model.userEntries.count - 1 { hairline }
                    }
                }
            }

            group {
                ForEach(Array(model.lists.enumerated()), id: \.element.id) { index, item in
                    Button {
                        model.openList(item.id)
                    } label: {
                        HStack(spacing: 10) {
                            leadingIcon(item.external ? "arrow.up.right" : "pencil")
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(item.title)
                                        .foregroundStyle(.primary)
                                    if !item.badge.isEmpty {
                                        Text(item.badge)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(nimbusBlue)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(nimbusBlue.opacity(0.14), in: Capsule())
                                    }
                                }
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.subheadline)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < model.lists.count - 1 {
                        hairline
                    }
                }
            }
        }
    }

    private var editorPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                backButton(model.editorTitle)
                Spacer()
                Button("Сохранить", action: model.saveList)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(nimbusBlue)
                    .disabled(model.busy)
            }

            TextEditor(text: $model.editorText)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 240)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var diagnosticsPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                backButton("Диагностика")
                Spacer()
                Button("Скопировать отчёт", action: model.copyDiagnostics)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(nimbusBlue)
                    .disabled(model.diagnosticText.isEmpty)
            }
            group {
                ForEach(Array(model.diagnostics.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(item.level == "OK" ? "OK" : (item.isFail ? "FAIL" : "WARN"))
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundStyle(item.isFail ? Color.red : (item.isWarn ? Color.orange : nimbusBlue))
                            .frame(width: 32, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .font(.subheadline)
                            if !item.detail.isEmpty {
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    if index < model.diagnostics.count - 1 { hairline }
                }
            }
        }
    }

    private func backButton(_ title: String) -> some View {
        Button {
            model.goBack()
        } label: {
            Label(title, systemImage: "chevron.left")
                .font(.subheadline.weight(.medium))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(nimbusBlue)
    }

    private var liveTestBanner: some View {
        Button {
            model.page = .more
        } label: {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                Text(model.testProgress.isEmpty ? "Идёт тест" : model.testProgress)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(nimbusBlue.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var testPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.testProgress.isEmpty {
                Text(model.testProgress)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.testing {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(nimbusBlue.opacity(0.16))
                        Capsule()
                            .fill(nimbusBlue)
                            .frame(width: max(6, geo.size.width * model.testFraction))
                    }
                }
                .frame(height: 3)
                .animation(MotionSettings.reduceMotion ? .easeInOut(duration: 0.12) : .easeOut(duration: 0.18), value: model.testFraction)
            }
            if !model.testRows.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.testRows) { row in
                            Button {
                                model.applyTestRow(row.name)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(row.name)
                                        .font(.caption)
                                        .foregroundStyle(row.isBest ? Color.primary : Color.secondary)
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(row.score)
                                        .font(.caption.monospacedDigit().weight(row.isBest ? .semibold : .regular))
                                        .foregroundStyle(row.isBest ? nimbusBlue : Color.secondary)
                                    if row.isBest {
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 8))
                                            .foregroundStyle(nimbusBlue)
                                    }
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.testing || model.busy)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
            if !model.testBest.isEmpty {
                Text(model.testBest)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.applyBestEnabled {
                Button(action: model.applyBest) {
                    Text(model.applyBestTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(nimbusBlue, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var servicesRow: some View {
        HStack(spacing: 0) {
            serviceCell("Discord", model.discord)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1, height: 16)
            serviceCell("YouTube", model.youtube)
        }
        .padding(.vertical, 8)
    }

    private func serviceCell(_ title: String, _ health: ServiceHealth) -> some View {
        ServiceDotCell(title: title, health: health)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                headerCloud
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nimbus")
                        .font(.headline)
                    Text(model.statusTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                        .id(model.statusTitle)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { model.running },
                    set: { _ in model.toggleService() }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(nimbusBlue)
                .labelsHidden()
                .disabled(model.busy)
            }
            if model.hasVpnWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("VPN активен")
                        .font(.caption.weight(.medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .help(model.vpnWarning)
            }
        }
    }

    private var headerCloud: some View {
        ZStack {
            Circle()
                .fill(model.running ? nimbusBlue : Color.primary.opacity(0.18))
                .frame(width: 34, height: 34)
            cloudGlyph
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .animation(.easeInOut(duration: 0.32), value: model.running)
    }

    @ViewBuilder
    private var cloudGlyph: some View {
        let image = Image(systemName: model.running ? "cloud.fill" : "cloud")
        if #available(macOS 14.0, *) {
            image
                .contentTransition(.symbolEffect(.replace))
        } else {
            image
        }
    }

    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .padding(.horizontal, 10)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func rowMenu<Content: View>(title: String, icon: String, value: String, @ViewBuilder content: () -> Content) -> some View {
        ZStack {
            HStack(spacing: 10) {
                leadingIcon(icon)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 108, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .padding(.vertical, 9)

            Menu {
                content()
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .disabled(model.busy)
    }

    @ViewBuilder
    private func presetButton(_ id: String, _ title: String) -> some View {
        Button {
            model.selectIPSet(id)
        } label: {
            if model.ipsetMode == id {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func toggleRow(title: String, icon: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            leadingIcon(icon)
            Text(title)
                .font(.subheadline)
            Spacer()
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { _ in action() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(nimbusBlue)
            .labelsHidden()
        }
        .padding(.vertical, 6)
    }

    private func settingsRow(
        _ title: String,
        icon: String,
        enabled: Bool,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                leadingIcon(icon)
                Text(title)
                    .foregroundStyle(destructive ? Color.red : (enabled ? Color.primary : Color.secondary))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func leadingIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 16)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, 26)
    }
}

private struct ServiceDotCell: View {
    let title: String
    let health: ServiceHealth
    @State private var ping = false

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(health.color)
                    .frame(width: 7, height: 7)
                Circle()
                    .stroke(health.color.opacity(0.45), lineWidth: 1)
                    .frame(width: 7, height: 7)
                    .scaleEffect(ping ? 2.2 : 1)
                    .opacity(ping && health == .ok ? 0 : 0)
            }
            .frame(width: 14, height: 14)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity)
        .onChange(of: health) { _, newValue in
            guard newValue == .ok, !MotionSettings.reduceMotion else {
                ping = false
                return
            }
            ping = false
            withAnimation(.easeOut(duration: 0.42)) { ping = true }
        }
    }
}
