import Foundation
import Observation

struct TmuxPane: Identifiable, Equatable, Sendable {
    let id: String
    let location: String
    let command: String
    let path: String
    var socketPath: String? = nil
    var label: String { "\(id) · \(location) · \(command) · \(path)" }

    /// The final field consumes the rest of the line, including spaces in the working directory.
    static func parse(_ output: String, socketPath: String? = nil) -> [TmuxPane] {
        var seen: Set<String> = []
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
            guard fields.count == 4, fields[0].first == "%", fields[0].dropFirst().allSatisfy(\.isNumber),
                  fields[0].count > 1, fields[1].contains(":"), fields[1].contains("."),
                  !fields[3].isEmpty, seen.insert(fields[0]).inserted else { return nil }
            return TmuxPane(id: fields[0], location: fields[1], command: fields[2], path: fields[3], socketPath: socketPath)
        }
    }
}

@MainActor @Observable
final class TmuxPaneDiscovery {
    private(set) var panes: [TmuxPane] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var guidance: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let executable: URL?
    @ObservationIgnored private let runner: any ProcessRunning
    @ObservationIgnored private let environment: [String: String]

    init(executable: URL? = nil, runner: any ProcessRunning = FoundationProcessRunner(),
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable; self.runner = runner; self.environment = environment
    }
    nonisolated static func resolveExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        TmuxExecutable.resolve(paths: TmuxExecutable.searchPaths(environment: environment))
    }
    /// No ambient/default server fallback: an absent assistant namespace cannot identify a pane.
    func refresh(socketPath: String?, assistantName: String = "assistant") async {
        let request = UUID(); generation = request; panes = []; error = nil; guidance = nil; isLoading = false
        guard let socket = AppSettings.normalizedTmuxSocket(socketPath) else {
            guidance = "Choose the \(assistantName) session under Assistant session to list its panes."; return
        }
        // An already-open Settings pane must see installs and removals on Refresh.
        guard let executable = executable ?? Self.resolveExecutable(environment: environment) else {
            error = "tmux was not found. Install it, or choose another delivery method."; return
        }
        isLoading = true
        defer { if generation == request { isLoading = false } }
        var environment = environment
        environment.removeValue(forKey: "TMUX"); environment.removeValue(forKey: "TMUX_PANE")
        do {
            let result = try await runner.run(executable: executable,
                arguments: ["-u", "-S", socket, "list-panes", "-a", "-F", "#{pane_id} #{session_name}:#{window_index}.#{pane_index} #{pane_current_command} #{pane_current_path}"],
                input: nil, environment: environment)
            guard generation == request, !Task.isCancelled else { return }
            if result.status == 0 { panes = TmuxPane.parse(String(decoding: result.stdout, as: UTF8.self), socketPath: socket) }
            else { error = "Couldn't list this assistant's Terminal panes. Check its connection, then try again." }
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            self.error = "Couldn't list this assistant's Terminal panes. Check its connection, then try again."
        }
    }
}
