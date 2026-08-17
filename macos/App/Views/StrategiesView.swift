import SwiftUI

struct StrategiesView: View {
    @EnvironmentObject private var service: ZapretService
    @State private var searchText = ""

    private var filteredStrategies: [Strategy] {
        guard !searchText.isEmpty else { return service.strategies }
        return service.strategies.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.id.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        SettingsPane {
            Section {
                SettingsHeader(
                    title: "Стратегии",
                    subtitle: SidebarItem.strategies.subtitle,
                    systemImage: SidebarItem.strategies.symbol,
                    iconColor: SidebarItem.strategies.iconColor
                )
            }

            Section {
                Picker("Активная стратегия", selection: strategySelection) {
                    ForEach(filteredStrategies) { strategy in
                        Text(strategy.name).tag(strategy.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Доступные стратегии")
            } footer: {
                Text("При активном сервисе изменение применится автоматически.")
            }
        }
        .searchable(text: $searchText, prompt: "Поиск стратегии")
    }

    private var strategySelection: Binding<String> {
        Binding(
            get: { service.selectedStrategyID },
            set: { service.selectStrategy($0) }
        )
    }
}
