import Darwin
import Foundation
import ZeusDesign

/// Optional presentation metadata; robust Terminal execution remains behind the controller.
@MainActor protocol ManagedTerminalPresenting: AnyObject {
    var managedTerminalSocketPath: String? { get }
}

extension ZeusRuntime: ManagedTerminalPresenting {
    var managedTerminalSocketPath: String? { managedController.record?.pane?.socket }
}

/// The command a person reads/copies targets the actual session, with a socket only when needed.
enum ManagedTerminalPresentation {
    static func attach(session: String, socket: String, temporaryDirectory: String = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] ?? "/tmp", userID: UInt32 = getuid()) -> String {
        let directory = temporaryDirectory.isEmpty ? "/tmp" : temporaryDirectory
        let base = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
        let actual = URL(fileURLWithPath: socket).standardizedFileURL
        let parent = actual.deletingLastPathComponent()
        // Resolve just the base: a stopped server's socket or UID directory may no longer exist.
        let actualBase = parent.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let custom = actual.lastPathComponent != "default" || parent.lastPathComponent != "tmux-\(userID)" || actualBase != base
        return ZeusManagedCopy.attachCommand(session: session, socket: custom ? socket : nil)
    }
}
