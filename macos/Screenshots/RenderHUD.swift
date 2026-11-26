// Renders the real NimbusHUDView (macos/App/NimbusHUD.swift) with sample data to PNG.
// Used by .github/workflows/screenshots.yml; not part of the app build.
import AppKit
import SwiftUI

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct Strategy {
    let id: String
    let name: String
}

@main
struct RenderHUD {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "screens"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let strategies = [
            "general", "general (ALT)", "general (ALT2)", "general (ALT3)", "general (ALT4)", "general (SIMPLE FAKE)",
        ].enumerated().map { Strategy(id: "s\($0.offset)", name: $0.element) }

        let spark: [Double] = [64, 61, 66, 70, 62, 58, 63, 67, 72, 69, 64, 60, 57, 59, 63, 71, 88, 76, 66, 62,
                               60, 58, 61, 64, 66, 63, 59, 57, 60, 62, 61, 58, 56, 59, 62, 60, 58, 55, 57, 60]
        func base(_ m: HUDModel) {
            m.strategies = strategies
            m.selectedStrategyID = "s3"
            m.strategyName = "general (ALT3)"
            m.running = true
            m.loginEnabled = true
            m.ipsetMode = "loaded"
            m.discord = .ok
            m.youtube = .ok
            m.discordMs = 42
            m.youtubeMs = 118
            m.latencySamples = spark
            m.lastProbe = Date().addingTimeInterval(-12)
            m.engineStarted = Date().addingTimeInterval(-8076)
            m.networkInterface = "en0"
            m.networkAddress = "192.168.1.24"
            m.vpnNote = "туннель utun4 · не трогаем"
            m.leaveAlone = "203.0.113.7, 10.8.0.0/16"
            m.appVersion = "1.6.0-beta.3"
            m.versionTitle = "Версия 1.6.0-beta.3"
        }
        let logText = """
        11:24:01 запуск utunws · стратегия general (ALT3)
        11:31:44 WARN VPN interface utun3 appeared (WireGuard)
        12:03:12 ERROR desync: fake rejected by 142.250.74.110:443
        12:14:31 discord.com:443 tls ok · 41 ms
        """
        let engineText = """
        11:24:01 pf anchor "nimbus" loaded · 14 rules
        11:24:01 hostlist list-general.txt · 1 240 domains
        12:03:12 fallback split2 · ttl 4
        """

        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let theme = dark ? "dark" : "light"
            shoot("\(out)/macos-\(theme)-main", dark: dark, setup: { m in base(m) })
            shoot("\(out)/macos-\(theme)-main-problem", dark: dark, setup: { m in
                base(m)
                m.youtube = .bad
                m.youtubeMs = nil
            })
            shoot("\(out)/macos-\(theme)-main-off", dark: dark, setup: { m in
                base(m)
                m.running = false
                m.discord = .off
                m.youtube = .off
            })
            shoot("\(out)/macos-\(theme)-more", dark: dark, setup: { m in
                base(m)
                m.page = .more
                m.testRows = [
                    TestRow(name: "general", score: "20/27", isBest: false),
                    TestRow(name: "general (ALT3)", score: "23/27", isBest: true),
                    TestRow(name: "general (ALT4)", score: "ошибка", isBest: false),
                ]
                m.testBest = "Лучшая: general (ALT3) (23/27)"
                m.applyBestEnabled = true
                m.testTitle = "Повторить тест"
            })
            shoot("\(out)/macos-\(theme)-logs", dark: dark, setup: { m in
                base(m)
                m.page = .logs
                m.logLines = LogParser.parse(logText, source: "nimbus") + LogParser.parse(engineText, source: "engine", startID: 100)
            })
            shoot("\(out)/macos-\(theme)-lists", dark: dark, setup: { m in
                base(m)
                m.page = .lists
                m.userEntries = [
                    UserEntry(file: UserListIO.bypassDomains, value: "chatgpt.com"),
                    UserEntry(file: "list-exclude-user.txt", value: "gosuslugi.ru"),
                ]
                m.lists = [
                    ListInfo(id: "list-general.txt", title: "list-general.txt", detail: "", badge: "", external: false, lines: 1240),
                    ListInfo(id: "list-google.txt", title: "list-google.txt", detail: "", badge: "", external: false, lines: 491),
                    ListInfo(id: "ipset-all.txt", title: "ipset-all.txt", detail: "", badge: "", external: true, lines: 52113),
                ]
            })
            shoot("\(out)/macos-\(theme)-editor", dark: dark, setup: { m in
                base(m)
                m.page = .editor
                m.editorName = "list-general.txt"
                m.editorOriginal = "# Nimbus — основной список обхода\n\ndiscord.com\ndiscord.gg\nyoutube.com\n"
                m.editorText = m.editorOriginal + "claude.ai\n"
            })
            shoot("\(out)/macos-\(theme)-diagnostics", dark: dark, setup: { m in
                base(m)
                m.page = .diagnostics
                m.diagnosticsElapsed = 0.84
                m.diagnostics = [
                    DiagnosticItem(level: "OK", name: "Движок utunws", detail: "pid 4182"),
                    DiagnosticItem(level: "OK", name: "Discord", detail: "tcp 443 · 42 ms"),
                    DiagnosticItem(level: "WARN", name: "VPN", detail: "utun3\nТрафик может идти мимо Nimbus — включите автопаузу."),
                    DiagnosticItem(level: "OK", name: "Списки", detail: "обновлены 2 ч назад"),
                ]
                m.diagnosticText = "report"
            })
            shoot("\(out)/macos-\(theme)-cmdk", dark: dark, setup: { m in base(m) }, then: { m in m.openPalette() })
            // window follows the content when pages change while open
            shoot("\(out)/macos-\(theme)-main-to-logs", dark: dark, setup: { m in base(m); m.logLines = LogParser.parse(logText, source: "nimbus") },
                  then: { m in m.page = .logs })
            shoot("\(out)/macos-\(theme)-editor-to-main", dark: dark, setup: { m in
                base(m)
                m.page = .editor
                m.editorName = "list-general.txt"
                m.editorText = "discord.com\n"
            }, then: { m in m.page = .main })
        }
        exit(0)
    }

    /// Opens the real HUDController panel under a fake status item at the top of the main screen,
    /// optionally runs `then` (page switch, ⌘K) and captures the whole window, so the shot shows
    /// exactly what the window size and position give on a real Mac.
    static func shoot(_ path: String, dark: Bool, setup: (HUDModel) -> Void, then: ((HUDModel) -> Void)? = nil) {
        let model = HUDModel()
        setup(model)
        let controller = HUDController(model: model)
        let screen = NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
        let anchor = NSRect(x: visible.midX - 12, y: visible.maxY, width: 24, height: 24)
        NSApp.activate(ignoringOtherApps: true)
        controller.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        controller.show(below: anchor, on: screen)
        // CPU rendering on CI is slow; leave the open animation and row reveals plenty of time to finish
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        if let then {
            then(model)
            RunLoop.current.run(until: Date().addingTimeInterval(2.0))
        }
        let window = controller.window
        guard let content = window.contentView else { return }
        let size = content.bounds.size
        let frame = window.frame
        let topGap = visible.maxY - (frame.maxY - HUDController.margin)
        print("\(path): window \(Int(size.width))x\(Int(size.height)), panel \(Int(controller.panelHeight)) pt, top gap \(Int(topGap)) pt, inside visibleFrame \(visible.contains(frame.insetBy(dx: HUDController.margin, dy: HUDController.margin)))")

        let scale = 2
        guard let panelRep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: panelRep)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // a plain desktop-like backdrop under the translucent panel
        (dark ? NSColor(srgbRed: 0.11, green: 0.14, blue: 0.20, alpha: 1) : NSColor(srgbRed: 0.79, green: 0.84, blue: 0.91, alpha: 1)).setFill()
        NSRect(origin: .zero, size: size).fill()
        panelRep.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        save(rep, to: path + ".png")
        controller.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    static func save(_ rep: NSBitmapImageRep, to path: String) {
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("saved \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }
    }
}
