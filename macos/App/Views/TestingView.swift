import SwiftUI

struct TestingView: View {
    @EnvironmentObject private var service: ZapretService
    @State private var showStartConfirmation = false

    var body: some View {
        SettingsPane {
            Section {
                SettingsHeader(
                    title: "Тестирование",
                    subtitle: SidebarItem.testing.subtitle,
                    systemImage: SidebarItem.testing.symbol,
                    iconColor: SidebarItem.testing.iconColor
                )
            }

            Section {
                if service.isTesting {
                    LabeledContent {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(service.isCancellingTest ? "Остановка…" : "Выполняется")
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        Label {
                            Text("Статус")
                        } icon: {
                            SettingsIconBadge(symbol: "hourglass", color: SettingsPalette.green)
                        }
                    }

                    if !service.testProgress.isEmpty {
                        SettingsValueRow(
                            title: "Прогресс",
                            symbol: "chart.bar",
                            color: SettingsPalette.green,
                            value: service.testProgress
                        )
                    }

                    SettingsActionRow(
                        title: "Остановить тест",
                        symbol: "stop.fill",
                        color: SettingsPalette.red,
                        isDestructive: true
                    ) {
                        service.cancelStrategyTest()
                    }
                    .disabled(service.isCancellingTest)
                } else {
                    SettingsActionRow(
                        title: "Запустить тест",
                        symbol: "play.fill",
                        color: SettingsPalette.green,
                        subtitle: "Проверить все стратегии по очереди"
                    ) {
                        showStartConfirmation = true
                    }
                    .disabled(service.isBusy)
                }
            } footer: {
                Text("Тест выполняется в фоне, настройки восстанавливаются после завершения. Отчёт: strategy-test.txt.")
            }
        }
        .confirmationDialog(
            "Запустить тест стратегий?",
            isPresented: $showStartConfirmation,
            titleVisibility: .visible
        ) {
            Button("Запустить") { service.startStrategyTest() }
            Button("Отмена", role: .cancel) {}
        }
    }
}
