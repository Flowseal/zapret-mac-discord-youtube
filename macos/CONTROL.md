# Optional privileged control service

This is a source-level add-on for Flowseal ZapretMac 1.1.2, requiring macOS 14 or later. The app's menus, text, icons, version display and update dialogs remain identical to upstream. Only the start/stop/restart implementation changes.

## Build and install

Run `python3 macos/build-control.py` with Python 3 and the Apple command-line developer tools installed. The engine, app, helper and diagnostics are built from this source tree for both arm64 and x86_64. No installed app, local backup or user lists are used as build inputs.

The output is `dist/ZapretMac-Control.pkg`, `dist/Restore-ZapretMac.pkg`, `dist/LICENSE` and `dist/SHA256SUMS`. Install the first package over an existing configured ZapretMac 1.1.2 in `/Applications`. It requires administrator authorization. The account is derived from the existing system service and validated against the operating system account database. The package contains no predefined account, UID or home directory.

The optional `Build privileged control preview` GitHub Actions workflow runs tests and builds the universal packages on pushes to `feature/privileged-control` and relevant pull requests. It uploads temporary workflow artifacts, not a public release, and requests only read access to repository contents. Manual dispatch becomes available when this workflow exists on the repository's default branch. The original upstream build workflow remains separate.

This package is an **add-on for an existing installation**, not a complete first-run installer. A fresh installation and an upstream lifecycle integration still need to be designed before proposing this as the project's default distribution.

The restore package removes the helper and restores an app built from the original 1.1.2 code path. It preserves the existing network engine configuration and user lists. Installer receipts and the diagnostic log can remain. If migrating from an earlier local prototype, legacy service identifiers are discovered from root-owned configuration rather than embedded in the source.

## Authorization

The root LaunchDaemon exposes only `ping`, `start`, `stop` and `restart` over a privileged XPC service. It accepts the owner of the existing Zapret data directory only after validating that directory against the account database and root-owned service configuration. It rechecks ownership when executing operations.

Both XPC peers enforce code-signing requirements with `NSXPCConnection.setCodeSigningRequirement`. The installer places the approved app, read-only diagnostic tool and helper code-directory hashes in a root-owned configuration. Both universal binary slices are pinned. Matching only a bundle identifier, a UID or a PID is insufficient. The diagnostic executable accepts no arguments and sends only `ping`.

Before an operation, the helper checks ownership, permissions and symbolic links in the installed privileged payload. Caller-supplied shell commands, executable paths and environment variables are not accepted. The app waits at most 40 seconds for a reply. A client timeout does not cancel an already running operation; bounded server-side execution remains an item for further review.

Missing, disabled or differently signed helper installations fall back to the original admin authorization path. An error returned by an accepted operation does not trigger a second execution. An official app update can replace this backend modification; the original update interface is deliberately preserved. Reinstalling a matching add-on package is necessary to restore this feature after such an update.

## Verification

- `python3 macos/Tests/test_source.py` checks that all original UI and unrelated app code remain unchanged.
- `python3 macos/Tests/test_controller.py` exercises the real shell controller with isolated command doubles, including start, idempotent start, restart, stop and cleanup after failures.
- `PolicyTests.swift` verifies dynamically selected account ownership and exact permitted commands.
- `python3 macos/Tests/check_privacy.py` scans source and uncompressed distribution payloads for identifiers from the build host.
- The build verifies universal architectures and code-signing requirements, including rejection of a differently signed executable.
- Installer performs a genuine XPC ping as the selected account and checks rejection of a differently signed diagnostic executable.

Compilation for Intel is not a substitute for running on an Intel Mac. Reboot, sleep/wake, multiple user sessions, minimum supported macOS, interrupted installation/update and actual rollback need separate integration testing before a public release. This work is not an independent security audit.

## Publication requirements and research

1. Preserve the upstream MIT license and copyright notices in source and distributed copies. See the repository `LICENSE`.
2. Publish only source and intentionally built release artifacts. Do not include user lists, machine logs, backups, `.DS_Store`, compiler logs, credentials or signing secrets. Build paths are remapped in compiled code.
3. Preserve the existing supported architectures and OS deployment target. The add-on builds universal binaries and targets macOS 14.
4. Apple documents `SMAppService` as the current service-management API on macOS 13+. The current add-on uses an explicitly authorized package and root LaunchDaemon. For upstream integration, discuss a bundled `SMAppService` daemon, first-run approval, disablement, updates and removal with the maintainer rather than treating a package prototype as a finished lifecycle design.
5. For Developer ID distribution and notarization, use the appropriate Application/Installer certificates, hardened runtime, secure timestamps and `notarytool`/stapling. Do not include debugging entitlements or weaken Gatekeeper/SIP. The default local build uses ad-hoc signatures and is **not notarized**. Setting `ZAPRET_SIGNING_IDENTITY` signs executables; package signing and notarization are separate release steps requiring the publisher's credentials.
6. Review the privileged boundary, lifecycle and failure handling before merging. A successful local run or valid signature is not evidence of a complete security audit.

Sources checked:

- Apple, [NSXPCConnection code-signing requirements](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)).
- Apple, [Updating helper executables](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos).
- Apple, [Managing ongoing background processes](https://developer.apple.com/documentation/appkit/managing-ongoing-background-processes-in-your-mac).
- Apple, [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
- Upstream, [MIT license](https://github.com/Flowseal/zapret-mac-discord-youtube/blob/1.1.2/LICENSE).
