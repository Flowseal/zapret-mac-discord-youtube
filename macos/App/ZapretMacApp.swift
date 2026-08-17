import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = AppIconProvider.applicationIcon
    }
}

@main
struct ZapretMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var service = ZapretService()
    @StateObject private var updates = UpdateService()
    @State private var bootstrapFailed = false
    @State private var bootstrapError = ""
    @State private var didBootstrap = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenuContent()
                .environmentObject(service)
                .environmentObject(updates)
                .onAppear { performBootstrapIfNeeded() }
        } label: {
            StatusMenuLabel(isRunning: service.isRunning)
        }
        .menuBarExtraStyle(.menu)

        WindowGroup(id: "main") {
            Group {
                if bootstrapFailed {
                    BootstrapErrorView(message: bootstrapError)
                } else {
                    MainWindowView()
                        .environmentObject(service)
                        .environmentObject(updates)
                }
            }
            .frame(minWidth: 680, minHeight: 480)
            .onAppear {
                performBootstrapIfNeeded()
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .defaultSize(width: 900, height: 620)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Сервис") {
                Button(service.isRunning ? "Остановить" : "Запустить") {
                    service.toggleService()
                }
                .disabled(service.isBusy || service.isTesting)
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Открыть списки") {
                    service.openListsFolder()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }

    private func performBootstrapIfNeeded() {
        guard !didBootstrap, !bootstrapFailed else { return }
        didBootstrap = true
        do {
            try service.bootstrap()
            service.showPendingUpdateErrorIfNeeded()
            updates.startPeriodicChecks { service.isRunning }
        } catch {
            bootstrapFailed = true
            bootstrapError = error.localizedDescription
        }
    }
}

struct BootstrapErrorView: View {
    let message: String

    var body: some View {
        SettingsPane {
            Section {
                SettingsHeader(
                    title: "Не удалось запустить",
                    subtitle: "ZapretMac не смог инициализировать окружение.",
                    systemImage: "exclamationmark.triangle.fill",
                    iconColor: SettingsPalette.orange
                )
            }

            Section {
                Text(message)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Button("Закрыть") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}
