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

        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let theme = dark ? "dark" : "light"
            shoot("\(out)/macos-\(theme)-main", dark: dark) { m in
                m.strategies = strategies
                m.selectedStrategyID = "s5"
                m.strategyName = "general (SIMPLE FAKE)"
                m.running = true
                m.loginEnabled = true
                m.ipsetMode = "loaded"
                m.discord = .ok
                m.youtube = .ok
                m.versionTitle = "Версия 1.5.0"
            }
            shoot("\(out)/macos-\(theme)-more", dark: dark) { m in
                m.strategies = strategies
                m.running = true
                m.page = .more
                m.testRows = [
                    TestRow(name: "general", score: "20/27", isBest: false),
                    TestRow(name: "general (ALT)", score: "21/27", isBest: false),
                    TestRow(name: "general (ALT2)", score: "22/27", isBest: false),
                    TestRow(name: "general (ALT3)", score: "23/27", isBest: true),
                    TestRow(name: "general (ALT4)", score: "ошибка", isBest: false),
                ]
                m.testBest = "Лучшая: general (ALT3) (23/27)"
                m.applyBestEnabled = true
                m.testTitle = "Повторить тест"
                m.versionTitle = "Версия 1.5.0"
            }
        }
        exit(0)
    }

    static func shoot(_ path: String, dark: Bool, setup: (HUDModel) -> Void) {
        let model = HUDModel()
        setup(model)
        let view = NimbusHUDView(model: model)
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        // a plain desktop-like backdrop under the translucent panel
        let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.11, green: 0.14, blue: 0.20, alpha: 1)
                                                : NSColor(srgbRed: 0.79, green: 0.84, blue: 0.91, alpha: 1)).cgColor
        hosting.frame = backdrop.bounds
        backdrop.addSubview(hosting)
        let window = KeyWindow(contentRect: NSRect(x: 200, y: 200, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = backdrop
        // an active key window, so switches use the accent tint like the real popover
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        // 2x snapshot of the view hierarchy
        let scale = 2
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = size
            backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
            save(rep, to: path + ".png")
        }
        window.orderOut(nil)
    }

    static func save(_ rep: NSBitmapImageRep, to path: String) {
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("saved \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }
    }
}
