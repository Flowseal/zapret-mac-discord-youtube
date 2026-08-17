import SwiftUI

struct IPSetView: View {
    @EnvironmentObject private var service: ZapretService

    var body: some View {
        SettingsPane {
            Section {
                SettingsHeader(
                    title: "IPSet",
                    subtitle: SidebarItem.ipset.subtitle,
                    systemImage: SidebarItem.ipset.symbol,
                    iconColor: SidebarItem.ipset.iconColor
                )
            }

            Section {
                Picker("Режим", selection: ipSetSelection) {
                    ForEach(IPSetMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(service.isBusy || service.isTesting)
            } header: {
                Text("Режим работы")
            } footer: {
                Text("После редактирования списков ipset выберите режим заново, чтобы перезапустить сервис.")
            }

            Section {
                ForEach(IPSetMode.allCases) { mode in
                    LabeledContent(mode.title) {
                        Text(mode.subtitle)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("Описание")
            }
        }
    }

    private var ipSetSelection: Binding<IPSetMode> {
        Binding(
            get: { service.selectedIPSetMode },
            set: { service.selectIPSetMode($0) }
        )
    }
}
