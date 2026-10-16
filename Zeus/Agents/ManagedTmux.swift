import Darwin
import Foundation
import ZeusDesign
import ZeusProtocol

/// Captured from one owned pane, not from terminal text. Dead signal and exit status are separate.
struct ManagedPane: Codable, Equatable, Sendable {
    var name: String
    var id: String
    var socket: String
    var serverPID: Int
    var sessionNumber: String
    var pid: Int
    var startTime: UInt64
    var dead: Bool
    var exitStatus: Int?
    var signal: String?
}

struct ManagedTmuxSession: Sendable { var name: String; var owner: String }

protocol ManagedSessionHosting: Sendable {
    func sessions() async throws -> [ManagedTmuxSession]
    func inspect(name: String, owner: String, pane: ManagedPane?) async throws -> ManagedPane?
    func create(name: String, owner: String, folder: String) async throws -> ManagedPane
    func launch(_ pane: ManagedPane, owner: String, command: ManagedLaunchCommand, folder: String) async throws -> ManagedPane
    func requestExit(_ pane: ManagedPane, owner: String) async throws
    func removePane(_ pane: ManagedPane, owner: String) async throws
    func capture(_ pane: ManagedPane, owner: String) async throws -> ManagedPaneSnapshot
    func conversationEnvironment(_ pane: ManagedPane, owner: String) async throws -> [String: String]
    func answerPrompt(_ pane: ManagedPane, owner: String, agent: AgentKind, scope: String,
                      fingerprint: String, optionID: String,
                      stillAllowed: @MainActor @Sendable () -> Bool) async throws -> ManagedPromptAnswerResult
}

extension ManagedSessionHosting {
    func capture(_ pane: ManagedPane, owner: String) async throws -> ManagedPaneSnapshot { .init(screen: "", inputMetadata: "") }
    func conversationEnvironment(_ pane: ManagedPane, owner: String) async throws -> [String: String] { [:] }
    func answerPrompt(_ pane: ManagedPane, owner: String, agent: AgentKind, scope: String,
                      fingerprint: String, optionID: String,
                      stillAllowed: @MainActor @Sendable () -> Bool) async throws -> ManagedPromptAnswerResult { .changed }
}

