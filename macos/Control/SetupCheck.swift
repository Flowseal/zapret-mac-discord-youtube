import Foundation
import Darwin

// Used by Installer only; no supplied paths or usernames are accepted.
@main struct SetupCheck {
    static func main() {
        do {
            print(try installationOwner())
        } catch {
            fputs("An existing ZapretMac installation configured for a local user is required.\n", stderr)
            exit(78)
        }
    }
}
