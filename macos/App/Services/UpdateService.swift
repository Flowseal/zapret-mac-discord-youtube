import CryptoKit
import Foundation

final class UpdateService: ObservableObject {
    @Published private(set) var availableRelease: GitHubRelease?
    @Published private(set) var isChecking = false
    @Published private(set) var isUpdating = false
    @Published var lastError: String?

    private let fileManager = FileManager.default
    private let executor = PrivilegedExecutor.shared
    private var updateTimer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var hasUpdate: Bool { availableRelease != nil }

    func startPeriodicChecks(isServiceRunning: @escaping () -> Bool) {
        checkForUpdate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.checkForUpdate() }
        }
        self.isServiceRunning = isServiceRunning
    }

    private var isServiceRunning: (() -> Bool) = { false }

    func checkForUpdate() {
        if isChecking || isUpdating { return }
        isChecking = true

        let url = URL(
            string: ZapretPaths.releaseURL.absoluteString
                + "?t=\(Int(Date().timeIntervalSince1970 * 1000))&per_page=1"
        )!
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("zapret-mac", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isChecking = false
                guard let response = response as? HTTPURLResponse,
                      response.statusCode == 200,
                      let data,
                      let decoded = try? JSONDecoder().decode([GitHubRelease].self, from: data),
                      let latest = decoded.first,
                      latest.assets.contains(where: { $0.name == ZapretPaths.releaseAssetName }),
                      self.isNewer(latest.tagName, than: self.currentVersion) else {
                    self.availableRelease = nil
                    return
                }
                self.availableRelease = latest
            }
        }.resume()
    }

    func installUpdate() {
        guard let release = availableRelease,
              let asset = release.assets.first(where: { $0.name == ZapretPaths.releaseAssetName }),
              !isUpdating else { return }

        let target = Bundle.main.bundleURL.standardizedFileURL
        guard target.pathExtension == "app",
              !target.path.contains("/AppTranslocation/") else {
            lastError = "Переместите ZapretMac.app в папку Applications и запустите снова"
            return
        }

        isUpdating = true
        lastError = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let source = self.fileManager.temporaryDirectory
                .appendingPathComponent("ZapretMac-\(UUID().uuidString).zip")
            do {
                let arguments = [
                    "-fL", "--connect-timeout", "5", "-A", "zapret-mac",
                    "-o", source.path, asset.downloadURL.absoluteString
                ]
                do {
                    try self.runProcess(
                        "/usr/bin/curl",
                        arguments: ["--resolve", "release-assets.githubusercontent.com:443:185.199.109.133", "--max-time", "30"] + arguments
                    )
                } catch {
                    try? self.fileManager.removeItem(at: source)
                    try self.runProcess("/usr/bin/curl", arguments: ["--max-time", "120"] + arguments)
                }
                try self.prepareAndLaunchUpdate(
                    source: source,
                    release: release,
                    asset: asset,
                    target: target,
                    serviceRunning: self.isServiceRunning()
                )
                DispatchQueue.main.async { NSApp.terminate(nil) }
            } catch {
                try? self.fileManager.removeItem(at: source)
                DispatchQueue.main.async {
                    self.isUpdating = false
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    private func isNewer(_ candidate: String, than installed: String) -> Bool {
        bundledVersion(candidate).compare(
            displayVersion(installed),
            options: [.numeric, .caseInsensitive]
        ) == .orderedDescending
    }

    private func displayVersion(_ version: String) -> String {
        version.first == "v" || version.first == "V" ? String(version.dropFirst()) : version
    }

    private func bundledVersion(_ releaseVersion: String) -> String {
        displayVersion(releaseVersion).split(separator: "-", maxSplits: 1).first.map(String.init)
            ?? displayVersion(releaseVersion)
    }

    private func prepareAndLaunchUpdate(
        source: URL,
        release: GitHubRelease,
        asset: GitHubReleaseAsset,
        target: URL,
        serviceRunning: Bool
    ) throws {
        let workRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ZapretMac-Update-\(UUID().uuidString)", isDirectory: true)
        let archive = workRoot.appendingPathComponent(ZapretPaths.releaseAssetName)
        let extracted = workRoot.appendingPathComponent("extracted", isDirectory: true)

        do {
            try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: archive)
            try verifyDigest(of: archive, expected: asset.digest)
            try runProcess("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extracted.path])
            let app = extracted.appendingPathComponent("ZapretMac.app", isDirectory: true)
            try verifyUpdate(app, version: release.tagName)

            let updater = ZapretPaths.payloadURL.appendingPathComponent("update-app.sh")
            let updaterCopy = workRoot.appendingPathComponent("update-app.sh")
            try fileManager.copyItem(at: updater, to: updaterCopy)

            let log = ZapretPaths.updateLog
            let command = ([
                "/usr/bin/nohup", "/bin/sh", updaterCopy.path, app.path, target.path,
                String(ProcessInfo.processInfo.processIdentifier), workRoot.path,
                serviceRunning ? "1" : "0", ZapretPaths.dataRoot.path,
                String(getuid()), String(getgid())
            ].map(executor.shellQuote).joined(separator: " ")) + " >\(executor.shellQuote(log.path)) 2>&1 </dev/null &"

            let result = try executor.execute(command: command)
            guard result.status == 0 else {
                throw NSError(
                    domain: "ZapretMac.Update",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: result.output.isEmpty
                        ? "Не удалось запустить установку обновления"
                        : result.output]
                )
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
            throw NSError(
                domain: "ZapretMac.Update",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Контрольная сумма обновления не совпала"]
            )
        }
    }

    private func verifyUpdate(_ app: URL, version: String) throws {
        guard fileManager.fileExists(atPath: app.path),
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let bundledVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              displayVersion(bundledVersion) == self.bundledVersion(version) else {
            throw NSError(
                domain: "ZapretMac.Update",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Архив релиза содержит неподходящую версию приложения"]
            )
        }
        try runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", app.path])
        let executable = app.appendingPathComponent("Contents/MacOS/ZapretMac")
        try runProcess("/usr/bin/lipo", arguments: [executable.path, "-verify_arch", "x86_64", "arm64"])
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
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "ZapretMac.Update",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false
                    ? message!
                    : "Проверка обновления не пройдена"]
            )
        }
    }
}

import AppKit
