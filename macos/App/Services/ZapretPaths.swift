import Foundation

enum ZapretPaths {
    static let dataRootName = "ZapretMac"
    static let systemRoot = URL(fileURLWithPath: "/Library/Application Support/ZapretMac", isDirectory: true)
    static let releaseURL = URL(string: "https://api.github.com/repos/Flowseal/zapret-mac-discord-youtube/releases")!
    static let releaseAssetName = "ZapretMac-macOS-universal.zip"

    static var dataRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dataRootName, isDirectory: true)
    }

    static var payloadURL: URL {
        Bundle.main.resourceURL!.appendingPathComponent("Payload", isDirectory: true)
    }

    static var listsURL: URL {
        dataRoot.appendingPathComponent("lists", isDirectory: true)
    }

    static var selectedStrategyFile: URL {
        dataRoot.appendingPathComponent("selected-strategy")
    }

    static var ipsetModeFile: URL {
        dataRoot.appendingPathComponent("ipset-mode")
    }

    static var strategyTestReport: URL {
        dataRoot.appendingPathComponent("strategy-test.txt")
    }

    static var strategyTestProgress: URL {
        dataRoot.appendingPathComponent("strategy-test-progress")
    }

    static var strategyTestCancel: URL {
        dataRoot.appendingPathComponent("strategy-test-cancel")
    }

    static var updateLog: URL {
        dataRoot.appendingPathComponent("update.log")
    }

    static var updateError: URL {
        dataRoot.appendingPathComponent("update-error")
    }
}
