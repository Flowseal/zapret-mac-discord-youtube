import AppKit
import CryptoKit
import Foundation
import Security
import ServiceManagement
import SwiftUI

@_silgen_name("AuthorizationExecuteWithPrivileges")
private func executeWithPrivileges(
    _ authorization: AuthorizationRef,
    _ path: UnsafePointer<CChar>,
    _ flags: AuthorizationFlags,
    _ arguments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>>,
    _ pipe: UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>
) -> OSStatus

struct Strategy: Equatable {
    let id: String
    let name: String
}

struct GitHubRelease: Decodable {
    let tagName: String
    let draft: Bool?
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case assets
    }
}

struct GitHubReleaseAsset: Decodable {
    let name: String
    let downloadURL: URL
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
        case digest
    }
}

@main
struct NimbusMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let fileManager = FileManager.default
    private var statusItem: NSStatusItem!
    private let hudModel = HUDModel()
    private var hud: HUDController!
    private var strategies: [Strategy] = []
    private var timer: Timer?
    private var updateTimer: Timer?
    private var busy = false
    private var testing = false
    private var cancellingTest = false
    private var checkingForUpdate = false
    private var updating = false
    private var availableRelease: GitHubRelease?
    private var authorization: AuthorizationRef?
    private var lastServiceProbe = Date.distantPast
    private var lastLayoutKey = ""
    private var glyph: StatusGlyphAnimator?
    private var engineWasRunning = false
    private var noticeTimer: Timer?
    private var loginChecked = false
    private var pausedByVpn = false
    private var lastVpnProbe = Date.distantPast
    private var vpnProbing = false
    private var startingSmartTest = false

    private let releaseURL = URL(string: "https://api.github.com/repos/relocpe/Nimbus/releases")!
    private let releaseAssetName = "Nimbus-macOS-universal.zip"

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
            // showError is async; terminating right after it would quit before the alert is shown
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Nimbus"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        buildStatusItem()
        refreshHUD()
        showPendingUpdateError()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshHUD()
        }
        checkForUpdate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let authorization {
            AuthorizationFree(authorization, [.destroyRights])
        }
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
        let autoPauseFile = dataRoot.appendingPathComponent("vpn-autopause")
        if !fileManager.fileExists(atPath: autoPauseFile.path) {
            try writeState("0", to: autoPauseFile)
        }
    }

    private func loadStrategies() throws -> [Strategy] {
        let text = try String(contentsOf: payloadURL.appendingPathComponent("strategies.tsv"), encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return fields.count == 2 ? Strategy(id: fields[0], name: fields[1]) : nil
        }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            glyph = StatusGlyphAnimator(button: button)
            button.toolTip = "Nimbus"
            button.target = self
            button.action = #selector(toggleHUD)
            button.sendAction(on: [.leftMouseUp])
        }
        hud = HUDController(model: hudModel)
        hudModel.toggleService = { [weak self] in self?.toggleService() }
        hudModel.selectStrategy = { [weak self] id in self?.selectStrategy(id: id) }
        hudModel.selectIPSet = { [weak self] mode in self?.selectIPSet(mode: mode) }
        hudModel.toggleLogin = { [weak self] in self?.toggleLoginItem() }
        hudModel.testStrategies = { [weak self] in self?.testStrategies() }
        hudModel.applyBest = { [weak self] in self?.applyBestStrategy() }
        hudModel.applyTestRow = { [weak self] name in self?.applyNamedStrategy(name) }
        hudModel.openLists = { [weak self] in self?.openListsPage() }
        hudModel.openList = { [weak self] name in self?.openList(name) }
        hudModel.saveList = { [weak self] in self?.saveCurrentList() }
        hudModel.openLogs = { [weak self] in self?.openLogsPage() }
        hudModel.copyLogs = { [weak self] in self?.copyLogs() }
        hudModel.restartService = { [weak self] in self?.restartService() }
        hudModel.openGitHub = { [weak self] in self?.openGitHub() }
        hudModel.installUpdate = { [weak self] in self?.installUpdate() }
        hudModel.findAndApply = { [weak self] in self?.findAndApply() }
        hudModel.updateLists = { [weak self] in self?.updateLists() }
        hudModel.openDiagnostics = { [weak self] in self?.openDiagnosticsPage() }
        hudModel.copyDiagnostics = { [weak self] in self?.copyDiagnosticsReport() }
        hudModel.toggleAutoPause = { [weak self] in self?.toggleAutoPause() }
        hudModel.addBypass = { [weak self] in self?.addListEntry(exclude: false) }
        hudModel.addExclude = { [weak self] in self?.addListEntry(exclude: true) }
        hudModel.removeUserEntry = { [weak self] entry in self?.removeListEntry(entry) }
        hudModel.quit = { [weak self] in self?.quitApp() }
        hudModel.onShown = { [weak self] in self?.probeServices(force: true) }
        hudModel.dismissNotice = { [weak self] in self?.dismissNotice() }
    }

    @objc private func toggleHUD() {
        guard let button = statusItem.button else { return }
        hud.toggle(relativeTo: button)
    }

    private func refreshHUD() {
        guard statusItem != nil else { return }
        let running = isRunning()
        let selectedStrategy = readState(from: dataRoot.appendingPathComponent("selected-strategy"))
        let selectedIPSet = readState(from: dataRoot.appendingPathComponent("ipset-mode"))
        hudModel.update(\.running, running)
        hudModel.update(\.busy, busy)
        if !busy { hudModel.update(\.switchIntent, nil) }
        hudModel.update(\.appVersion, displayVersion(currentVersion))
        if running != engineWasRunning || (running && hudModel.engineStarted == nil) {
            engineWasRunning = running
            hudModel.update(\.engineStarted, running ? (EngineClock.engineStartDate() ?? Date()) : nil)
            if !running, !hudModel.latencySamples.isEmpty { hudModel.latencySamples = [] }
        }
        hudModel.update(\.testing, testing)
        hudModel.update(\.cancellingTest, cancellingTest)
        hudModel.update(\.updating, updating)
        hudModel.update(\.strategies, strategies)
        hudModel.update(\.selectedStrategyID, selectedStrategy)
        hudModel.update(\.strategyName, strategies.first(where: { $0.id == selectedStrategy })?.name ?? selectedStrategy)
        hudModel.update(\.ipsetMode, selectedIPSet.isEmpty ? "none" : selectedIPSet)
        if hud.isVisible || !loginChecked {
            // an XPC round trip to smd: only while someone can see the switch
            loginChecked = true
            hudModel.update(\.loginEnabled, SMAppService.mainApp.status == .enabled)
        }
        loadTestLive()
        if testing || hud.isVisible {
            probeServices(force: false)
        }
        hudModel.update(\.applyBestEnabled, !testing && !busy && hudModel.testRows.contains(where: { $0.isBest }))
        if testing {
            let progress = readState(from: dataRoot.appendingPathComponent("strategy-test-progress"))
            hudModel.update(\.testProgress, progress)
            if cancellingTest {
                hudModel.update(\.testTitle, "Остановка теста…")
            } else {
                hudModel.update(\.testTitle, progress.isEmpty ? "Остановить тест" : "Остановить")
            }
            hudModel.update(\.testEnabled, !cancellingTest)
        } else {
            hudModel.update(\.testTitle, hudModel.testRows.isEmpty ? "Тест стратегий" : "Повторить тест")
            hudModel.update(\.testEnabled, !busy)
        }
        if hudModel.page == .logs {
            loadLogs()
        }
        if hudModel.page == .lists {
            hudModel.update(\.lists, listInfos())
            hudModel.update(\.userEntries, loadUserEntries())
        }
        hudModel.update(\.autoPauseVpn, readState(from: dataRoot.appendingPathComponent("vpn-autopause")) == "1")
        refreshVpnState()
        if updating {
            hudModel.update(\.versionTitle, "Установка обновления…")
            hudModel.update(\.canInstallUpdate, false)
        } else if let release = availableRelease {
            hudModel.update(\.versionTitle, "Обновить до \(displayVersion(release.tagName))")
            hudModel.update(\.canInstallUpdate, !busy && !testing)
        } else {
            hudModel.update(\.versionTitle, "Версия \(currentVersion)")
            hudModel.update(\.canInstallUpdate, false)
        }
        if !running {
            hudModel.update(\.discord, .off)
            hudModel.update(\.youtube, .off)
            hudModel.update(\.discordMs, nil)
            hudModel.update(\.youtubeMs, nil)
        }
        updateStatusGlyph()
        let layoutKey = "\(hudModel.page)|\(testing)|\(hudModel.testRows.count)|\(hudModel.testBest)|\(hudModel.testProgress)|\(hudModel.notice)|\(hudModel.lists.count)|\(hudModel.editorName)|\(hudModel.logLines.count)|\(hudModel.diagnosticsRunning)|\(hudModel.paletteOpen)|\(hudModel.vpnWarning)|\(hudModel.userEntries.count)|\(hudModel.diagnostics.count)|\(hudModel.updatingLists)"
        if hud.isVisible, layoutKey != lastLayoutKey {
            lastLayoutKey = layoutKey
            hud.relayout()
        }
    }

    private func loadTestLive() {
        let best = readState(from: dataRoot.appendingPathComponent("strategy-test-best"))
        hudModel.update(\.testBest, best)
        let live = readState(from: dataRoot.appendingPathComponent("strategy-test-live.tsv"))
        let bestNames = best
        var rows: [TestRow] = []
        for line in live.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, !fields[0].isEmpty else { continue }
            let score = fields[1] == "err" ? "ошибка" : "\(fields[1])/\(fields[2])"
            let isBest = !bestNames.isEmpty && bestNames.contains(fields[0]) && bestNames.hasPrefix("Лучшая:")
            rows.append(TestRow(name: fields[0], score: score, isBest: isBest))
        }
        hudModel.update(\.testRows, rows)
        if !testing {
            hudModel.update(\.testProgress, "")
        }
    }

    private func probeServices(force: Bool) {
        let running = isRunning()
        if !running {
            hudModel.update(\.discord, .off)
            hudModel.update(\.youtube, .off)
            return
        }
        if !force, Date().timeIntervalSince(lastServiceProbe) < 12 { return }
        lastServiceProbe = Date()
        if hudModel.discord == .off || hudModel.discord == .unknown { hudModel.discord = .checking }
        if hudModel.youtube == .off || hudModel.youtube == .unknown { hudModel.youtube = .checking }
        updateStatusGlyph()
        probeURL("https://discord.com/") { [weak self] ok, ms in
            guard let self else { return }
            self.hudModel.update(\.discord, ok ? .ok : .bad)
            self.hudModel.update(\.discordMs, ok ? ms : nil)
            self.hudModel.update(\.lastProbe, Date())
            self.updateStatusGlyph()
        }
        probeURL("https://www.youtube.com/") { [weak self] ok, ms in
            guard let self else { return }
            self.hudModel.update(\.youtube, ok ? .ok : .bad)
            self.hudModel.update(\.youtubeMs, ok ? ms : nil)
            self.hudModel.update(\.lastProbe, Date())
            // the history chart follows the slower, video side of the bypass
            var samples = self.hudModel.latencySamples
            samples.append(ok ? Double(ms) : .nan)
            if samples.count > 40 { samples.removeFirst(samples.count - 40) }
            self.hudModel.latencySamples = samples
            self.updateStatusGlyph()
        }
    }

    private func updateStatusGlyph() {
        glyph?.set(hudModel.phase)
        statusItem?.button?.toolTip = "Nimbus — " + hudModel.heroTitle.lowercased()
    }


    private func probeURL(_ raw: String, done: @escaping (Bool, Int) -> Void) {
        guard let url = URL(string: raw) else {
            done(false, 0)
            return
        }
        let started = Date()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { _, response, error in
            let ok: Bool
            if error != nil {
                ok = false
            } else if let http = response as? HTTPURLResponse {
                ok = (200..<500).contains(http.statusCode)
            } else {
                ok = false
            }
            let ms = Int((Date().timeIntervalSince(started) * 1000).rounded())
            DispatchQueue.main.async { done(ok, ms) }
        }.resume()
    }

    private func isRunning() -> Bool {
        // read the process table in place; spawning pgrep every second stalled the main thread
        if let found = ProcessTable.contains("utunws") { return found }
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
        pausedByVpn = false
        if isRunning() {
            runPrivileged(script: "stop.sh", arguments: [])
        } else {
            runPrivileged(script: "install.sh", arguments: [dataRoot.path])
        }
    }

    private func selectStrategy(id: String) {
        do {
            try writeState(id, to: dataRoot.appendingPathComponent("selected-strategy"))
            refreshHUD()
            applyIfRunning()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func selectIPSet(mode: String) {
        do {
            try writeState(mode, to: dataRoot.appendingPathComponent("ipset-mode"))
            refreshHUD()
            applyIfRunning()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func applyIfRunning() {
        if isRunning() {
            runPrivileged(script: "restart.sh", arguments: [])
        }
    }

    private func openListsPage() {
        hudModel.lists = listInfos()
        hudModel.userEntries = loadUserEntries()
        hudModel.page = .lists
        hud.relayout()
    }

    private func openList(_ name: String) {
        let url = dataRoot.appendingPathComponent("lists", isDirectory: true).appendingPathComponent(name)
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > 80_000 {
            NSWorkspace.shared.open(url)
            return
        }
        hudModel.editorName = name
        hudModel.editorTitle = Self.listTitle(name)
        hudModel.editorText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        hudModel.editorOriginal = hudModel.editorText
        hudModel.editorCaret = EditorCaret()
        hudModel.page = .editor
        hud.relayout()
    }

    private func saveCurrentList() {
        let name = hudModel.editorName
        guard !name.isEmpty else { return }
        let url = dataRoot.appendingPathComponent("lists", isDirectory: true).appendingPathComponent(name)
        do {
            try hudModel.editorText.write(to: url, atomically: true, encoding: .utf8)
            showNotice("Сохранено")
            applyIfRunning()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func openLogsPage() {
        loadLogs()
        hudModel.page = .logs
        hud.relayout()
    }

    private func copyLogs() {
        NSPasteboard.general.clearContents()
        let visible = hudModel.visibleLogLines
        let text = visible.isEmpty ? hudModel.logs : visible.map { "\($0.time) \($0.level) \($0.source) \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.setString(text, forType: .string)
        showNotice("Логи скопированы")
    }

    private func restartService() {
        if isRunning() {
            runPrivileged(script: "restart.sh", arguments: [])
        }
    }

    private func openGitHub() {
        if let url = URL(string: "https://github.com/relocpe/Nimbus") {
            NSWorkspace.shared.open(url)
        }
    }

    private func applyBestStrategy() {
        if let name = hudModel.testRows.first(where: { $0.isBest })?.name {
            applyNamedStrategy(name)
        }
    }

    private func applyNamedStrategy(_ name: String) {
        guard let id = strategies.first(where: { $0.name == name })?.id else {
            showError("Не нашёл стратегию \(name)")
            return
        }
        selectStrategy(id: id)
        showNotice("Стратегия: \(name)")
    }

    private static func listTitle(_ name: String) -> String {
        switch name {
        case "list-general.txt": return "Основные"
        case "list-general-user.txt": return "Основные"
        case "list-google.txt": return "Google"
        case "list-exclude.txt": return "Исключения"
        case "list-exclude-user.txt": return "Исключения"
        case "ipset-all.txt": return "IP-набор"
        case "ipset-all-user.txt": return "IP-набор"
        case "ipset-exclude.txt": return "IP исключения"
        case "ipset-exclude-user.txt": return "IP исключения"
        default: return name
        }
    }

    private func listInfos() -> [ListInfo] {
        let names = [
            "list-general-user.txt",
            "list-exclude-user.txt",
            "ipset-all-user.txt",
            "ipset-exclude-user.txt",
            "list-general.txt",
            "list-google.txt",
            "list-exclude.txt",
            "ipset-exclude.txt",
            "ipset-all.txt",
        ]
        let dir = dataRoot.appendingPathComponent("lists", isDirectory: true)
        return names.compactMap { name in
            let url = dir.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let lines = text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            let user = name.contains("-user")
            return ListInfo(
                id: name,
                title: name,
                detail: Self.listTitle(name) + (size > 80_000 ? " · \(lines) строк · открыть во внешнем редакторе" : " · \(lines) строк"),
                badge: user ? "свои" : "",
                external: size > 80_000,
                lines: lines
            )
        }
    }

    /// Last lines of zapret.log (source "nimbus") and engine.log (source "engine") for the Логи page.
    private func loadLogs(limit: Int = 400) {
        hudModel.update(\.logs, loadDiagnostics(limit: 90))
        let root = URL(fileURLWithPath: "/Library/Application Support/ZapretMac", isDirectory: true)
        var rows: [LogLine] = []
        for (name, source) in [("zapret.log", "nimbus"), ("engine.log", "engine")] {
            guard let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) else { continue }
            let tail = text.split(whereSeparator: \.isNewline).suffix(limit).joined(separator: "\n")
            rows += LogParser.parse(tail, source: source, startID: rows.count)
        }
        if rows != hudModel.logLines { hudModel.logLines = rows }
    }

    private func loadDiagnostics(limit: Int = 18) -> String {
        let root = URL(fileURLWithPath: "/Library/Application Support/ZapretMac", isDirectory: true)
        var chunks: [String] = []
        for name in ["zapret.log", "engine.log"] {
            let url = root.appendingPathComponent(name)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                let tail = lines.suffix(limit)
                if !tail.isEmpty {
                    chunks.append("— \(name) —\n" + tail.joined(separator: "\n"))
                }
            }
        }
        return chunks.joined(separator: "\n\n")
    }

    private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            refreshHUD()
        } catch {
            showError("Не удалось изменить автозапуск: \(error.localizedDescription)")
        }
    }

    /// Full version with the pre-release part ("1.6.0-beta.1"). CFBundleShortVersionString only holds "1.6.0".
    private var currentVersion: String {
        if let full = Bundle.main.object(forInfoDictionaryKey: "NimbusVersion") as? String, !full.isEmpty { return full }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private func displayVersion(_ version: String) -> String {
        version.first == "v" || version.first == "V" ? String(version.dropFirst()) : version
    }

    private func bundledVersion(_ releaseVersion: String) -> String {
        ReleaseVersion.numeric(releaseVersion)
    }

    private func checkForUpdate() {
        if checkingForUpdate || updating { return }
        checkingForUpdate = true
        let url = URL(string: releaseURL.absoluteString + "?t=\(Int(Date().timeIntervalSince1970 * 1000))&per_page=10")!
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Nimbus", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            var release: GitHubRelease?
            var completed = false
            if let response = response as? HTTPURLResponse,
               response.statusCode == 200,
               let data,
               let decoded = try? JSONDecoder().decode([GitHubRelease].self, from: data) {
                completed = true
                // pre-releases count too: 1.5.0 gets 1.6.0-beta.1, and the beta later gets 1.6.0
                let candidates = decoded.map { item in
                    (tag: item.tagName, draft: item.draft ?? false, hasAsset: item.assets.contains { $0.name == self.releaseAssetName })
                }
                if let index = ReleaseVersion.pickUpdate(candidates, installed: self.currentVersion) {
                    release = decoded[index]
                }
            }
            DispatchQueue.main.async {
                self.checkingForUpdate = false
                if completed {
                    self.availableRelease = release
                }
                self.refreshHUD()
            }
        }.resume()
    }

    @objc private func installUpdate() {
        guard let release = availableRelease,
              let asset = release.assets.first(where: { $0.name == releaseAssetName }),
              !updating else { return }
        let target = Bundle.main.bundleURL.standardizedFileURL
        guard target.pathExtension == "app",
              !target.path.contains("/AppTranslocation/") else {
            showError("Переместите Nimbus.app в папку Программы и запустите снова")
            return
        }
        updating = true
        refreshHUD()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let source = self.fileManager.temporaryDirectory.appendingPathComponent("Nimbus-\(UUID().uuidString).zip")
            do {
                let arguments = ["-fL", "--connect-timeout", "5", "-A", "Nimbus", "-o", source.path, asset.downloadURL.absoluteString]
                do {
                    try self.runProcess("/usr/bin/curl", arguments: ["--resolve", "release-assets.githubusercontent.com:443:185.199.109.133", "--max-time", "30"] + arguments)
                } catch {
                    try? self.fileManager.removeItem(at: source)
                    try self.runProcess("/usr/bin/curl", arguments: ["--max-time", "120"] + arguments)
                }
                try self.prepareAndLaunchUpdate(source: source, release: release, asset: asset, target: target)
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            } catch {
                try? self.fileManager.removeItem(at: source)
                DispatchQueue.main.async {
                    self.updating = false
                    self.refreshHUD()
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func prepareAndLaunchUpdate(source: URL, release: GitHubRelease, asset: GitHubReleaseAsset, target: URL) throws {
        let workRoot = fileManager.temporaryDirectory.appendingPathComponent("Nimbus-Update-\(UUID().uuidString)", isDirectory: true)
        let archive = workRoot.appendingPathComponent(releaseAssetName)
        let extracted = workRoot.appendingPathComponent("extracted", isDirectory: true)
        do {
            try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: archive)
            try verifyDigest(of: archive, expected: asset.digest)
            try runProcess("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extracted.path])
            let app = extracted.appendingPathComponent("Nimbus.app", isDirectory: true)
            try verifyUpdate(app, version: release.tagName)
            let updater = payloadURL.appendingPathComponent("update-app.sh")
            let updaterCopy = workRoot.appendingPathComponent("update-app.sh")
            try fileManager.copyItem(at: updater, to: updaterCopy)
            let log = dataRoot.appendingPathComponent("update.log")
            let command = ([
                "/usr/bin/nohup", "/bin/sh", updaterCopy.path, app.path, target.path,
                String(ProcessInfo.processInfo.processIdentifier), workRoot.path,
                isRunning() ? "1" : "0", dataRoot.path, String(getuid()), String(getgid())
            ].map(shellQuote).joined(separator: " ")) + " >\(shellQuote(log.path)) 2>&1 </dev/null &"
            let result = try executePrivileged(command: command)
            guard result.status == 0 else {
                throw NSError(domain: "Nimbus.Update", code: 2, userInfo: [NSLocalizedDescriptionKey: result.output.isEmpty ? "Не удалось запустить установку обновления" : result.output])
            }
        } catch {
            try? fileManager.removeItem(at: workRoot)
            throw error
        }
    }

    private func verifyDigest(of archive: URL, expected: String?) throws {
        guard let expected, expected.hasPrefix("sha256:") else { return }
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual.caseInsensitiveCompare(String(expected.dropFirst(7))) == .orderedSame else {
            throw NSError(domain: "Nimbus.Update", code: 3, userInfo: [NSLocalizedDescriptionKey: "Контрольная сумма обновления не совпала"])
        }
    }

    private func verifyUpdate(_ app: URL, version: String) throws {
        guard fileManager.fileExists(atPath: app.path),
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let bundledVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              displayVersion(bundledVersion) == self.bundledVersion(version),
              ReleaseVersion.compare((bundle.object(forInfoDictionaryKey: "NimbusVersion") as? String) ?? bundledVersion, version) == .orderedSame else {
            throw NSError(domain: "Nimbus.Update", code: 4, userInfo: [NSLocalizedDescriptionKey: "Архив релиза содержит неподходящую версию приложения"])
        }
        try runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", app.path])
        let executable = app.appendingPathComponent("Contents/MacOS/Nimbus")
        try runProcess("/usr/bin/lipo", arguments: [executable.path, "-verify_arch", "x86_64"])
        try runProcess("/usr/bin/lipo", arguments: [executable.path, "-verify_arch", "arm64"])
    }

    private func runProcess(_ path: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "Nimbus.Update", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "Проверка обновления не пройдена"])
        }
    }

    private func showPendingUpdateError() {
        let file = dataRoot.appendingPathComponent("update-error")
        guard let message = try? String(contentsOf: file, encoding: .utf8), !message.isEmpty else { return }
        try? fileManager.removeItem(at: file)
        showError(message)
    }

    @objc private func testStrategies() {
        if busy { return }
        let report = dataRoot.appendingPathComponent("strategy-test.txt")
        let live = dataRoot.appendingPathComponent("strategy-test-live.tsv")
        let bestFile = dataRoot.appendingPathComponent("strategy-test-best")
        let cancel = dataRoot.appendingPathComponent("strategy-test-cancel")
        if testing {
            do {
                try Data().write(to: cancel, options: .atomic)
                cancellingTest = true
                refreshHUD()
            } catch {
                showError(error.localizedDescription)
            }
            return
        }
        if !startingSmartTest {
            hudModel.testIsSmart = false
        }
        startingSmartTest = false
        writeTestPlan()
        try? fileManager.removeItem(at: report)
        try? fileManager.removeItem(at: live)
        try? fileManager.removeItem(at: bestFile)
        try? fileManager.removeItem(at: cancel)
        try? fileManager.removeItem(at: dataRoot.appendingPathComponent("strategy-test-apply"))
        hudModel.testRows = []
        hudModel.testBest = ""
        hudModel.testProgress = "Подготовка"
        hudModel.page = .more
        testing = true
        cancellingTest = false
        refreshHUD()
        if let button = statusItem.button, !hud.isVisible {
            hud.show(relativeTo: button)
        } else if hud.isVisible {
            hud.relayout()
        }
        runPrivileged(
            script: "test-strategies.sh",
            arguments: [dataRoot.path, String(getuid()), String(getgid())]
        ) { [weak self] failure in
            guard let self else { return }
            self.testing = false
            self.cancellingTest = false
            try? self.fileManager.removeItem(at: cancel)
            if self.hudModel.testIsSmart {
                let apply = (try? String(contentsOf: self.dataRoot.appendingPathComponent("strategy-test-apply"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !apply.isEmpty, self.strategies.contains(where: { $0.id == apply }) {
                    self.selectStrategy(id: apply)
                    let name = self.strategies.first(where: { $0.id == apply })?.name ?? apply
                    self.showNotice("Стратегия: \(name)")
                }
            }
            self.hudModel.page = .more
            self.refreshHUD()
            if let button = self.statusItem.button, !self.hud.isVisible {
                self.hud.show(relativeTo: button)
            } else if self.hud.isVisible {
                self.hud.relayout()
            }
            if let failure {
                self.showError(failure)
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func runPrivileged(script: String, arguments: [String], completion: ((String?) -> Void)? = nil) {
        if busy { return }
        busy = true
        refreshHUD()
        let payload = payloadURL
        let dataArguments = arguments
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var failure: String?
            let stagingRoot = self.fileManager.temporaryDirectory.appendingPathComponent("Nimbus-\(UUID().uuidString)", isDirectory: true)
            let stagedPayload = stagingRoot.appendingPathComponent("Payload", isDirectory: true)
            do {
                try self.fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
                try self.fileManager.copyItem(at: payload, to: stagedPayload)
                let shFiles = (try? self.fileManager.contentsOfDirectory(atPath: stagedPayload.path)) ?? []
                for name in shFiles where name.hasSuffix(".sh") {
                    try? self.fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedPayload.appendingPathComponent(name).path)
                }
                let utunwsPath = stagedPayload.appendingPathComponent("bin/utunws").path
                if self.fileManager.fileExists(atPath: utunwsPath) {
                    try? self.fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: utunwsPath)
                }
                var commandArguments = [stagedPayload.path]
                if script == "install.sh" || script == "test-strategies.sh" {
                    commandArguments = [stagedPayload.path] + dataArguments
                } else {
                    commandArguments = dataArguments
                }
                let command = (["/bin/sh", stagedPayload.appendingPathComponent(script).path] + commandArguments)
                    .map(self.shellQuote)
                    .joined(separator: " ")
                let result = try self.executePrivileged(command: command + " 2>&1")
                if result.status != 0 {
                    failure = result.output.isEmpty ? "Операция не выполнена" : result.output
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
                self.refreshHUD()
                if let failure { self.showError(failure) }
                completion?(failure)
            }
        }
    }

    private func executePrivileged(command: String) throws -> (status: Int32, output: String) {
        var auth = authorization
        if auth == nil {
            let status = kAuthorizationRightExecute.withCString { name in
                var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                return withUnsafeMutablePointer(to: &item) { item in
                    var rights = AuthorizationRights(count: 1, items: item)
                    return AuthorizationCreate(&rights, nil, [.interactionAllowed, .extendRights], &auth)
                }
            }
            guard status == errAuthorizationSuccess, let auth else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            authorization = auth
        }
        guard let auth else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errAuthorizationInvalidRef)) }
        let arguments = calloc(3, MemoryLayout<UnsafeMutablePointer<CChar>>.stride)!
            .bindMemory(to: UnsafeMutablePointer<CChar>.self, capacity: 3)
        arguments[0] = strdup("-c")!
        let marker = "ZAPRET_EXIT_STATUS="
        let wrappedCommand = command + "\nresult=$?\nprintf '\\n" + marker + "%d\\n' \"$result\""
        arguments[1] = strdup(wrappedCommand)!
        defer {
            free(arguments[0])
            free(arguments[1])
            free(arguments)
        }
        var pipe: UnsafeMutablePointer<FILE>?
        let executeStatus = "/bin/sh".withCString {
            executeWithPrivileges(auth, $0, [], arguments, &pipe)
        }
        guard executeStatus == errAuthorizationSuccess, let pipe else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(executeStatus))
        }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = fread(&buffer, 1, buffer.count, pipe)
            if count == 0 { break }
            output.append(buffer, count: count)
        }
        fclose(pipe)
        var text = String(data: output, encoding: .utf8) ?? ""
        guard let range = text.range(of: marker, options: .backwards) else { return (1, text) }
        let statusText = text[range.upperBound...].prefix { $0.isNumber }
        let exitStatus = Int32(statusText) ?? 1
        text.removeSubrange(range.lowerBound...)
        return (exitStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func serviceDiagnostics() -> String {
        loadDiagnostics(limit: 18)
    }

    private func showNotice(_ message: String, error: Bool = false) {
        hudModel.notice = message
        hudModel.noticeError = error
        noticeTimer?.invalidate()
        if !error {
            noticeTimer = Timer.scheduledTimer(withTimeInterval: 3.2, repeats: false) { [weak self] _ in
                self?.hudModel.notice = ""
                if self?.hud.isVisible == true {
                    self?.hud.relayout()
                }
            }
        }
        if hud.isVisible {
            hud.relayout()
        }
    }

    private func dismissNotice() {
        noticeTimer?.invalidate()
        hudModel.notice = ""
        if hud.isVisible {
            hud.relayout()
        }
    }

    private func showError(_ message: String) {
        DispatchQueue.main.async {
            if self.statusItem == nil || self.hud == nil {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Nimbus"
                alert.informativeText = message
                alert.runModal()
                return
            }
            let compact = message.split(whereSeparator: \.isNewline).prefix(6).joined(separator: "\n")
            self.showNotice(compact, error: true)
            if let button = self.statusItem.button, !self.hud.isVisible {
                self.hud.show(relativeTo: button)
            }
        }
    }

    private func findAndApply() {
        if busy { return }
        if testing {
            if hudModel.testIsSmart { testStrategies() }
            return
        }
        hudModel.testIsSmart = true
        startingSmartTest = true
        testStrategies()
    }

    private func writeTestPlan() {
        let mode = hudModel.testIsSmart ? "smart" : "full"
        try? writeState(mode, to: dataRoot.appendingPathComponent("strategy-test-mode"))
        let extra = HostParser.normalize(hudModel.extraHost) ?? ""
        try? writeState(extra, to: dataRoot.appendingPathComponent("strategy-test-extra"))
        let winners = StrategyOrdering.parseWinners(hudModel.testBest)
        let current = readState(from: dataRoot.appendingPathComponent("selected-strategy"))
        let ordered = hudModel.testIsSmart ? StrategyOrdering.smartOrder(strategies, currentID: current, winners: winners) : strategies
        let tsv = ordered.map { "\($0.id)\t\($0.name)" }.joined(separator: "\n") + "\n"
        try? tsv.write(to: dataRoot.appendingPathComponent("strategy-test-order.tsv"), atomically: true, encoding: .utf8)
    }

    private func refreshVpnState() {
        let now = Date()
        if vpnProbing || now.timeIntervalSince(lastVpnProbe) < 4 { return }
        lastVpnProbe = now
        vpnProbing = true
        // `route get default` is a subprocess: run it off the main thread so it can't stall an animation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let interface = VpnProbe.defaultInterface()
            let address = SystemInfo.ipv4Address(of: interface)
            DispatchQueue.main.async {
                guard let self else { return }
                self.vpnProbing = false
                self.applyVpnState(interface: interface, address: address)
            }
        }
    }

    private func applyVpnState(interface: String, address: String) {
        hudModel.update(\.networkInterface, interface)
        hudModel.update(\.networkAddress, address)
        let warning = VpnProbe.warning(for: interface)
        hudModel.update(\.vpnWarning, warning ?? "")
        let auto = hudModel.autoPauseVpn
        if auto, warning != nil, isRunning(), !testing, !busy, !updating {
            pausedByVpn = true
            runPrivileged(script: "stop.sh", arguments: []) { [weak self] failure in
                if failure == nil { self?.showNotice("Nimbus на паузе: активен VPN") }
            }
            return
        }
        if auto, warning == nil, pausedByVpn, !isRunning(), !testing, !busy, !updating {
            pausedByVpn = false
            runPrivileged(script: "install.sh", arguments: [dataRoot.path]) { [weak self] failure in
                if failure == nil { self?.showNotice("VPN выключен, Nimbus снова включён") }
            }
            return
        }
        if warning == nil, isRunning() { pausedByVpn = false }
    }

    private func toggleAutoPause() {
        do {
            let next = readState(from: dataRoot.appendingPathComponent("vpn-autopause")) != "1"
            try writeState(next ? "1" : "0", to: dataRoot.appendingPathComponent("vpn-autopause"))
            if !next { pausedByVpn = false }
            refreshHUD()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func updateLists() {
        if busy || testing || hudModel.updatingLists { return }
        hudModel.updatingLists = true
        refreshHUD()
        let listsDir = dataRoot.appendingPathComponent("lists", isDirectory: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var failure: String?
            var updated: [String] = []
            do {
                var files: [String: String] = [:]
                for name in UpstreamLists.files {
                    guard let url = URL(string: UpstreamLists.baseURL + name) else { continue }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 20
                    request.setValue("Nimbus", forHTTPHeaderField: "User-Agent")
                    let data = try self.urlData(request)
                    let text = String(data: data, encoding: .utf8) ?? ""
                    if let reason = UpstreamLists.validate(name: name, text: text) { throw NSError(domain: "Nimbus.Lists", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
                    files[name] = UserListIO.normalize(text)
                    updated.append(name)
                }
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let backup = listsDir.appendingPathComponent("backup-\(stamp)", isDirectory: true)
                try self.fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
                try self.fileManager.createDirectory(at: listsDir, withIntermediateDirectories: true)
                for (name, text) in files {
                    let dest = listsDir.appendingPathComponent(name)
                    if self.fileManager.fileExists(atPath: dest.path) {
                        try self.fileManager.copyItem(at: dest, to: backup.appendingPathComponent(name))
                    }
                    let body = text.hasSuffix("\n") ? text : text + "\n"
                    try body.write(to: dest, atomically: true, encoding: .utf8)
                }
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.hudModel.updatingLists = false
                if let failure {
                    self.showError(failure)
                } else {
                    self.showNotice("Списки обновлены (\(updated.count))")
                    self.applyIfRunning()
                }
                self.refreshHUD()
            }
        }
    }

    private func urlData(_ request: URLRequest) throws -> Data {
        let session = URLSession(configuration: .ephemeral)
        var resultData: Data?
        var resultError: Error?
        let lock = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            defer { lock.signal() }
            if let error {
                resultError = error
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                resultError = NSError(domain: "Nimbus.Lists", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) для \(request.url?.lastPathComponent ?? "")"])
                return
            }
            resultData = data
        }
        task.resume()
        if lock.wait(timeout: .now() + 25) == .timedOut {
            task.cancel()
            throw NSError(domain: "Nimbus.Lists", code: 2, userInfo: [NSLocalizedDescriptionKey: "Таймаут загрузки списков"])
        }
        if let resultError { throw resultError }
        guard let resultData, !resultData.isEmpty else {
            throw NSError(domain: "Nimbus.Lists", code: 3, userInfo: [NSLocalizedDescriptionKey: "Пустой ответ"])
        }
        return resultData
    }

    private func openDiagnosticsPage() {
        guard !hudModel.diagnosticsRunning else {
            hudModel.page = .diagnostics
            return
        }
        hudModel.page = .diagnostics
        hudModel.diagnostics = []
        hudModel.diagnosticsRunning = true
        hudModel.diagnosticsElapsed = 0
        let started = Date()
        hud.relayout()
        let out = dataRoot.appendingPathComponent("diagnostics.txt")
        try? fileManager.removeItem(at: out)
        runPrivileged(script: "diagnose.sh", arguments: [out.path, String(getuid()), String(getgid())]) { [weak self] failure in
            guard let self else { return }
            let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            self.hudModel.diagnosticsElapsed = Date().timeIntervalSince(started)
            self.hudModel.diagnosticsRunning = false
            self.hudModel.diagnostics = Self.parseDiagnosticRows(text)
            self.hudModel.diagnosticText = Self.formatDiagnosticReport(self.hudModel.diagnostics)
            self.hudModel.page = .diagnostics
            if failure != nil, self.hudModel.diagnostics.isEmpty {
                // keep the error notice from runPrivileged
            }
            self.hud.relayout()
        }
    }

    private static func parseDiagnosticRows(_ text: String) -> [DiagnosticItem] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, ["OK", "WARN", "FAIL"].contains(parts[0]) else { return nil }
            return DiagnosticItem(level: parts[0], name: parts[1], detail: parts.count > 2 ? parts[2] : "")
        }
    }

    private static func formatDiagnosticReport(_ rows: [DiagnosticItem]) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let header = "Nimbus \(version) · \(Date())"
        var lines = [header, ""]
        for row in rows {
            let detail = row.detail.isEmpty ? "" : " — \(row.detail)"
            lines.append("[\(row.level)] \(row.name)\(detail)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func copyDiagnosticsReport() {
        let text = hudModel.diagnosticText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showNotice("Отчёт скопирован")
    }

    private func addListEntry(exclude: Bool) {
        guard let parsed = HostParser.parse(hudModel.listInput) else {
            showError("Не получилось распознать домен или IP")
            return
        }
        let name = UserListIO.file(isIP: parsed.isIP, exclude: exclude)
        let url = dataRoot.appendingPathComponent("lists", isDirectory: true).appendingPathComponent(name)
        do {
            if !fileManager.fileExists(atPath: url.path) { try "".write(to: url, atomically: true, encoding: .utf8) }
            let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try UserListIO.add(current, entry: parsed.value).write(to: url, atomically: true, encoding: .utf8)
            hudModel.listInput = ""
            showNotice(exclude ? "Исключено: \(parsed.value)" : "Добавлено в обход: \(parsed.value)")
            hudModel.userEntries = loadUserEntries()
            applyIfRunning()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func removeListEntry(_ entry: UserEntry) {
        let url = dataRoot.appendingPathComponent("lists", isDirectory: true).appendingPathComponent(entry.file)
        do {
            let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try UserListIO.remove(current, entry: entry.value).write(to: url, atomically: true, encoding: .utf8)
            hudModel.userEntries = loadUserEntries()
            applyIfRunning()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func loadUserEntries() -> [UserEntry] {
        let dir = dataRoot.appendingPathComponent("lists", isDirectory: true)
        var rows: [UserEntry] = []
        for name in [UserListIO.bypassDomains, UserListIO.bypassIpset, UserListIO.excludeDomains, UserListIO.excludeIpset] {
            let text = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
            for value in UserListIO.entries(text) {
                rows.append(UserEntry(file: name, value: value))
            }
        }
        return rows
    }

        private func showInformation(_ message: String) {
        DispatchQueue.main.async {
            self.showNotice(message)
            if let button = self.statusItem.button, !self.hud.isVisible {
                self.hud.show(relativeTo: button)
            }
        }
    }
}