/// All clients clear inherited TMUX. Tests supply a private -S namespace; production uses default.
struct ManagedTmux: ManagedSessionHosting {
    let executable: URL
    let runner: any ProcessRunning
    var environment: [String: String]
    var testSocket: String?
    init(executable: URL, runner: any ProcessRunning = FoundationProcessRunner(), environment: [String: String] = ProcessInfo.processInfo.environment, testSocket: String? = nil) {
        self.executable = executable; self.runner = runner; self.environment = environment; self.testSocket = testSocket
    }
    private func run(_ args: [String], socket: String? = nil) async throws -> ProcessResult {
        var env = environment; env.removeValue(forKey: "TMUX"); env.removeValue(forKey: "TMUX_PANE")
        env["LANG"] = "en_US.UTF-8"; env["LC_CTYPE"] = "UTF-8"; env["LC_ALL"] = "en_US.UTF-8"
        let path = socket ?? testSocket
        return try await runner.run(executable: executable, arguments: ["-u"] + (path.map { ["-S", $0] } ?? []) + args, input: nil, environment: env)
    }
    private func checked(_ args: [String], socket: String? = nil, preserveRows: Bool = false) async throws -> String {
        let result = try await run(args, socket: socket)
        guard result.status == 0 else { throw ManagedSessionError.terminalCommand("tmux: " + String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
        let text = String(decoding: result.stdout, as: UTF8.self)
        return preserveRows ? text : text.trimmingCharacters(in: .newlines)
    }
    func sessions() async throws -> [ManagedTmuxSession] {
        let result = try await run(["list-sessions", "-F", "#{session_name}\t#{@zeus-owner}"])
        if result.status != 0 {
            let error = String(decoding: result.stderr, as: UTF8.self)
            if error.contains("No such file or directory") || error.contains("no server running") || error.contains("no sessions") { return [] }
            throw ManagedSessionError.terminalCommand("Couldn't inspect the tmux server: " + error)
        }
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").compactMap {
            let fields = $0.split(separator: "\t", omittingEmptySubsequences: false)
            return fields.count == 2 ? .init(name: String(fields[0]), owner: String(fields[1])) : nil
        }
    }
    func inspect(name: String, owner: String, pane: ManagedPane?) async throws -> ManagedPane? {
        try await inspectPane(name: name, owner: owner, pane: pane, createdID: nil)
    }
    private func inspectPane(name: String, owner: String, pane: ManagedPane?, createdID: String?) async throws -> ManagedPane? {
        let socket = pane?.socket
        // Option commands do not honor the =name exact-target syntax: with -q,
        // show-options silently returns an empty marker for a perfectly owned session.
        // Resolve name, immutable ID and owner together; only genuinely missing markers
        // take the interrupted-launch recovery path. Never use prefix-matched names.
        let sessions = try await run(["list-sessions", "-F", "#{session_name}\t#{session_id}\t#{@zeus-owner}"], socket: socket)
        if sessions.status != 0 {
            let message = String(decoding: sessions.stderr, as: UTF8.self)
            if message.contains("No such file or directory") || message.contains("no server running") || message.contains("no sessions") { return nil }
            throw ManagedSessionError.terminalCommand("Couldn't inspect managed tmux: " + message)
        }
        let entries = String(decoding: sessions.stdout, as: UTF8.self).split(separator: "\n")
        guard let sessionFields = entries.map({ $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) })
            .first(where: { $0.count == 3 && $0[0] == name }) else { return nil }
        let sessionID = sessionFields[1]
        guard sessionID.hasPrefix("$"), Int(sessionID.dropFirst()) != nil else { throw ManagedSessionError.ownershipChanged }
        var token = sessionFields[2]
        if token.isEmpty {
            // Recover only a launch interrupted before its session option was saved.
            let result = try await run(["show-environment", "-t", sessionID, "ZEUS_MANAGED_OWNER"], socket: socket)
            let marker = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
            guard result.status == 0, marker == "ZEUS_MANAGED_OWNER=" + owner else { throw ManagedSessionError.ownershipChanged }
            _ = try await checked(["set-option", "-t", sessionID, "@zeus-owner", owner], socket: socket); token = owner
        }
        guard token == owner else { throw ManagedSessionError.ownershipChanged }
        let target: String
        if let pane { target = pane.id }
        else if let createdID { target = createdID }
        else {
            // A pane marker proves the launched process lifetime, not every later
            // respawn in the same pane. Ignore human replacements during recovery.
            let candidates = try await checked(["list-panes", "-s", "-t", "=" + name, "-F", "#{pane_id}"], socket: socket).split(separator: "\n").map(String.init)
            var launched: [ManagedPane] = []
            for id in candidates {
                guard try await checked(["show-options", "-p", "-qv", "-t", id, "@zeus-launched-owner"], socket: socket) == owner,
                      let value = try await inspectPane(name: name, owner: owner, pane: nil, createdID: id) else { continue }
                let lifetime = try await checked(["show-options", "-p", "-qv", "-t", id, "@zeus-launched-lifetime"], socket: socket)
                let matches = value.dead ? lifetime.hasPrefix("\(value.pid).") : lifetime == "\(value.pid).\(value.startTime)"
                if matches { launched.append(value) }
            }
            guard launched.count <= 1 else { throw ManagedSessionError.ownershipChanged }
            return launched.first
        }
        let present = try await checked(["list-panes", "-s", "-t", "=" + name, "-F", "#{pane_id}"], socket: socket).split(separator: "\n")
        guard present.contains(Substring(target)) else { return nil }
        let format = "#{session_name}\t#{pane_id}\t#{socket_path}\t#{pid}\t#{session_id}\t#{pane_pid}\t#{pane_dead}\t#{pane_dead_status}\t#{pane_dead_signal}"
        let fields = try await checked(["display-message", "-p", "-t", target, format], socket: socket).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        if pane == nil && fields.count == 9 && fields[1].isEmpty { return nil }
        guard fields.count == 9, fields[0] == name, fields[1].hasPrefix("%"), fields[2].hasPrefix("/"),
              let server = Int(fields[3]), let pid = Int(fields[5]) else { throw ManagedSessionError.ownershipChanged }
        var info = proc_bsdinfo(); let size = MemoryLayout.size(ofValue: info)
        var start: UInt64 = 0
        if let kernelPID = Int32(exactly: pid), proc_pidinfo(kernelPID, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size {
            start = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
        }
        return .init(name: name, id: fields[1], socket: fields[2], serverPID: server, sessionNumber: String(fields[4].dropFirst()), pid: pid, startTime: start,
                     dead: fields[6] == "1", exitStatus: Int(fields[7]), signal: fields[8].isEmpty ? nil : fields[8])
    }
    func create(name: String, owner: String, folder: String) async throws -> ManagedPane {
        let existing = try await sessions().first { $0.name == name }
        if let existing, existing.owner != owner { throw ManagedSessionError.collision }
        let args = existing == nil
            ? ["new-session", "-d", "-P", "-F", "#{pane_id}", "-s", name, "-c", folder, "-e", "ZEUS_MANAGED_OWNER=" + owner, "-x", "120", "-y", "40"]
            : ["new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "=" + name, "-c", folder]
        let result = try await run(args + ["/bin/sleep", "86400"])
        guard result.status == 0 else {
            if String(decoding: result.stderr, as: UTF8.self).contains("duplicate session") { throw ManagedSessionError.collision }
            throw ManagedSessionError.terminalCommand("Couldn't create managed tmux: " + String(decoding: result.stderr, as: UTF8.self))
        }
        let id = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasPrefix("%"), Int(id.dropFirst()) != nil else { throw ManagedSessionError.ownershipChanged }
        // The returned ID is the pane we just launched, including after interrupted lease persistence.
        _ = try await checked(["set-option", "-p", "-t", id, "@zeus-launched-owner", owner])
        for _ in 0..<20 {
            if let pane = try await inspectPane(name: name, owner: owner, pane: nil, createdID: id), pane.startTime > 0 {
                try await markLifetime(pane)
                _ = try await checked(["set-option", "-w", "-t", pane.id, "remain-on-exit", "on"], socket: pane.socket)
                return pane
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ManagedSessionError.command(ZeusRuntimeCopy.Managed.terminalNotReady)
    }
    func capture(_ pane: ManagedPane, owner: String) async throws -> ManagedPaneSnapshot {
        guard let current = try await inspect(name: pane.name, owner: owner, pane: pane), !current.dead else { throw ManagedSessionError.ownershipChanged }
        try validateLifetime(pane, current)
        let metadata = try await checked(["display-message", "-p", "-t", pane.id, "#{cursor_x}|#{cursor_y}|#{pane_width}|#{pane_dead}|#{cursor_flag}"], socket: pane.socket)
        // Cursor coordinates are absolute screen rows; leading/trailing blank
        // rows are significant, including Claude's blank first banner row.
        let screen = try await checked(["capture-pane", "-p", "-e", "-t", pane.id], socket: pane.socket, preserveRows: true)
        guard let after = try await inspect(name: pane.name, owner: owner, pane: pane), !after.dead else { throw ManagedSessionError.ownershipChanged }
        try validateLifetime(pane, after)
        return .init(screen: screen, inputMetadata: metadata)
    }
    /// Input is generated only from a freshly parsed listed choice. No paste,
    /// free-text, default acceptance or timer-based answer is available here.
    func answerPrompt(_ pane: ManagedPane, owner: String, agent: AgentKind, scope: String,
                      fingerprint: String, optionID: String,
                      stillAllowed: @MainActor @Sendable () -> Bool) async throws -> ManagedPromptAnswerResult {
        let snapshot = try await capture(pane, owner: owner)
        guard let prompt = ManagedPromptParser.parse(snapshot, agent: agent, scope: scope),
              prompt.fingerprint == fingerprint, let option = prompt.options.first(where: { $0.id == optionID }) else { return .changed }
        let keys: [String]
        switch option.key {
        case .digit(let digit): keys = [String(digit)]
        case .shortcut(let shortcut): keys = [shortcut.rawValue]
        case .horizontal(let index):
            guard let highlighted = prompt.highlightedOption, prompt.options.indices.contains(index) else { return .changed }
            let movement = index - highlighted
            var current = highlighted
            for _ in 0..<abs(movement) {
                guard await stillAllowed() else { return .changed }
                _ = try await checked(["send-keys", "-t", pane.id, movement < 0 ? "Left" : "Right"], socket: pane.socket)
                current += movement < 0 ? -1 : 1
                let navigationDeadline = ContinuousClock.now + .seconds(1)
                while true {
                    let frame = try await capture(pane, owner: owner)
                    guard let next = ManagedPromptParser.parse(frame, agent: agent, scope: scope),
                          next.fingerprint == fingerprint else { return .changed }
                    if next.highlightedOption == current { break }
                    guard ContinuousClock.now < navigationDeadline else { return .changed }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            // Revalidate even when the clicked option was already highlighted.
            let frame = try await capture(pane, owner: owner)
            guard let selected = ManagedPromptParser.parse(frame, agent: agent, scope: scope),
                  selected.fingerprint == fingerprint, selected.highlightedOption == index else { return .changed }
            keys = ["Enter"]
        }
        guard await stillAllowed() else { return .changed }
        _ = try await checked(["send-keys", "-t", pane.id] + keys, socket: pane.socket)
        // Verification polls are read-only: never press the choice again.
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            do {
                let latest = try await capture(pane, owner: owner)
                switch ManagedPaneClassifier.classify(latest, agent: agent) {
                case .idle, .working: return .answered(optionID: option.id, label: option.label)
                case .blocked:
                    if ManagedPromptParser.parse(latest, agent: agent, scope: scope)?.fingerprint != fingerprint {
                        return .answered(optionID: option.id, label: option.label)
                    }
                case .unknown: break
                }
            } catch { return .unconfirmed(label: option.label) }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        return .unconfirmed(label: option.label)
    }
    func conversationEnvironment(_ pane: ManagedPane, owner: String) async throws -> [String: String] {
        guard try await inspect(name: pane.name, owner: owner, pane: pane) != nil else { throw ManagedSessionError.ownershipChanged }
        var values: [String: String] = [:]
        // Profile paths only: never query credential variables or the agent's full environment.
        for key in ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME"] {
            let scoped = try await run(["show-environment", "-t", "=" + pane.name, key], socket: pane.socket)
            // Session environment overlays the default server's global environment.
            let result = scoped.status == 0 ? scoped : try await run(["show-environment", "-g", key], socket: pane.socket)
            let output = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
            if result.status == 0, output.hasPrefix(key + "=") { values[key] = String(output.dropFirst(key.count + 1)) }
        }
        return values
    }
    private func validateLifetime(_ expected: ManagedPane, _ current: ManagedPane) throws {
        guard current.id == expected.id, current.socket == expected.socket,
              current.serverPID == expected.serverPID, current.sessionNumber == expected.sessionNumber,
              current.pid == expected.pid, current.dead || current.startTime == expected.startTime else { throw ManagedSessionError.ownershipChanged }
    }
    private func markLifetime(_ pane: ManagedPane) async throws {
        _ = try await checked(["set-option", "-p", "-t", pane.id, "@zeus-launched-lifetime", "\(pane.pid).\(pane.startTime)"], socket: pane.socket)
    }
    func launch(_ pane: ManagedPane, owner: String, command: ManagedLaunchCommand, folder: String) async throws -> ManagedPane {
        guard let current = try await inspect(name: pane.name, owner: owner, pane: pane), current.id == pane.id else { throw ManagedSessionError.ownershipChanged }
        try validateLifetime(pane, current)
        _ = try await checked(["respawn-pane", "-k", "-t", pane.id, "-c", folder] + command.arguments, socket: pane.socket)
        for _ in 0..<20 {
            if let current = try await inspect(name: pane.name, owner: owner, pane: pane), current.dead || (current.pid != pane.pid && current.startTime > 0) {
                try await markLifetime(current)
                return current
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ManagedSessionError.command(ZeusRuntimeCopy.Managed.terminalNotReady)
    }
    func requestExit(_ pane: ManagedPane, owner: String) async throws {
        guard let current = try await inspect(name: pane.name, owner: owner, pane: pane), !current.dead else { return }
        try validateLifetime(pane, current)
        // Native Ctrl-C exit/interrupt twice, never a blind Enter that could approve a dialog.
        _ = try await checked(["send-keys", "-t", pane.id, "C-c"], socket: pane.socket)
        try await Task.sleep(for: .milliseconds(200))
        if let current = try await inspect(name: pane.name, owner: owner, pane: pane), !current.dead {
            try validateLifetime(pane, current)
            _ = try await checked(["send-keys", "-t", pane.id, "C-c"], socket: pane.socket)
        }
    }
    func removePane(_ pane: ManagedPane, owner: String) async throws {
        guard let current = try await inspect(name: pane.name, owner: owner, pane: pane) else { return }
        try validateLifetime(pane, current)
        let allPanes = try await checked(["list-panes", "-a", "-F", "#{pane_id}"], socket: pane.socket).split(separator: "\n")
        let exitsWhenEmpty = try await checked(["show-options", "-sv", "exit-empty"], socket: pane.socket) == "on"
        var serverInfo = proc_bsdinfo()
        let infoSize = MemoryLayout.size(ofValue: serverInfo)
        let serverPID = Int32(exactly: pane.serverPID)
        let knowsServer = serverPID.map { proc_pidinfo($0, PROC_PIDTBSDINFO, 0, &serverInfo, Int32(infoSize)) == infoSize } ?? false
        _ = try await checked(["kill-pane", "-t", pane.id], socket: pane.socket)
        if allPanes.count == 1, exitsWhenEmpty, knowsServer, let serverPID {
            // The successful kill reply precedes daemon termination. Starting a
            // replacement during that interval connects to a dying server. Wait
            // for this exact daemon lifetime to finish; never restart or kill it.
            let deadline = ContinuousClock.now + .seconds(5)
            while true {
                var current = proc_bsdinfo()
                guard proc_pidinfo(serverPID, PROC_PIDTBSDINFO, 0, &current, Int32(infoSize)) == infoSize,
                      current.pbi_start_tvsec == serverInfo.pbi_start_tvsec,
                      current.pbi_start_tvusec == serverInfo.pbi_start_tvusec else { break }
                // Another client may have created a pane after our preflight count.
                // In that case the daemon correctly stays alive; leave it alone.
                let remaining = try await run(["list-panes", "-a", "-F", "#{pane_id}"], socket: pane.socket)
                if remaining.status == 0, !String(decoding: remaining.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                guard ContinuousClock.now < deadline else { throw ManagedSessionError.command("Terminal didn't finish closing your assistant's session. Try again.") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }
}
