import Foundation

let controlServiceName = "io.github.flowseal.zapretmac.control"
let controlRoot = "/Library/Application Support/ZapretMacControl"
let controlRequirementsPath = controlRoot + "/requirements.plist"
let payloadRoot = "/Library/Application Support/ZapretMac"
let servicePlist = "/Library/LaunchDaemons/io.github.flowseal.zapretmac.plist"

@objc(ZapretControlProtocol) protocol ZapretControlProtocol {
    func perform(_ action: String, reply: @escaping (Int32, String) -> Void)
}

enum ControlAction: String {
    case ping, start, stop, restart

    static func forScript(_ script: String) -> ControlAction? {
        switch script {
        case "install.sh": return .start
        case "stop.sh": return .stop
        case "restart.sh": return .restart
        default: return nil
        }
    }
}

enum ControlPolicy {
    static func accepts(uid: uid_t, owner: uid_t) -> Bool { owner != 0 && uid == owner }
}
