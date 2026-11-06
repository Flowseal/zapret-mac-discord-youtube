import Foundation

@main struct PolicyTests {
    static func main() {
        for owner: uid_t in [1001, 2042, 3077] {
            precondition(ControlPolicy.accepts(uid: owner, owner: owner))
            precondition(!ControlPolicy.accepts(uid: owner + 1, owner: owner))
            precondition(!ControlPolicy.accepts(uid: 0, owner: owner))
        }
        precondition(!ControlPolicy.accepts(uid: 0, owner: 0))
        for command in ["", "install", "test", "update", "Start", "start ", "start\n", "start; id", "/bin/sh", "$(id)", "restart\u{0}start"] {
            precondition(ControlAction(rawValue: command) == nil)
        }
        precondition(ControlAction.forScript("install.sh") == .start)
        precondition(ControlAction.forScript("stop.sh") == .stop)
        precondition(ControlAction.forScript("restart.sh") == .restart)
        precondition(ControlAction.forScript("test-strategies.sh") == nil)
        precondition(ControlAction.forScript("update-app.sh") == nil)
        print("PASS: dynamic owner authorization, exact commands, legacy privileged operations")
    }
}
