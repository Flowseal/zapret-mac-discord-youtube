// Plays the real panel animations (open, page, ⌘K, close) and prints frame intervals per step.
// Used by CI to compare builds; not part of the app.
// NIMBUS_BENCH_REFRESH=old repeats what the app's 1 s refresh used to do on the main thread
// (pgrep/route subprocesses, re-publishing every model value); "new" publishes nothing that didn't change.
import AppKit
import QuartzCore
import SwiftUI

struct Strategy {
    let id: String
    let name: String
}

final class FrameMeter: NSObject {
    private(set) var order: [String] = []
    private(set) var samples: [String: [Double]] = [:]
    private var phase = ""
    private var last: CFTimeInterval = 0
    private var link: CADisplayLink?
    private(set) var refresh: Double = 60

    func start(on screen: NSScreen) {
        refresh = Double(screen.maximumFramesPerSecond)
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() { link?.invalidate() }

    func begin(_ name: String) {
        phase = name
        samples[name] = []
        order.append(name)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let t = link.timestamp
        if last > 0, !phase.isEmpty { samples[phase, default: []].append((t - last) * 1000) }
        last = t
    }
}

@main
struct BenchHUD {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: .darkAqua)
        let refreshMode = ProcessInfo.processInfo.environment["NIMBUS_BENCH_REFRESH"] ?? "new"

        let model = HUDModel()
        let strategies = (0..<6).map { Strategy(id: "s\($0)", name: "general (ALT\($0))") }
        model.strategies = strategies
        model.selectedStrategyID = "s3"
        model.strategyName = "general (ALT3)"
        model.running = true
        model.discord = .ok
        model.youtube = .ok
        model.discordMs = 42
        model.youtubeMs = 118
        model.latencySamples = (0..<40).map { 55 + Double(($0 * 7) % 13) }
        model.engineStarted = Date().addingTimeInterval(-8076)
        model.networkInterface = "en0"
        model.networkAddress = "192.168.1.24"
        model.versionTitle = "Версия 1.6.0"

        let controller = HUDController(model: model)
        guard let screen = NSScreen.main else { print("no screen"); exit(1) }
        let visible = screen.visibleFrame
        let anchor = NSRect(x: visible.midX - 12, y: visible.maxY, width: 24, height: 24)
        NSApp.activate(ignoringOtherApps: true)

        var tick = 0
        let refresh = Timer(timeInterval: 1, repeats: true) { _ in
            tick += 1
            guard refreshMode == "old" else { return }
            for _ in 0..<3 { run("/usr/bin/pgrep", ["-x", "utunws"]) }
            if tick % 4 == 0 { run("/sbin/route", ["-n", "get", "default"]) }
            // every assignment fires objectWillChange, equal value or not
            model.running = model.running
            model.busy = model.busy
            model.testing = model.testing
            model.strategies = model.strategies
            model.strategyName = model.strategyName
            model.selectedStrategyID = model.selectedStrategyID
            model.ipsetMode = model.ipsetMode
            model.loginEnabled = model.loginEnabled
            model.versionTitle = model.versionTitle
            model.testTitle = model.testTitle
            model.testRows = model.testRows
            model.discord = model.discord
            model.youtube = model.youtube
            model.autoPauseVpn = model.autoPauseVpn
            model.vpnWarning = model.vpnWarning
        }
        RunLoop.main.add(refresh, forMode: .common)

        let meter = FrameMeter()
        meter.start(on: screen)
        func step(_ name: String, _ seconds: Double, _ action: () -> Void) {
            meter.begin(name)
            action()
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        step("open", 1.2) { controller.show(below: anchor, on: screen) }
        step("page-more", 1.0) { withAnimation(Motion.smooth) { model.page = .more } }
        step("page-back", 1.0) { withAnimation(Motion.smooth) { model.page = .main } }
        step("palette-open", 0.8) { model.openPalette() }
        step("palette-close", 0.6) { model.closePalette() }
        step("idle", 2.0) {}
        step("close", 0.6) { controller.close() }
        meter.stop()

        print("refresh=\(refreshMode) display=\(Int(meter.refresh)) Hz")
        print("step            frames  avg ms  p95 ms  max ms  long")
        let budget = 1000 / meter.refresh * 1.5
        for name in meter.order {
            let list = meter.samples[name] ?? []
            guard !list.isEmpty else { print(name.padding(toLength: 15, withPad: " ", startingAt: 0) + " 0"); continue }
            let sorted = list.sorted()
            let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
            let avg = list.reduce(0, +) / Double(list.count)
            let long = list.filter { $0 > budget }.count
            print(name.padding(toLength: 15, withPad: " ", startingAt: 0)
                  + String(format: " %6d  %6.1f  %6.1f  %6.1f  %4d", list.count, avg, p95, sorted.last!, long))
        }
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
