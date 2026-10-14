import Darwin
import Foundation
import ZeusProtocol

/// Read-only authorization snapshot: explicit user selection plus a registered agent lifetime.
struct OwnSessionScreenDestination: Equatable, Sendable {
    let sessionKey: String
    let sessionID: UUID
    let agent: AgentKind
    let pane: String
    let socket: String
    let agentPID: Int
    let agentStart: UInt64
}

@MainActor
protocol OwnSessionScreenReading {
    func capture(_ destination: OwnSessionScreenDestination, stillAllowed: @MainActor () -> Bool) async throws -> ManagedPaneSnapshot
}

/// Never targets an ambient server, writes input, sets ownership options or adopts a pane.
/// The selected pane must still contain the registered agent lifetime before and after capture.
@MainActor
struct OwnSessionScreenReader: OwnSessionScreenReading {
    struct ProcessIdentity: Equatable, Sendable { let pid: Int; let parent: Int; let start: UInt64 }
    private struct PaneIdentity: Equatable { let fields: [String]; let process: ProcessIdentity; let server: ProcessIdentity }
    let runner: any ProcessRunning
    let executable: @MainActor () -> URL?
    let process: @Sendable (Int) -> ProcessIdentity?
    let environment: [String: String]
    init(runner: any ProcessRunning = FoundationProcessRunner(), executable: @escaping @MainActor () -> URL? = { TmuxExecutable.resolve() },
         process: @escaping @Sendable (Int) -> ProcessIdentity? = Self.processIdentity,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.runner = runner; self.executable = executable; self.process = process; self.environment = environment
    }
    nonisolated static func processIdentity(_ pid: Int) -> ProcessIdentity? {
        guard let native = Int32(exactly: pid), native > 1 else { return nil }
        var info = proc_bsdinfo(); let size = MemoryLayout.size(ofValue: info)
        guard proc_pidinfo(native, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size, info.pbi_start_tvsec > 0 else { return nil }
        return .init(pid: pid, parent: Int(info.pbi_ppid), start: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }
    nonisolated static func normalizedSocket(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/"), !value.contains("\0") else { return nil }
        return URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL.path
    }
    func capture(_ destination: OwnSessionScreenDestination, stillAllowed: @MainActor () -> Bool) async throws -> ManagedPaneSnapshot {
        guard destination.pane.hasPrefix("%"), let number = UInt64(destination.pane.dropFirst()), destination.pane == "%\(number)",
              Self.normalizedSocket(destination.socket) == destination.socket, let executable = executable() else { throw ManagedSessionError.ownershipChanged }
        var env = environment; env.removeValue(forKey: "TMUX"); env.removeValue(forKey: "TMUX_PANE")
        func read(_ args: [String]) async throws -> String {
            try Task.checkCancellation()
            guard stillAllowed() else { throw CancellationError() }
            let result = try await runner.run(executable: executable, arguments: ["-u", "-S", destination.socket] + args, input: nil, environment: env)
            try Task.checkCancellation()
            guard stillAllowed() else { throw CancellationError() }
            guard result.status == 0 else { throw ConnectorError.processExit(result.status) }
            return String(decoding: result.stdout, as: UTF8.self)
        }
        func inspect() async throws -> PaneIdentity {
            let value = try await read(["display-message", "-p", "-t", destination.pane, "#{socket_path}\t#{pane_id}\t#{pid}\t#{session_id}\t#{pane_pid}\t#{pane_dead}"])
            let fields = value.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
            guard fields.count == 6, Self.normalizedSocket(fields[0]) == destination.socket, fields[1] == destination.pane, fields[5] == "0",
                  let serverPID = Int(fields[2]), let server = process(serverPID), let panePID = Int(fields[4]), let pane = process(panePID),
                  let agent = process(destination.agentPID), agent.start == destination.agentStart else { throw ManagedSessionError.ownershipChanged }
            var ancestor = agent, found = ancestor.pid == panePID
            for _ in 0..<16 where !found {
                guard ancestor.parent > 1, ancestor.parent != ancestor.pid, let next = process(ancestor.parent) else { break }
                ancestor = next; found = ancestor == pane
            }
            guard found else { throw ManagedSessionError.ownershipChanged }
            return .init(fields: fields, process: pane, server: server)
        }
        let before = try await inspect()
        let metadata = try await read(["display-message", "-p", "-t", destination.pane, "#{cursor_x}|#{cursor_y}|#{pane_width}|#{pane_dead}|#{cursor_flag}|#{bracket_paste_flag}"])
        let screen = try await read(["capture-pane", "-p", "-e", "-t", destination.pane])
        guard before == (try await inspect()) else { throw ManagedSessionError.ownershipChanged }
        return .init(screen: screen, inputMetadata: metadata.trimmingCharacters(in: .newlines))
    }
}
