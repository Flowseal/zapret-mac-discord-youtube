import Foundation

final class ZapretService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var strategies: [Strategy] = []
    @Published var selectedStrategyID = ""
    @Published var selectedIPSetMode: IPSetMode = .none
    @Published var lastError: String?
    @Published var lastInfo: String?

    @Published private(set) var isTesting = false
    @Published private(set) var isCancellingTest = false
    @Published private(set) var testProgress = ""

    private let fileManager = FileManager.default
    private let executor = PrivilegedExecutor.shared
    private var refreshTimer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    func bootstrap() throws {
        try initializeUserData()
        strategies = try loadStrategies()
        selectedStrategyID = readState(from: ZapretPaths.selectedStrategyFile)
        selectedIPSetMode = IPSetMode(rawValue: readState(from: ZapretPaths.ipsetModeFile)) ?? .none
        refreshRunningState()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshRunningState() }
        }
    }

    func refreshRunningState() {
        isRunning = checkRunning()
        if isTesting {
            testProgress = readState(from: ZapretPaths.strategyTestProgress)
        }
    }

    func toggleService() {
        if isRunning {
            runPrivileged(script: "stop.sh", arguments: [])
        } else {
            runPrivileged(script: "install.sh", arguments: [ZapretPaths.dataRoot.path])
        }
    }

    func selectStrategy(_ id: String) {
        guard selectedStrategyID != id else { return }
        do {
            try writeState(id, to: ZapretPaths.selectedStrategyFile)
            selectedStrategyID = id
            applyIfRunning()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func selectIPSetMode(_ mode: IPSetMode) {
        guard selectedIPSetMode != mode else { return }
        do {
            try writeState(mode.rawValue, to: ZapretPaths.ipsetModeFile)
            selectedIPSetMode = mode
            applyIfRunning()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func openListsFolder() {
        NSWorkspace.shared.open(ZapretPaths.listsURL)
    }

    func startStrategyTest() {
        guard !isTesting, !isBusy else { return }
        try? fileManager.removeItem(at: ZapretPaths.strategyTestReport)
        try? fileManager.removeItem(at: ZapretPaths.strategyTestCancel)
        isTesting = true
        isCancellingTest = false
        testProgress = ""
        runPrivileged(
            script: "test-strategies.sh",
            arguments: [ZapretPaths.dataRoot.path, String(getuid()), String(getgid())]
        ) { [weak self] failure in
            guard let self else { return }
            let wasCancelled = self.isCancellingTest
            self.isTesting = false
            self.isCancellingTest = false
            self.testProgress = ""
            try? self.fileManager.removeItem(at: ZapretPaths.strategyTestCancel)
            guard failure == nil else { return }
            if wasCancelled {
                self.lastInfo = "Тест остановлен. Настройки восстановлены."
                return
            }
            guard let text = try? String(contentsOf: ZapretPaths.strategyTestReport, encoding: .utf8) else {
                self.lastError = "Отчёт тестирования не найден"
                return
            }
            let best = text.split(whereSeparator: \.isNewline)
                .first { $0.hasPrefix("Лучшая:") }
                .map(String.init) ?? "Тест завершён"
            NSWorkspace.shared.open(ZapretPaths.strategyTestReport)
            self.lastInfo = best
            self.refreshSelectionFromDisk()
        }
    }

    func cancelStrategyTest() {
        guard isTesting, !isCancellingTest else { return }
        do {
            try Data().write(to: ZapretPaths.strategyTestCancel, options: .atomic)
            isCancellingTest = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    func showPendingUpdateErrorIfNeeded() {
        guard let message = try? String(contentsOf: ZapretPaths.updateError, encoding: .utf8),
              !message.isEmpty else { return }
        try? fileManager.removeItem(at: ZapretPaths.updateError)
        lastError = message
    }

    func refreshSelectionFromDisk() {
        selectedStrategyID = readState(from: ZapretPaths.selectedStrategyFile)
        selectedIPSetMode = IPSetMode(rawValue: readState(from: ZapretPaths.ipsetModeFile)) ?? .none
    }

    private func initializeUserData() throws {
        try fileManager.createDirectory(at: ZapretPaths.listsURL, withIntermediateDirectories: true)
        let defaults = ZapretPaths.payloadURL.appendingPathComponent("default-lists", isDirectory: true)
        for name in try fileManager.contentsOfDirectory(atPath: defaults.path) {
            let target = ZapretPaths.listsURL.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: target.path) {
                try fileManager.copyItem(at: defaults.appendingPathComponent(name), to: target)
            }
        }
        if !fileManager.fileExists(atPath: ZapretPaths.selectedStrategyFile.path) {
            try writeState("general-simple-fake", to: ZapretPaths.selectedStrategyFile)
        }
        if !fileManager.fileExists(atPath: ZapretPaths.ipsetModeFile.path) {
            try writeState(IPSetMode.none.rawValue, to: ZapretPaths.ipsetModeFile)
        }
    }

    private func loadStrategies() throws -> [Strategy] {
        let text = try String(
            contentsOf: ZapretPaths.payloadURL.appendingPathComponent("strategies.tsv"),
            encoding: .utf8
        )
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return fields.count == 2 ? Strategy(id: fields[0], name: fields[1]) : nil
        }
    }

    private func applyIfRunning() {
        if isRunning {
            runPrivileged(script: "restart.sh", arguments: [])
        }
    }

    private func checkRunning() -> Bool {
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

    private func runPrivileged(
        script: String,
        arguments: [String],
        completion: ((String?) -> Void)? = nil
    ) {
        if isBusy { return }
        isBusy = true
        lastError = nil

        let payload = ZapretPaths.payloadURL
        let dataArguments = arguments

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var failure: String?
            let stagingRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("ZapretMac-\(UUID().uuidString)", isDirectory: true)
            let stagedPayload = stagingRoot.appendingPathComponent("Payload", isDirectory: true)

            do {
                try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: payload, to: stagedPayload)
                try makePayloadExecutable(at: stagedPayload)

                var commandArguments = [stagedPayload.path]
                if script == "install.sh" || script == "test-strategies.sh" {
                    commandArguments = [stagedPayload.path] + dataArguments
                } else {
                    commandArguments = dataArguments
                }

                let command = (["/bin/sh", stagedPayload.appendingPathComponent(script).path] + commandArguments)
                    .map(self.executor.shellQuote)
                    .joined(separator: " ")
                let result = try self.executor.execute(command: command + " 2>&1")

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

            try? FileManager.default.removeItem(at: stagingRoot)

            DispatchQueue.main.async {
                self.isBusy = false
                self.refreshRunningState()
                if script != "test-strategies.sh" {
                    self.refreshSelectionFromDisk()
                }
                if let failure {
                    self.lastError = failure
                }
                completion?(failure)
            }
        }
    }

    private func makePayloadExecutable(at payload: URL) throws {
        let fileManager = FileManager.default
        let names = [
            "install.sh", "run.sh", "restart.sh", "stop.sh",
            "test-strategies.sh", "update-app.sh", "watchdog.sh"
        ]
        for name in names {
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: payload.appendingPathComponent(name).path
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: payload.appendingPathComponent("bin/utunws").path
        )
    }

    private func serviceDiagnostics() -> String {
        for name in ["engine.log", "zapret.log"] {
            let url = ZapretPaths.systemRoot.appendingPathComponent(name)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let lines = text.split(whereSeparator: \.isNewline).suffix(18)
                if !lines.isEmpty { return lines.joined(separator: "\n") }
            }
        }
        return ""
    }
}

import AppKit
