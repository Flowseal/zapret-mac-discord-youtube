import AppKit
import SwiftUI

enum SettingsMetrics {
    static let detailMinWidth: CGFloat = 480
    static let detailIdealWidth: CGFloat = 580
    static let headerIconSize: CGFloat = 60
    static let rowIconSize: CGFloat = 20
    static let sidebarIconSize: CGFloat = 20
}

struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
    }
}

private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct SettingsIconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = SettingsMetrics.rowIconSize

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(color)
            )
    }
}

struct SettingsPane<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SettingsHeader: View {
    let title: String
    let subtitle: String
    var systemImage: String?
    var iconColor: Color = SettingsPalette.gray
    var appIcon: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            icon
                .padding(.bottom, 4)

            Text(title)
                .font(.title.weight(.semibold))

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var icon: some View {
        if let appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: SettingsMetrics.headerIconSize, height: SettingsMetrics.headerIconSize)
        } else if let systemImage {
            SettingsIconBadge(
                symbol: systemImage,
                color: iconColor,
                size: SettingsMetrics.headerIconSize
            )
        }
    }
}

struct SettingsActionRow: View {
    let title: String
    let symbol: String
    var color: Color = SettingsPalette.blue
    var subtitle: String?
    var isDestructive = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsIconBadge(symbol: symbol, color: color)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(isDestructive ? SettingsPalette.red : Color.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(SettingsRowButtonStyle())
        .opacity(isEnabled ? 1 : 0.4)
    }
}

struct SettingsRowButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor(pressed: configuration.isPressed))
            )
            .padding(.horizontal, -8)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }

    private func fillColor(pressed: Bool) -> Color {
        if pressed {
            return Color.primary.opacity(0.12)
        } else if isHovering {
            return Color.primary.opacity(0.06)
        }
        return .clear
    }
}

struct SettingsValueRow: View {
    let title: String
    let symbol: String
    var color: Color = SettingsPalette.gray
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(.secondary)
        } label: {
            Label {
                Text(title)
            } icon: {
                SettingsIconBadge(symbol: symbol, color: color)
            }
        }
    }
}

struct ServiceStatusLabel: View {
    let isRunning: Bool

    var body: some View {
        Label {
            Text(isRunning ? "Активен" : "Остановлен")
        } icon: {
            Image(systemName: isRunning ? "checkmark.circle.fill" : "pause.circle.fill")
                .foregroundStyle(isRunning ? .green : .orange)
                .symbolRenderingMode(.hierarchical)
        }
        .help(isRunning ? "Активен" : "Остановлен")
    }
}

enum SettingsPalette {
    static let gray = Color(nsColor: .systemGray)
    static let blue = Color(nsColor: .systemBlue)
    static let indigo = Color(nsColor: .systemIndigo)
    static let orange = Color(nsColor: .systemOrange)
    static let green = Color(nsColor: .systemGreen)
    static let red = Color(nsColor: .systemRed)
    static let teal = Color(nsColor: .systemTeal)
    static let purple = Color(nsColor: .systemPurple)
}

extension SidebarItem {
    var subtitle: String {
        switch self {
        case .dashboard: "Статус и быстрые действия"
        case .strategies: "Профили обхода блокировок"
        case .ipset: "IP-профили обхода"
        case .lists: "Домены и IP-адреса"
        case .testing: "Автоподбор стратегии"
        case .updates: "Проверка релизов"
        }
    }

    var iconColor: Color {
        switch self {
        case .dashboard: SettingsPalette.gray
        case .strategies: SettingsPalette.blue
        case .ipset: SettingsPalette.indigo
        case .lists: SettingsPalette.orange
        case .testing: SettingsPalette.green
        case .updates: SettingsPalette.blue
        }
    }
}
