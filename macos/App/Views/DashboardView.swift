import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var service: ZapretService

    var body: some View {
        SettingsPane {
            Section {
                SettingsHeader(
                    title: "ZapretMac",
                    subtitle: "Обход блокировок для Discord, YouTube и других сервисов.",
                    appIcon: AppIconProvider.applicationIcon
                )
            }

            Section {
                SettingsActionRow(
                    title: service.isRunning ? "Остановить сервис" : "Запустить сервис",
                    symbol: service.isRunning ? "stop.fill" : "play.fill",
                    color: service.isRunning ? SettingsPalette.orange : SettingsPalette.green,
                    subtitle: service.isRunning ? "Сервис работает" : "Сервис не запущен"
                ) {
                    service.toggleService()
                }
                .disabled(service.isBusy || service.isTesting)

                SettingsActionRow(
                    title: "Открыть списки",
                    symbol: "folder",
                    color: SettingsPalette.orange,
                    subtitle: "Редактировать домены и IP"
                ) {
                    service.openListsFolder()
                }

                if service.isTesting {
                    SettingsActionRow(
                        title: "Остановить тест",
                        symbol: "stop.fill",
                        color: SettingsPalette.red,
                        isDestructive: true
                    ) {
                        service.cancelStrategyTest()
                    }
                } else {
                    SettingsActionRow(
                        title: "Тест стратегий",
                        symbol: "checkmark.seal",
                        color: SettingsPalette.green,
                        subtitle: "Подобрать лучшую автоматически"
                    ) {
                        service.startStrategyTest()
                    }
                    .disabled(service.isBusy)
                }
            }

            Section {
                SettingsValueRow(
                    title: "Стратегия",
                    symbol: "bolt.horizontal",
                    color: SettingsPalette.blue,
                    value: currentStrategyName
                )
                SettingsValueRow(
                    title: "IPSet",
                    symbol: "network",
                    color: SettingsPalette.indigo,
                    value: service.selectedIPSetMode.title
                )
                SettingsValueRow(
                    title: "Версия",
                    symbol: "info.circle",
                    value: service.currentVersion
                )
            } header: {
                Text("Конфигурация")
            }
        }
    }

    private var currentStrategyName: String {
        service.strategies.first { $0.id == service.selectedStrategyID }?.name ?? "—"
    }
}
