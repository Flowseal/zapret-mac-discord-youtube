import Foundation
import Security

@_silgen_name("AuthorizationExecuteWithPrivileges")
private func executeWithPrivileges(
    _ authorization: AuthorizationRef,
    _ path: UnsafePointer<CChar>,
    _ flags: AuthorizationFlags,
    _ arguments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>>,
    _ pipe: UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>
) -> OSStatus

struct PrivilegedResult {
    let status: Int32
    let output: String
}

final class PrivilegedExecutor: @unchecked Sendable {
    static let shared = PrivilegedExecutor()

    private let lock = NSLock()
    private var authorization: AuthorizationRef?

    deinit {
        if let authorization {
            AuthorizationFree(authorization, [.destroyRights])
        }
    }

    private func acquireAuthorization() throws -> AuthorizationRef {
        lock.lock()
        defer { lock.unlock() }

        if let authorization {
            return authorization
        }

        var auth: AuthorizationRef?
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
        return auth
    }

    func execute(command: String) throws -> PrivilegedResult {
        let auth = try acquireAuthorization()

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
        guard let range = text.range(of: marker, options: .backwards) else {
            return PrivilegedResult(status: 1, output: text)
        }
        let statusText = text[range.upperBound...].prefix { $0.isNumber }
        let exitStatus = Int32(statusText) ?? 1
        text.removeSubrange(range.lowerBound...)
        return PrivilegedResult(
            status: exitStatus,
            output: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
