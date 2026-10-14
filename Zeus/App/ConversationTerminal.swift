import Foundation
import ZeusProtocol

/// A pane is meaningful only together with its original server namespace.
@MainActor struct ConversationTerminalTarget: Equatable {
    let pane: String
    let socket: String
    static func make(session: ConnectedSession?, configuredPane: String?, configuredSocket: String?) -> Self? {
        guard let session, let socket = AppSettings.normalizedTmuxSocket(session.tmuxSocketPath) else { return nil }
        if let configuredPane {
            guard AppSettings.normalizedTmuxSocket(configuredSocket) == socket else { return nil }
            return validated(pane: configuredPane, socket: socket)
        }
        return session.tmuxPane.flatMap { validated(pane: $0, socket: socket) }
    }
    private static func validated(pane: String, socket: String) -> Self? {
        guard !pane.isEmpty, !pane.contains("\0"), !pane.contains("\n"), !pane.hasPrefix("-") else { return nil }
        return .init(pane: pane, socket: socket)
    }
    func command(executable: URL) -> String {
        "/usr/bin/env -u TMUX -u TMUX_PANE " + ManagedSessionController.shellQuote(executable.path)
            + " -u -S " + ManagedSessionController.shellQuote(socket) + " attach -t " + ManagedSessionController.shellQuote(pane)
    }
}

/// Reuses the existing Terminal opener without Apple events, input injection or sending a reply.
@MainActor struct ConversationTerminal {
    var directory = ZeusPaths.appSupport.appendingPathComponent("terminal-commands", isDirectory: true)
    var opener: any ManagedTerminalOpening = NativeManagedTerminalOpener()
    func open(_ target: ConversationTerminalTarget, executable: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(UUID().uuidString + ".command")
        try Data(("#!/bin/sh\nexec " + target.command(executable: executable) + "\n").utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        try await opener.open(commandFile: file)
    }
}
