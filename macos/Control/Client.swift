import Foundation

func callZapretControl(_ action: ControlAction, timeout: TimeInterval = 40) -> (status: Int32, output: String) {
    guard let requirements = try? signingRequirements(), let serviceRequirement = requirements["ServiceRequirement"] else {
        return (69, "")
    }
    let connection = NSXPCConnection(machServiceName: controlServiceName, options: .privileged)
    connection.remoteObjectInterface = NSXPCInterface(with: ZapretControlProtocol.self)
    connection.setCodeSigningRequirement(serviceRequirement)
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var result: (Int32, String)?
    func finish(_ status: Int32, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        if result == nil {
            result = (status, message)
            semaphore.signal()
        }
    }
    connection.invalidationHandler = { finish(69, "") }
    connection.interruptionHandler = { finish(69, "") }
    connection.resume()
    defer { connection.invalidate() }
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in finish(69, "") }) as? ZapretControlProtocol else {
        return (69, "")
    }
    proxy.perform(action.rawValue) { status, message in finish(status, message) }
    if semaphore.wait(timeout: .now() + timeout) == .timedOut { finish(75, "Операция не выполнена") }
    lock.lock()
    defer { lock.unlock() }
    return result ?? (69, "")
}
