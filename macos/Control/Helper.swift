import Foundation
import Darwin

private let operationQueue = DispatchQueue(label: "io.github.flowseal.zapretmac.control.operations")

private func execute(_ action: ControlAction, uid: uid_t) -> (Int32, String) {
    do {
        guard ControlPolicy.accepts(uid: uid, owner: try installationOwner()) else { return (77, "Операция не выполнена") }
        try validatePayload()
        if action == .ping { return (0, "OK") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [controlRoot + "/control.sh", action.rawValue]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        var output = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if output.count < 65536 { output.append(chunk.prefix(65536 - output.count)) }
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    } catch { return (78, "Операция не выполнена") }
}

private final class ControlService: NSObject, ZapretControlProtocol {
    private let uid: uid_t
    private let lock = NSLock()
    private var pending = false
    init(uid: uid_t) { self.uid = uid }

    func perform(_ input: String, reply: @escaping (Int32, String) -> Void) {
        guard let action = ControlAction(rawValue: input) else { reply(64, "Операция не выполнена"); return }
        lock.lock()
        if pending { lock.unlock(); reply(75, "Операция не выполнена"); return }
        pending = true
        lock.unlock()
        operationQueue.async {
            let result = execute(action, uid: self.uid)
            self.lock.lock()
            self.pending = false
            self.lock.unlock()
            reply(result.0, result.1)
        }
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let owner = try? installationOwner(),
              ControlPolicy.accepts(uid: connection.effectiveUserIdentifier, owner: owner),
              let requirements = try? signingRequirements(), let clientRequirement = requirements["ClientRequirement"] else {
            return false
        }
        // macOS enforces this against the peer for incoming messages, avoiding PID-reuse checks.
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: ZapretControlProtocol.self)
        connection.exportedObject = ControlService(uid: connection.effectiveUserIdentifier)
        connection.resume()
        return true
    }
}

@main struct HelperMain {
    static func main() {
        guard geteuid() == 0 else { exit(77) }
        umask(0o022)
        let delegate = ListenerDelegate()
        let listener = NSXPCListener(machServiceName: controlServiceName)
        listener.delegate = delegate
        listener.resume()
        withExtendedLifetime((listener, delegate)) { RunLoop.current.run() }
    }
}
