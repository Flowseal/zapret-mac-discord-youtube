import AppKit
import SwiftUI

enum MenuBarZIcon {
    static func image(isRunning: Bool, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        NSColor.black.setStroke()

        let inset: CGFloat = size * 0.18
        let thickness: CGFloat = max(2, size * 0.155)
        let topY = size - inset - thickness * 0.5
        let bottomY = inset + thickness * 0.5
        let leftX = inset
        let rightX = size - inset

        func strokeCapsule(from start: NSPoint, to end: NSPoint) {
            let path = NSBezierPath()
            path.lineWidth = thickness
            path.lineCapStyle = .round
            path.move(to: start)
            path.line(to: end)
            path.stroke()
        }

        strokeCapsule(from: NSPoint(x: leftX, y: topY), to: NSPoint(x: rightX, y: topY))
        strokeCapsule(
            from: NSPoint(x: rightX - thickness * 0.15, y: topY),
            to: NSPoint(x: leftX + thickness * 0.15, y: bottomY)
        )
        strokeCapsule(from: NSPoint(x: leftX, y: bottomY), to: NSPoint(x: rightX, y: bottomY))

        if !isRunning {
            let slash = NSBezierPath()
            slash.lineWidth = max(1.8, thickness * 0.85)
            slash.lineCapStyle = .round
            slash.move(to: NSPoint(x: inset * 0.55, y: size - inset * 0.55))
            slash.line(to: NSPoint(x: size - inset * 0.55, y: inset * 0.55))
            slash.stroke()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

enum AppIconProvider {
    static var applicationIcon: NSImage? {
        if let icon = NSImage(named: "AppIcon") {
            return icon
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            return icon
        }
        return NSApp.applicationIconImage
    }

    static func menuBarIcon(isRunning: Bool) -> NSImage {
        MenuBarZIcon.image(isRunning: isRunning)
    }
}

struct StatusMenuLabel: View {
    let isRunning: Bool

    var body: some View {
        Image(nsImage: AppIconProvider.menuBarIcon(isRunning: isRunning))
    }
}

struct MenuBarMenuContent: View {
    @EnvironmentObject private var service: ZapretService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(service.isRunning ? "ZapretMac — активен" : "ZapretMac — остановлен")

        Button(service.isRunning ? "Остановить сервис" : "Запустить сервис") {
            service.toggleService()
        }
        .disabled(service.isBusy || service.isTesting)
        .keyboardShortcut("r", modifiers: [.command, .shift])

        Divider()

        Button("Открыть панель управления") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o", modifiers: .command)

        Button("Открыть списки") {
            service.openListsFolder()
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])

        Divider()

        Button("Выйти из ZapretMac") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
