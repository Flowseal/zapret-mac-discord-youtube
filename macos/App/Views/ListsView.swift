import SwiftUI

struct ListsView: View {
    @EnvironmentObject private var service: ZapretService

    private struct ListFile: Identifiable {
        let id: String
        let description: String
        let symbol: String
        let color: Color

        init(_ name: String, _ description: String, _ symbol: String, _ color: Color) {
            self.id = name
            self.description = description
            self.symbol = symbol
            self.color = color
        }
    }

    private let listFiles: [ListFile] = [
        ListFile("list-general.txt", "Основные домены", "globe", SettingsPalette.blue),
        ListFile("list-general-user.txt", "Ваши домены", "person.crop.circle", SettingsPalette.teal),
        ListFile("list-google.txt", "Google и YouTube", "play.rectangle", SettingsPalette.red),
        ListFile("list-exclude.txt", "Исключения", "minus.circle", SettingsPalette.orange),
        ListFile("list-exclude-user.txt", "Ваши исключения", "person.crop.circle.badge.minus", SettingsPalette.orange),
        ListFile("ipset-exclude.txt", "Исключения IP", "network.slash", SettingsPalette.indigo),
        ListFile("ipset-exclude-user.txt", "Ваши IP-исключения", "person.crop.circle.badge.xmark", SettingsPalette.indigo),
        ListFile("ipset-all.txt", "IP-набор для режима Loaded", "list.bullet", SettingsPalette.gray)
    ]

    var body: some View {
        SettingsPane {
            Section {
                SettingsHeader(
                    title: "Списки",
                    subtitle: SidebarItem.lists.subtitle,
                    systemImage: SidebarItem.lists.symbol,
                    iconColor: SidebarItem.lists.iconColor
                )
            }

            Section {
                SettingsActionRow(
                    title: "Открыть папку списков",
                    symbol: "folder",
                    color: SettingsPalette.orange,
                    subtitle: "~/Library/Application Support/ZapretMac/lists"
                ) {
                    service.openListsFolder()
                }
            }

            Section {
                ForEach(listFiles) { file in
                    SettingsValueRow(
                        title: file.id,
                        symbol: file.symbol,
                        color: file.color,
                        value: file.description
                    )
                }
            } header: {
                Text("Файлы")
            } footer: {
                Text("Добавляйте домены по одному на строку. Поддомены учитываются автоматически.")
            }
        }
    }
}
