import AppKit
import Foundation

struct Strategy {
    let id: String
    let name: String
}

@main
struct ZapretMacMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let fileManager = FileManager.default
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private var startStopItem = NSMenuItem()
    private var strategyItems: [NSMenuItem] = []
    private var ipsetItems: [NSMenuItem] = []
    private var strategies: [Strategy] = []
    private var timer: Timer?
    private var busy = false

    private var dataRoot: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZapretMac", isDirectory: true)
    }

    private var payloadURL: URL {
        Bundle.main.resourceURL!.appendingPathComponent("Payload", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try initializeUserData()
            strategies = try loadStrategies()
        } catch {
            showError(error.localizedDescription)
            NSApp.terminate(nil)
            return
        }
        buildMenu()
        refreshMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshMenu()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenu()
    }

    private func initializeUserData() throws {
        let lists = dataRoot.appendingPathComponent("lists", isDirectory: true)
        try fileManager.createDirectory(at: lists, withIntermediateDirectories: true)
        let defaults = payloadURL.appendingPathComponent("default-lists", isDirectory: true)
        for name in try fileManager.contentsOfDirectory(atPath: defaults.path) {
            let target = lists.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: target.path) {
                try fileManager.copyItem(at: defaults.appendingPathComponent(name), to: target)
            }
        }
        let strategyFile = dataRoot.appendingPathComponent("selected-strategy")
        if !fileManager.fileExists(atPath: strategyFile.path) {
            try writeState("general-simple-fake", to: strategyFile)
        }
        let ipsetFile = dataRoot.appendingPathComponent("ipset-mode")
        if !fileManager.fileExists(atPath: ipsetFile.path) {
            try writeState("none", to: ipsetFile)
        }
    }

    private func loadStrategies() throws -> [Strategy] {
        let text = try String(contentsOf: payloadURL.appendingPathComponent("strategies.tsv"), encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return fields.count == 2 ? Strategy(id: fields[0], name: fields[1]) : nil
        }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = menu
        menu.delegate = self

        startStopItem = NSMenuItem(title: "Запустить", action: #selector(toggleService), keyEquivalent: "")
        startStopItem.target = self
        menu.addItem(startStopItem)

        let strategyRoot = NSMenuItem(title: "Выбор стратегии", action: nil, keyEquivalent: "")
        let strategyMenu = NSMenu()
        for strategy in strategies {
            let item = NSMenuItem(title: strategy.name, action: #selector(selectStrategy(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = strategy.id
            strategyMenu.addItem(item)
            strategyItems.append(item)
        }
        strategyRoot.submenu = strategyMenu
        menu.addItem(strategyRoot)

        let ipsetRoot = NSMenuItem(title: "Переключить IPSet", action: nil, keyEquivalent: "")
        let ipsetMenu = NSMenu()
        for mode in ["none", "loaded", "any"] {
            let item = NSMenuItem(title: mode, action: #selector(selectIPSet(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            ipsetMenu.addItem(item)
            ipsetItems.append(item)
        }
        ipsetRoot.submenu = ipsetMenu
        menu.addItem(ipsetRoot)

        menu.addItem(.separator())
        let openLists = NSMenuItem(title: "Открыть списки", action: #selector(openLists), keyEquivalent: "")
        openLists.target = self
        menu.addItem(openLists)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выход", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func refreshMenu() {
        guard statusItem != nil else { return }
        let running = isRunning()
        startStopItem.title = running ? "Остановить" : "Запустить"
        statusItem.button?.image = statusIcon(running: running)
        statusItem.button?.toolTip = running ? "ZapretMac запущен" : "ZapretMac остановлен"
        let selectedStrategy = readState(from: dataRoot.appendingPathComponent("selected-strategy"))
        for item in strategyItems {
            item.state = item.representedObject as? String == selectedStrategy ? .on : .off
            item.isEnabled = !busy
        }
        let selectedIPSet = readState(from: dataRoot.appendingPathComponent("ipset-mode"))
        for item in ipsetItems {
            item.state = item.representedObject as? String == selectedIPSet ? .on : .off
            item.isEnabled = !busy
        }
        startStopItem.isEnabled = !busy
    }

    private func statusIcon(running: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.black.setStroke()
        let z = NSBezierPath()
        z.lineWidth = 2
        z.lineCapStyle = .round
        z.lineJoinStyle = .round
        z.move(to: NSPoint(x: 4, y: 14))
        z.line(to: NSPoint(x: 14, y: 14))
        z.line(to: NSPoint(x: 4, y: 4))
        z.line(to: NSPoint(x: 14, y: 4))
        z.stroke()
        if !running {
            let slash = NSBezierPath()
            slash.lineWidth = 2.4
            slash.lineCapStyle = .round
            slash.move(to: NSPoint(x: 3, y: 15))
            slash.line(to: NSPoint(x: 15, y: 3))
            slash.stroke()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func isRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "utunws"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func readState(from url: URL) -> String {
        guard let value = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeState(_ value: String, to url: URL) throws {
        try (value + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @objc private func toggleService() {
        if isRunning() {
            runPrivileged(script: "stop.sh", arguments: [], prompt: "Остановить ZapretMac")
        } else {
            runPrivileged(script: "install.sh", arguments: [dataRoot.path], prompt: "Установить и запустить ZapretMac")
        }
    }

    @objc private func selectStrategy(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        do {
            try writeState(id, to: dataRoot.appendingPathComponent("selected-strategy"))
            refreshMenu()
            applyIfRunning()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func selectIPSet(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        do {
            try writeState(mode, to: dataRoot.appendingPathComponent("ipset-mode"))
            refreshMenu()
            applyIfRunning()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func applyIfRunning() {
        if isRunning() {
            runPrivileged(script: "restart.sh", arguments: [], prompt: "Применить настройки ZapretMac")
        }
    }

    @objc private func openLists() {
        NSWorkspace.shared.open(dataRoot.appendingPathComponent("lists", isDirectory: true))
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func runPrivileged(script: String, arguments: [String], prompt: String) {
        if busy { return }
        busy = true
        refreshMenu()
        let payload = payloadURL
        let dataArguments = arguments
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var failure: String?
            let stagingRoot = self.fileManager.temporaryDirectory.appendingPathComponent("ZapretMac-\(UUID().uuidString)", isDirectory: true)
            let stagedPayload = stagingRoot.appendingPathComponent("Payload", isDirectory: true)
            do {
                try self.fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
                try self.fileManager.copyItem(at: payload, to: stagedPayload)
                var commandArguments = [stagedPayload.path]
                if script == "install.sh" {
                    commandArguments = [stagedPayload.path] + dataArguments
                } else {
                    commandArguments = dataArguments
                }
                let command = (["/bin/sh", stagedPayload.appendingPathComponent(script).path] + commandArguments)
                    .map(self.shellQuote)
                    .joined(separator: " ")
                let source = "do shell script \"\(self.appleScriptEscape(command))\" with administrator privileges with prompt \"\(self.appleScriptEscape(prompt))\""
                let process = Process()
                let errorPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = errorPipe
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    failure = text?.isEmpty == false ? text : "Операция не выполнена"
                    let diagnostics = self.serviceDiagnostics()
                    if !diagnostics.isEmpty {
                        failure = (failure ?? "Операция не выполнена") + "\n\n" + diagnostics
                    }
                }
            } catch {
                failure = error.localizedDescription
            }
            try? self.fileManager.removeItem(at: stagingRoot)
            DispatchQueue.main.async {
                self.busy = false
                self.refreshMenu()
                if let failure { self.showError(failure) }
            }
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func serviceDiagnostics() -> String {
        let root = URL(fileURLWithPath: "/Library/Application Support/ZapretMac", isDirectory: true)
        for name in ["engine.log", "zapret.log"] {
            let url = root.appendingPathComponent(name)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let lines = text.split(whereSeparator: \.isNewline).suffix(18)
                if !lines.isEmpty { return lines.joined(separator: "\n") }
            }
        }
        return ""
    }

    private func showError(_ message: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "ZapretMac"
            alert.informativeText = message
            alert.runModal()
        }
    }
}
