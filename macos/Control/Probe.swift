import Foundation

// Installed diagnostics deliberately expose no start/stop command-line interface.
@main struct ProbeMain {
    static func main() {
        guard CommandLine.arguments.count == 1 else { exit(64) }
        let result = callZapretControl(.ping)
        print(result.output)
        exit(result.status)
    }
}
