import Foundation
import Security
import Darwin

enum ControlError: Error {
    case invalidInstallation
}

func requireTrusted(_ path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_uid == 0,
          info.st_mode & 0o022 == 0,
          info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR else {
        throw ControlError.invalidInstallation
    }
}

func signingRequirements() throws -> [String: String] {
    for path in ["/Library", "/Library/Application Support", controlRoot, controlRequirementsPath] {
        try requireTrusted(path)
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: controlRequirementsPath))
    guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
        throw ControlError.invalidInstallation
    }
    for key in ["ClientRequirement", "ServiceRequirement"] {
        guard let text = values[key], !text.isEmpty else { throw ControlError.invalidInstallation }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
            throw ControlError.invalidInstallation
        }
    }
    return values
}

func installationOwner() throws -> uid_t {
    for path in ["/Library", "/Library/LaunchDaemons", servicePlist] { try requireTrusted(path) }
    let data = try Data(contentsOf: URL(fileURLWithPath: servicePlist))
    guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          plist["Label"] as? String == "io.github.flowseal.zapretmac",
          let arguments = plist["ProgramArguments"] as? [String], arguments.count == 2,
          arguments[0] == payloadRoot + "/run.sh" else { throw ControlError.invalidInstallation }
    let dataRoot = arguments[1]
    var info = stat()
    guard lstat(dataRoot, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid != 0 else {
        throw ControlError.invalidInstallation
    }
    // Resolve through the account database, never through caller-supplied HOME or paths.
    var account = passwd()
    var result: UnsafeMutablePointer<passwd>?
    var buffer = [CChar](repeating: 0, count: 65536)
    guard getpwuid_r(info.st_uid, &account, &buffer, buffer.count, &result) == 0,
          result != nil, let home = account.pw_dir,
          dataRoot == String(cString: home) + "/Library/Application Support/ZapretMac" else {
        throw ControlError.invalidInstallation
    }
    return info.st_uid
}

func validatePayload() throws {
    for path in ["/Library", "/Library/Application Support", payloadRoot, controlRoot, controlRoot + "/control.sh"] {
        try requireTrusted(path)
    }
    guard let paths = FileManager.default.enumerator(atPath: payloadRoot) else {
        throw ControlError.invalidInstallation
    }
    for case let relative as String in paths { try requireTrusted(payloadRoot + "/" + relative) }
}
