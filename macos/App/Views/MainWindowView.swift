import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var service: ZapretService
    @EnvironmentObject private var updates: UpdateService
    @State private var selection: SidebarItem? = .dashboard
    @State private var sidebarSearch = ""

    private var activeItem: SidebarItem { selection ?? .dashboard }

    private var filteredSidebarItems: [SidebarItem] {
        guard !sidebarSearch.isEmpty else { return SidebarItem.allCases }
        return SidebarItem.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(sidebarSearch)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filteredSidebarItems, selection: $selection) { item in
                SidebarRow(item: item, hasUpdate: item == .updates && updates.hasUpdate)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .navigationTitle(activeItem.title)
                .navigationSplitViewColumnWidth(
                    min: SettingsMetrics.detailMinWidth,
                    ideal: SettingsMetrics.detailIdealWidth
                )
                .toolbar { serviceToolbar }
        }
        .searchable(text: $sidebarSearch, placement: .sidebar, prompt: "Поиск")
        .background {
            SettingsWindowChrome()
                .allowsHitTesting(false)
        }
        .alert("Ошибка", isPresented: errorBinding) {
            Button("OK", role: .cancel) { service.lastError = nil }
        } message: {
            Text(service.lastError ?? "")
        }
        .alert("Готово", isPresented: infoBinding) {
            Button("OK", role: .cancel) { service.lastInfo = nil }
        } message: {
            Text(service.lastInfo ?? "")
        }
        .alert("Ошибка обновления", isPresented: updateErrorBinding) {
            Button("OK", role: .cancel) { updates.lastError = nil }
        } message: {
            Text(updates.lastError ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch activeItem {
        case .dashboard: DashboardView()
        case .strategies: StrategiesView()
        case .ipset: IPSetView()
        case .lists: ListsView()
        case .testing: TestingView()
        case .updates: UpdatesView()
        }
    }

    @ToolbarContentBuilder
    private var serviceToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
                if service.isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    ServiceStatusLabel(isRunning: service.isRunning)
                        .labelStyle(.iconOnly)
                }

                Button {
                    service.toggleService()
                } label: {
                    Label(
                        service.isRunning ? "Остановить" : "Запустить",
                        systemImage: service.isRunning ? "stop.fill" : "play.fill"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help(service.isRunning ? "Остановить сервис" : "Запустить сервис")
                .disabled(service.isBusy || service.isTesting)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { service.lastError != nil }, set: { if !$0 { service.lastError = nil } })
    }

    private var infoBinding: Binding<Bool> {
        Binding(get: { service.lastInfo != nil }, set: { if !$0 { service.lastInfo = nil } })
    }

    private var updateErrorBinding: Binding<Bool> {
        Binding(get: { updates.lastError != nil }, set: { if !$0 { updates.lastError = nil } })
    }
}

private struct SidebarRow: View {
    let item: SidebarItem
    let hasUpdate: Bool

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(item.title)
                Spacer(minLength: 0)
                if hasUpdate {
                    Text("1")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.tint))
                }
            }
        } icon: {
            SettingsIconBadge(
                symbol: item.symbol,
                color: item.iconColor,
                size: SettingsMetrics.sidebarIconSize
            )
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case strategies
    case ipset
    case lists
    case testing
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Обзор"
        case .strategies: "Стратегии"
        case .ipset: "IPSet"
        case .lists: "Списки"
        case .testing: "Тестирование"
        case .updates: "Обновления"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .strategies: "bolt.horizontal"
        case .ipset: "network"
        case .lists: "doc.text"
        case .testing: "checkmark.seal"
        case .updates: "arrow.down.circle"
        }
    }
}
