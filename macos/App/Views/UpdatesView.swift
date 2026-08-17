import SwiftUI

struct UpdatesView: View {
    @EnvironmentObject private var service: ZapretService
    @EnvironmentObject private var updates: UpdateService

    var body: some View {
        SettingsPane {
            Section {
                SettingsHeader(
                    title: "Обновления",
                    subtitle: SidebarItem.updates.subtitle,
                    systemImage: SidebarItem.updates.symbol,
                    iconColor: SidebarItem.updates.iconColor
                )
            }

            Section {
                if updates.isUpdating {
                    LabeledContent {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Установка…")
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        Label {
                            Text("Статус")
                        } icon: {
                            SettingsIconBadge(symbol: "arrow.down.circle", color: SettingsPalette.blue)
                        }
                    }
                } else if let release = updates.availableRelease {
                    SettingsValueRow(
                        title: "Доступна версия",
                        symbol: "arrow.down.circle.fill",
                        color: SettingsPalette.blue,
                        value: displayVersion(release.tagName)
                    )

                    SettingsActionRow(
                        title: "Установить обновление",
                        symbol: "square.and.arrow.down",
                        color: SettingsPalette.blue
                    ) {
                        updates.installUpdate()
                    }
                    .disabled(service.isBusy || service.isTesting)
                } else {
                    SettingsValueRow(
                        title: "Статус",
                        symbol: "checkmark.circle",
                        color: SettingsPalette.green,
                        value: updates.isChecking ? "Проверка…" : "Актуальная версия"
                    )

                    SettingsActionRow(
                        title: "Проверить снова",
                        symbol: "arrow.clockwise",
                        color: SettingsPalette.blue
                    ) {
                        updates.checkForUpdate()
                    }
                    .disabled(updates.isChecking)
                }
            }

            Section {
                SettingsValueRow(
                    title: "Установлено",
                    symbol: "info.circle",
                    value: updates.currentVersion
                )
            } header: {
                Text("Информация")
            }
        }
    }

    private func displayVersion(_ version: String) -> String {
        version.first == "v" || version.first == "V" ? String(version.dropFirst()) : version
    }
}
